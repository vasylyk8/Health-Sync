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
    /// 1 = last 30 days, 2 = long-term totals, 3 = full history (0 = not syncing).
    var phase = 0
    /// Every type's last 30 days are on the server: the AI is already useful.
    var recentReady = false
    var stepTitle: String {
        switch phase {
        case 1: return "Step 1 of 3: last 30 days"
        case 2: return "Step 2 of 3: long-term totals"
        case 3: return "Step 3 of 3: full history"
        default: return "Syncing your history"
        }
    }
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
        /// Objects per anchored page for plain samples. Pages are split into ≤ 5 MB uploads anyway;
        /// small pages only add round trips.
        var pageLimit = 20_000
        /// Cap for types whose objects carry large nested data (ECG voltages, heartbeat series, workouts).
        var heavyPageLimit = 2_000
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
    private var phase = 0
    private var lastReported: [Int]?
    /// Types checked with nothing new, reported together in one status batch.
    private var statusPending: [String: Date] = [:]
    private var typeErrors: [Error] = []
    private var lastUploadMs: Int?
    /// Set when an upload fails (offline, server down): every type would fail the same way, so
    /// the whole run stops instead of isolating the error to one type.
    private var uploadFailed = false

    /// Most-asked types first, so answers are useful while the rest syncs.
    static let priority = [
        "HKQuantityTypeIdentifierStepCount", "HKCategoryTypeIdentifierSleepAnalysis", "HKQuantityTypeIdentifierHeartRate",
        "HKWorkoutTypeIdentifier", "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierBodyMass", "HKQuantityTypeIdentifierVO2Max", "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierBasalEnergyBurned", "HKQuantityTypeIdentifierWalkingHeartRateAverage",
        "HKQuantityTypeIdentifierOxygenSaturation", "HKQuantityTypeIdentifierRespiratoryRate", "HKQuantityTypeIdentifierFlightsClimbed",
    ]

    /// Stable sort: priority types first (in priority order), everything else keeps its order.
    static func prioritized(_ types: [SyncType]) -> [SyncType] {
        let rank = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
        return types.enumerated()
            .sorted { (rank[$0.element.id] ?? priority.count, $0.offset) < (rank[$1.element.id] ?? priority.count, $1.offset) }
            .map(\.element)
    }

    init(source: HealthSource, uploader: Uploader, outbox: Outbox, types: [SyncType], config: Config = Config(),
         now: @escaping @Sendable () -> Date = Date.init, timeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier },
         telemetry: Telemetry = NoTelemetry()) {
        self.source = source
        self.uploader = uploader
        self.outbox = outbox
        self.types = SyncEngine.prioritized(types)
        self.config = config
        self.now = now
        self.timeZone = timeZone
        self.telemetry = telemetry
    }

    func onProgress(_ handler: @escaping @Sendable (SyncProgress) -> Void) {
        progressHandler = handler
        lastReported = nil
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
                            stepsDone: done, stepsTotal: 3 * anchored.count + quantity.count, phase: running ? phase : 0,
                            recentReady: !anchored.isEmpty && anchored.allSatisfy { s.recentDone.contains($0.id) })
    }

    /// Notifies the UI only when something visible changes (whole percent, step, flags).
    private func report(syncing: Bool) {
        var p = progress
        p.isSyncing = syncing
        let key = [Int(p.fraction * 100), p.phase, p.isSyncing ? 1 : 0, p.recentReady ? 1 : 0, p.historyComplete ? 1 : 0]
        guard key != lastReported else { return }
        lastReported = key
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

        typeErrors = []
        uploadFailed = false
        do {
            let anchored = types.filter(\.isAnchored)
            phase = 1
            try await eachType(anchored.filter { !outbox.state.recentDone.contains($0.id) }) { engine, t in
                if outOfTime() { throw OutOfTime() }
                try await engine.recent(t)
            }
            phase = 2
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
            phase = 3
            try await eachType(anchored) { engine, t in
                while true {
                    if outOfTime() { throw OutOfTime() }
                    if try await engine.anchoredPage(t) { break }
                    await engine.report(syncing: true)
                }
            }
            try await sendStatus()
        } catch is OutOfTime {
            try? await sendStatus()
            return .outOfTime
        }
        // A type that failed (e.g. one HealthKit query error) didn't stop the others; report the
        // run as failed so it is retried, but everything else is already synced.
        if let first = typeErrors.first { throw first }
        try outbox.update { $0.lastSyncAt = now() }
        return .finished
    }

    private struct OutOfTime: Error {}

    /// Runs `body` for each type, `config.parallelTypes` at a time. Each type's uploads stay in
    /// order (one task per type); different types are independent on the server.
    private func eachType(_ list: [SyncType], _ body: @escaping @Sendable (SyncEngine, SyncType) async throws -> Void) async throws {
        var queue = list[...]
        let parallel = max(1, config.parallelTypes)
        // One type's failure is recorded and the others continue; running out of time or
        // cancellation stops everything.
        let isolated: @Sendable (SyncType) async throws -> Void = { t in
            do {
                try await body(self, t)
            } catch let e where e is OutOfTime || e is CancellationError {
                throw e
            } catch {
                if await self.uploadFailed { throw error }
                await self.noteFailure(t, error)
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<parallel {
                guard let t = queue.popFirst() else { break }
                group.addTask { try await isolated(t) }
            }
            while try await group.next() != nil {
                await self.report(syncing: true)
                if let t = queue.popFirst() { group.addTask { try await isolated(t) } }
            }
        }
    }

    private func noteFailure(_ t: SyncType, _ error: Error) {
        typeErrors.append(error)
        telemetry.nonFatal("sync.type", code: (error as NSError).code)
    }

    /// Quick incremental sync of specific types (HealthKit background observers).
    func runTypes(_ ids: Set<String>, deadline: Date) async throws {
        // Only types whose history is already in: HealthKit calls every observer once at launch, and a
        // type that is still syncing belongs to the main run (which orders and reports it). Taking the
        // engine for one of those would keep the main run from starting.
        let eligible = types.filter { ids.contains($0.id) && outbox.state.caughtUp.contains($0.id) }
        guard !running, !eligible.isEmpty else { return }
        running = true
        defer { running = false }
        try await flush()
        for t in eligible {
            while now() < deadline {
                if try await anchoredPage(t) { break }
            }
            if case .quantity = t.kind, outbox.state.statsFullAt[t.id] != nil { try await stats(t) }
        }
        try await sendStatus()
    }

    // MARK: Steps

    private func recent(_ t: SyncType) async throws {
        let end = now()
        let start = end.addingTimeInterval(-Double(config.recentDays) * 86_400)
        let started = Date()
        let records = try await source.samples(t, from: start, to: end)
        let readMs = Self.ms(since: started)
        if records.isEmpty {
            // Nothing recent: skip the upload. The full-history pass reports this type (and its
            // coverage) to the server anyway, so an empty batch here only costs a round trip.
            try outbox.update { $0.recentDone.insert(t.id) }
            return
        }
        let header = BatchHeader(type: t.id, mode: .recent, seq: try outbox.nextSeq(t.id), window: (start, end), checkedAt: end)
        try await send(t.id, header: header, records: records, anchor: nil, completes: .recentDone, readMs: readMs)
    }

    private func stats(_ t: SyncType) async throws {
        let end = now()
        let full = outbox.state.statsFullAt[t.id].map { end.timeIntervalSince($0) > config.statsFullEvery } ?? true
        var start: Date
        if full {
            // Re-read every full recompute: older data added later (e.g. imported from another app)
            // must be included in the merged totals.
            if let e = try await source.earliestSampleDate(t), outbox.state.earliest[t.id] != e {
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
            let started = Date()
            let records = try await source.hourlyStats(t, from: chunkStart, to: chunkEnd)
            let readMs = Self.ms(since: started)
            let header = BatchHeader(type: t.id, mode: .stats, seq: try outbox.nextSeq(t.id), window: (chunkStart, chunkEnd), checkedAt: end)
            let last = chunkEnd >= end
            try await send(t.id, header: header, records: records, anchor: nil, completes: last && full ? .statsFull(end) : nil, readMs: readMs)
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
        // Sorted keys: dictionary order can differ between instances, which would change the hash
        // and re-upload an unchanged profile.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(profile)
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
        let limit = pageLimit(for: t)
        let started = Date()
        let page = try await source.anchoredPage(t, anchor: anchor, limit: limit)
        let readMs = Self.ms(since: started)
        let caughtUp = page.objectCount < limit
        if page.objectCount == 0 && reconcileId == nil {
            // Nothing new (or no data at all). Instead of one upload per type, it goes into a
            // single status batch; already-synced types are re-reported at most once an hour.
            if outbox.state.caughtUp.contains(t.id), let last = lastEmptyCheck[t.id], checked.timeIntervalSince(last) < 3600 { return true }
            lastEmptyCheck[t.id] = checked
            statusPending[t.id] = checked
            return true
        }
        let header = BatchHeader(
            type: t.id, mode: reconcileId == nil ? .anchored : .reconcile, seq: try outbox.nextSeq(t.id),
            caughtUp: caughtUp, checkedAt: checked, reconcileId: reconcileId, reconcileDone: reconcileId == nil ? nil : caughtUp)
        let completes: Outbox.Completion? = caughtUp ? (reconcileId == nil ? .caughtUp : .reconcileDone) : nil
        try await send(t.id, header: header, records: page.records, anchor: page.newAnchor, completes: completes, readMs: readMs)
        return caughtUp
    }

    private func pageLimit(for t: SyncType) -> Int {
        switch t.kind {
        case .quantity, .category: return config.pageLimit
        default: return min(config.pageLimit, config.heavyPageLimit)
        }
    }

    /// Sends every pending "checked, nothing new" type in one batch.
    private func sendStatus() async throws {
        guard !statusPending.isEmpty else { return }
        let items = statusPending.sorted { $0.key < $1.key }
        statusPending = [:]
        let id = HealthTypes.statusId
        let records: [Record] = items.map { ["k": "c", "t": .string($0.key), "at": $0.value.ms, "cu": true] }
        let header = BatchHeader(type: id, mode: .status, seq: try outbox.nextSeq(id), checkedAt: now())
        try await send(id, header: header, records: records, anchor: nil, completes: .caughtUpMany(items.map(\.key)))
        report(syncing: running)
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

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

    private func send(_ typeId: String, header: BatchHeader, records: [Record], anchor: Data?, completes: Outbox.Completion?, readMs: Int? = nil) async throws {
        let outbox = self.outbox
        var header = header
        header.readMs = readMs
        header.uploadMs = lastUploadMs
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
            var lost = false
            for id in entry.batchIds where !entry.uploaded.contains(id) {
                guard let gz = outbox.batchData(id) else {
                    lost = true
                    break
                }
                let sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
                let started = Date()
                do {
                    try await uploader.upload(batchId: id, gz: gz, sha256: sha, typeId: entry.typeId)
                } catch {
                    uploadFailed = true
                    throw error
                }
                lastUploadMs = Self.ms(since: started)
                try outbox.markUploaded(&entry, batchId: id)
            }
            if lost {
                // A batch file vanished (should not happen). Completing the entry would move the anchor
                // past data the server never got, so drop it instead: the next run re-reads from the
                // last committed anchor.
                telemetry.nonFatal("outbox.missingBatch", code: 1)
                try outbox.discard(entry)
                continue
            }
            try outbox.complete(entry)
        }
    }
}
