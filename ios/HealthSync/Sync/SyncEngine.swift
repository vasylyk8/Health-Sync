import CryptoKit
import Foundation

protocol Uploader: Sendable {
    /// Uploads one batch. Must succeed only once the server has durably accepted it.
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws
}

struct SyncProgress: Equatable, Sendable {
    /// Types whose full history has been sent.
    var typesDone: Int
    var typesTotal: Int
    var isSyncing: Bool
    /// Work units across all phases (last 30 days, hourly totals, full history), so the bar moves
    /// from the start instead of only in the final phase.
    var stepsDone = 0
    var stepsTotal = 0
    var fraction: Double {
        if stepsTotal > 0 { return min(1, Double(stepsDone) / Double(stepsTotal)) }
        return typesTotal == 0 ? 0 : Double(typesDone) / Double(typesTotal)
    }
    var historyComplete: Bool { typesTotal > 0 && typesDone >= typesTotal }
}

/// Orchestrates reading Apple Health and uploading batches. Order is chosen so the AI becomes
/// useful fast: last 30 days → all-history hourly totals → full raw history (newest data first
/// was already sent by the recent pass).
actor SyncEngine {
    struct Config: Sendable {
        var pageLimit = 5000
        var recentDays = 30
        var statsIncrementalDays = 3
        var statsFullEvery: TimeInterval = 7 * 86_400
        var reconcileAfter: TimeInterval = 30 * 86_400
        /// Data types synced at the same time (uploads are latency-bound, not bandwidth-bound).
        var parallelTypes = 4
        var device = "iPhone"
        var appVersion = "1.0"
    }

    private let source: HealthSource
    private let uploader: Uploader
    private let outbox: Outbox
    private let types: [SyncType]
    private let config: Config
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> String
    private let telemetry: Telemetry
    private var running = false
    private var progressHandler: (@Sendable (SyncProgress) -> Void)?

    init(source: HealthSource, uploader: Uploader, outbox: Outbox, types: [SyncType], config: Config = Config(),
         now: @escaping @Sendable () -> Date = Date.init, timeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier },
         telemetry: Telemetry = NoTelemetry()) {
        self.source = source
        self.uploader = uploader
        self.outbox = outbox
        self.types = types
        self.config = config
        self.now = now
        self.timeZone = timeZone
        self.telemetry = telemetry
    }

    func onProgress(_ handler: @escaping @Sendable (SyncProgress) -> Void) {
        progressHandler = handler
        report(syncing: running)
    }

    var progress: SyncProgress {
        let s = outbox.state
        let anchored = types.filter(\.isAnchored)
        let quantity = types.filter { if case .quantity = $0.kind { return true } else { return false } }
        let caughtUp = anchored.filter { s.caughtUp.contains($0.id) }.count
        // The full-history phase takes longest, so it counts double.
        let done = anchored.filter { s.recentDone.contains($0.id) }.count + quantity.filter { s.statsFullAt[$0.id] != nil }.count + 2 * caughtUp
        return SyncProgress(typesDone: caughtUp, typesTotal: anchored.count, isSyncing: running,
                            stepsDone: done, stepsTotal: 3 * anchored.count + quantity.count)
    }

    private func report(syncing: Bool) {
        var p = progress
        p.isSyncing = syncing
        progressHandler?(p)
    }

    enum Outcome: Equatable, Sendable { case finished, outOfTime, alreadyRunning }

    /// Full sync. `deadline` bounds background runs; everything is resumable.
    @discardableResult
    func run(deadline: Date? = nil) async throws -> Outcome {
        guard !running else { return .alreadyRunning }
        running = true
        report(syncing: true)
        defer {
            running = false
            report(syncing: false)
        }
        let outOfTime: @Sendable () -> Bool = { [now] in deadline.map { now() >= $0 } ?? false }

        try await flush()
        try startReconcileIfNeeded()
        try await syncProfile()

        do {
            let anchored = types.filter(\.isAnchored)
            try await eachType(anchored.filter { !outbox.state.recentDone.contains($0.id) }) { engine, t in
                if outOfTime() { throw OutOfTime() }
                try await engine.recent(t)
            }
            try await eachType(types.filter { if case .quantity = $0.kind { return true } else { return false } }) { engine, t in
                if outOfTime() { throw OutOfTime() }
                try await engine.stats(t)
            }
            for t in types where t.kind == .activitySummary {
                try await activity(t)
            }
            for t in types where t.kind == .correlation {
                try await correlation(t)
            }
            try await eachType(anchored) { engine, t in
                while true {
                    if outOfTime() { throw OutOfTime() }
                    if try await engine.anchoredPage(t) { break }
                    await engine.report(syncing: true)
                }
            }
        } catch is OutOfTime {
            return .outOfTime
        }
        try outbox.update { $0.lastSyncAt = now() }
        return .finished
    }

    private struct OutOfTime: Error {}

    /// Runs `body` for each type, `config.parallelTypes` at a time. Each type's uploads stay in
    /// order (one task per type); different types are independent on the server.
    private func eachType(_ list: [SyncType], _ body: @escaping @Sendable (SyncEngine, SyncType) async throws -> Void) async throws {
        var queue = list[...]
        let parallel = max(1, config.parallelTypes)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<parallel {
                guard let t = queue.popFirst() else { break }
                group.addTask { try await body(self, t) }
            }
            while try await group.next() != nil {
                await self.report(syncing: true)
                if let t = queue.popFirst() { group.addTask { try await body(self, t) } }
            }
        }
    }

    /// Quick incremental sync of specific types (HealthKit background observers).
    func runTypes(_ ids: Set<String>, deadline: Date) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        try await flush()
        for t in types where ids.contains(t.id) {
            while now() < deadline {
                if try await anchoredPage(t) { break }
            }
            if case .quantity = t.kind, outbox.state.statsFullAt[t.id] != nil { try await stats(t) }
        }
    }

    // MARK: Steps

    private func recent(_ t: SyncType) async throws {
        let end = now()
        let start = end.addingTimeInterval(-Double(config.recentDays) * 86_400)
        let records = try await source.samples(t, from: start, to: end)
        if records.isEmpty {
            // Nothing recent: skip the upload. The full-history pass reports this type (and its
            // coverage) to the server anyway, so an empty batch here only costs a round trip.
            try outbox.update { $0.recentDone.insert(t.id) }
            return
        }
        let header = BatchHeader(type: t.id, mode: .recent, seq: try outbox.nextSeq(t.id), window: (start, end), checkedAt: end)
        try await send(t.id, header: header, records: records, anchor: nil, completes: .recentDone)
    }

    private func stats(_ t: SyncType) async throws {
        let end = now()
        let full = outbox.state.statsFullAt[t.id].map { end.timeIntervalSince($0) > config.statsFullEvery } ?? true
        var start: Date
        if full {
            if outbox.state.earliest[t.id] == nil, let e = try await source.earliestSampleDate(t) {
                try outbox.update { $0.earliest[t.id] = e }
            }
            guard let earliest = outbox.state.earliest[t.id] else {
                // No data at all for this type: nothing to summarize yet.
                try outbox.update { $0.statsFullAt[t.id] = end }
                return
            }
            start = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: earliest)?.start ?? earliest
        } else {
            start = end.addingTimeInterval(-Double(config.statsIncrementalDays) * 86_400)
            start = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: start)?.start ?? start
        }
        // One year per batch set keeps memory and batch sizes bounded.
        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: chunkStart) ?? end, end)
            let records = try await source.hourlyStats(t, from: chunkStart, to: chunkEnd)
            let header = BatchHeader(type: t.id, mode: .stats, seq: try outbox.nextSeq(t.id), window: (chunkStart, chunkEnd), checkedAt: end)
            let last = chunkEnd >= end
            try await send(t.id, header: header, records: records, anchor: nil, completes: last && full ? .statsFull(end) : nil)
            chunkStart = chunkEnd
        }
    }

    private func activity(_ t: SyncType) async throws {
        let end = now()
        let initial = !outbox.state.activityInitialDone
        let start = initial ? (end.addingTimeInterval(-15 * 365 * 86_400)) : end.addingTimeInterval(-7 * 86_400)
        let records = try await source.activitySummaries(from: start, to: end)
        let header = BatchHeader(type: t.id, mode: .recent, seq: try outbox.nextSeq(t.id), window: (start, end), checkedAt: end)
        try await send(t.id, header: header, records: records, anchor: nil, completes: initial ? .activityInitial : nil)
    }

    private func correlation(_ t: SyncType) async throws {
        let end = now()
        let initial = !outbox.state.correlationInitialDone.contains(t.id)
        let start = initial ? Date(timeIntervalSince1970: 0) : end.addingTimeInterval(-7 * 86_400)
        let records = try await source.correlations(t, from: start, to: end)
        let header = BatchHeader(type: t.id, mode: .recent, seq: try outbox.nextSeq(t.id), window: (start, end), checkedAt: end)
        try await send(t.id, header: header, records: records, anchor: nil, completes: initial ? .correlationInitial : nil)
    }

    private func syncProfile() async throws {
        guard let profile = source.profile() else { return }
        let data = try JSONEncoder().encode(profile)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash != outbox.state.profileHash else { return }
        let header = BatchHeader(type: HealthTypes.profileId, mode: .profile, seq: try outbox.nextSeq(HealthTypes.profileId), checkedAt: now())
        try await send(HealthTypes.profileId, header: header, records: [profile], anchor: nil, completes: .profile(hash))
    }

    /// One anchored page. Returns true when the type is caught up.
    private func anchoredPage(_ t: SyncType) async throws -> Bool {
        let reconcileId = outbox.state.reconcile[t.id]
        let anchor = outbox.state.anchors[t.id]
        let checked = now()
        let page = try await source.anchoredPage(t, anchor: anchor, limit: config.pageLimit)
        let caughtUp = page.objectCount < config.pageLimit
        if page.objectCount == 0 && reconcileId == nil && outbox.state.caughtUp.contains(t.id) {
            // Nothing changed. Still tell the server we checked, so freshness stays accurate,
            // at most once an hour per type.
            if let last = lastEmptyCheck[t.id], checked.timeIntervalSince(last) < 3600 { return true }
            lastEmptyCheck[t.id] = checked
        }
        let header = BatchHeader(
            type: t.id, mode: reconcileId == nil ? .anchored : .reconcile, seq: try outbox.nextSeq(t.id),
            caughtUp: caughtUp, checkedAt: checked, reconcileId: reconcileId, reconcileDone: reconcileId == nil ? nil : caughtUp)
        let completes: Outbox.Completion? = caughtUp ? (reconcileId == nil ? .caughtUp : .reconcileDone) : nil
        try await send(t.id, header: header, records: page.records, anchor: page.newAnchor, completes: completes)
        return caughtUp
    }

    private var lastEmptyCheck: [String: Date] = [:]

    private func startReconcileIfNeeded() throws {
        guard let last = outbox.state.lastSyncAt, now().timeIntervalSince(last) > config.reconcileAfter else { return }
        // Deletions made while we were away may have expired from HealthKit: re-read everything
        // and let the server remove what no longer exists.
        try outbox.update { s in
            for t in types where t.isAnchored {
                s.reconcile[t.id] = UUID().uuidString.lowercased()
                s.anchors[t.id] = nil
                s.caughtUp.remove(t.id)
            }
        }
        telemetry.event("reconcile_started")
    }

    // MARK: Upload

    private func send(_ typeId: String, header: BatchHeader, records: [Record], anchor: Data?, completes: Outbox.Completion?) async throws {
        let outbox = self.outbox
        let batches = try BatchWriter.make(
            header: header, records: records, nextSeq: { (try? outbox.nextSeq(typeId)) ?? header.seq },
            now: now(), tz: timeZone(), device: config.device, appVersion: config.appVersion)
        _ = try outbox.enqueue(typeId: typeId, batches: batches, anchor: anchor, completes: completes)
        try await flush(typeId: typeId)
    }

    /// Uploads everything pending (or only one type's entries), in order. Stops at the first
    /// failure (retried next run).
    func flush(typeId: String? = nil) async throws {
        for var entry in outbox.pending() where typeId == nil || entry.typeId == typeId {
            for id in entry.batchIds where !entry.uploaded.contains(id) {
                guard let gz = outbox.batchData(id) else {
                    // Missing file (should not happen): treat as uploaded rather than block forever.
                    try outbox.markUploaded(&entry, batchId: id)
                    telemetry.nonFatal("outbox.missingBatch", code: 1)
                    continue
                }
                let sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
                try await uploader.upload(batchId: id, gz: gz, sha256: sha, typeId: entry.typeId)
                try outbox.markUploaded(&entry, batchId: id)
            }
            try outbox.complete(entry)
        }
    }
}
