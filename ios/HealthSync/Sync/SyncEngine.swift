import CryptoKit
import Foundation

protocol Uploader: Sendable {
    /// Uploads one batch. Must succeed only once the server has durably accepted it.
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws
}

struct SyncProgress: Equatable, Sendable {
    /// Workouts whose raw data is on the server, and workouts found on this iPhone.
    var detailsDone: Int
    var detailsTotal: Int
    var isSyncing: Bool
    /// Work units across all phases, so the bar moves from the start.
    var stepsDone = 0
    var stepsTotal = 0
    /// 1 = recent workouts, 2 = daily context, 3 = workout history, 4 = workout details (0 = not syncing).
    var phase = 0
    /// Recent workouts and the daily context are on the server: the AI is already useful.
    var recentReady = false
    var stepTitle: String {
        switch phase {
        case 1: return "Step 1 of 4: recent workouts"
        case 2: return "Step 2 of 4: daily context"
        case 3: return "Step 3 of 4: workout history"
        case 4: return "Step 4 of 4: workout details (\(detailsDone) of \(detailsTotal))"
        default: return "Syncing your workouts"
        }
    }
    var fraction: Double { stepsTotal > 0 ? min(1, Double(stepsDone) / Double(stepsTotal)) : 0 }
    var historyComplete: Bool { stepsTotal > 0 && stepsDone >= stepsTotal }
}

/// Orchestrates reading Apple Health and uploading batches. Order is chosen so the AI becomes
/// useful fast: recent workouts → daily context → all workout summaries → raw detail of every
/// workout (newest first).
actor SyncEngine {
    struct Config: Sendable {
        /// Workouts per anchored page. Pages are also split into ≤ 5 MB uploads.
        var workoutPageLimit = 200
        var recentDays = 30
        var dailyIncrementalDays = 3
        var dailyFullEvery: TimeInterval = 7 * 86_400
        var reconcileAfter: TimeInterval = 30 * 86_400
        var device = "iPhone"
        var appVersion = "1.0"
    }

    private let source: HealthSource
    private let uploader: Uploader
    private let outbox: Outbox
    private let scope: SyncScope
    private let config: Config
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> String
    private let telemetry: Telemetry
    private var running = false
    private var progressHandler: (@Sendable (SyncProgress) -> Void)?
    private var phase = 0
    private var lastReported: [Int]?
    private var deadline: Date?
    /// Set when the workout type was checked with nothing new; reported in one status batch.
    private var statusPending: [String: Date] = [:]
    private var stepErrors: [Error] = []
    private var lastUploadMs: Int?
    /// Set when an upload fails (offline, server down): the whole run stops instead of trying the rest.
    private var uploadFailed = false
    private var lastEmptyCheck: [String: Date] = [:]

    init(source: HealthSource, uploader: Uploader, outbox: Outbox, scope: SyncScope, config: Config = Config(),
         now: @escaping @Sendable () -> Date = Date.init, timeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier },
         telemetry: Telemetry = NoTelemetry()) {
        self.source = source
        self.uploader = uploader
        self.outbox = outbox
        self.scope = scope
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

    private var workoutId: String { scope.workout?.id ?? HealthTypes.workoutId }

    var progress: SyncProgress {
        let s = outbox.state
        let detailTotal = max(s.workoutTotal, s.detailsDone.count)
        let done = (s.recentDone.contains(workoutId) ? 1 : 0) + (s.dailyFullAt != nil ? 1 : 0) + (s.caughtUp.contains(workoutId) ? 1 : 0) + s.detailsDone.count
        return SyncProgress(detailsDone: s.detailsDone.count, detailsTotal: detailTotal, isSyncing: running,
                            stepsDone: done, stepsTotal: 3 + detailTotal, phase: running ? phase : 0,
                            recentReady: s.recentDone.contains(workoutId) && s.dailyFullAt != nil)
    }

    /// Notifies the UI only when something visible changes (whole percent, step, flags).
    private func report(syncing: Bool) {
        var p = progress
        p.isSyncing = syncing
        let key = [Int(p.fraction * 100), p.phase, p.isSyncing ? 1 : 0, p.recentReady ? 1 : 0, p.historyComplete ? 1 : 0, p.detailsDone]
        guard key != lastReported else { return }
        lastReported = key
        progressHandler?(p)
    }

    enum Outcome: Equatable, Sendable { case finished, outOfTime, alreadyRunning }

    private struct OutOfTime: Error {}

    private func checkTime() throws {
        if let deadline, now() >= deadline { throw OutOfTime() }
    }

    /// Full sync. `deadline` bounds background runs; everything is resumable.
    @discardableResult
    func run(deadline: Date? = nil) async throws -> Outcome {
        guard !running else { return .alreadyRunning }
        running = true
        self.deadline = deadline
        report(syncing: true)
        defer {
            running = false
            self.deadline = nil
            report(syncing: false)
        }

        try await flush()
        try startReconcileIfNeeded()

        stepErrors = []
        uploadFailed = false
        do {
            var index: [WorkoutRef] = []
            try await step { index = try await self.refreshWorkoutIndex() }
            phase = 1
            try await step { try await self.recentWorkouts() }
            phase = 2
            try await step { try await self.dailyContext() }
            phase = 3
            try await step {
                guard let wt = self.scope.workout else { return }
                while true {
                    try self.checkTime()
                    if try await self.anchoredPage(wt) { break }
                    self.report(syncing: true)
                }
            }
            phase = 4
            try await step { try await self.uploadDetails(index) }
            try await sendStatus()
        } catch is OutOfTime {
            try? await sendStatus()
            return .outOfTime
        }
        // A step that failed (e.g. one HealthKit query error) didn't stop the others; report the run
        // as failed so it is retried, but everything else is already synced.
        if let first = stepErrors.first { throw first }
        try outbox.update { $0.lastSyncAt = now() }
        return .finished
    }

    /// Runs one phase. A failure is recorded and the next phase still runs; running out of time,
    /// cancellation and upload failures (which would fail the same way everywhere) stop everything.
    private func step(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let e where e is OutOfTime || e is CancellationError {
            throw e
        } catch {
            if uploadFailed { throw error }
            stepErrors.append(error)
            telemetry.nonFatal("sync.step", code: (error as NSError).code)
        }
    }

    /// Quick incremental sync after HealthKit reports a new workout (background delivery).
    func runWorkoutChanges(deadline: Date) async throws {
        // Only once the full history is in: HealthKit calls every observer once at launch, and the
        // main run orders and reports that first sync. Taking the engine here would block it.
        guard !running, let wt = scope.workout, outbox.state.caughtUp.contains(wt.id) else { return }
        running = true
        self.deadline = deadline
        defer {
            running = false
            self.deadline = nil
        }
        try await flush()
        do {
            while now() < deadline {
                if try await anchoredPage(wt) { break }
            }
            let index = try await refreshWorkoutIndex()
            try await uploadDetails(index)
            try checkTime()
            try await dailyContext()
        } catch is OutOfTime {
            // Everything is resumable; the next run continues.
        }
        try await sendStatus()
    }

    // MARK: Steps

    private func refreshWorkoutIndex() async throws -> [WorkoutRef] {
        let index = try await source.workoutIndex()
        try outbox.update { $0.workoutTotal = index.count }
        report(syncing: true)
        return index
    }

    private func recentWorkouts() async throws {
        guard let wt = scope.workout, !outbox.state.recentDone.contains(wt.id) else { return }
        let end = now()
        let start = end.addingTimeInterval(-Double(config.recentDays) * 86_400)
        let started = Date()
        let records = try await source.workouts(from: start, to: end)
        let readMs = Self.ms(since: started)
        if records.isEmpty {
            // Nothing recent: skip the upload. The full-history pass reports the type anyway.
            try outbox.update { $0.recentDone.insert(wt.id) }
            return
        }
        let header = BatchHeader(type: wt.id, mode: .recent, seq: try outbox.nextSeq(wt.id), window: (start, end), checkedAt: end)
        try await send(wt.id, header: header, records: records, anchor: nil, completes: .recentDone, readMs: readMs)
    }

    /// Daily context: the whole history the first time (and once a week, so older data added
    /// later is included), otherwise just the last few days.
    private func dailyContext() async throws {
        guard !scope.dailyMetrics.isEmpty else { return }
        let end = now()
        let full = outbox.state.dailyFullAt.map { end.timeIntervalSince($0) > config.dailyFullEvery } ?? true
        var start: Date
        if full {
            start = try await source.earliestDailyDate() ?? end.addingTimeInterval(-365 * 86_400)
        } else {
            start = end.addingTimeInterval(-Double(config.dailyIncrementalDays) * 86_400)
        }
        let cal = Calendar.current
        start = cal.startOfDay(for: start)
        // One year per batch set keeps memory and batch sizes bounded.
        var chunkStart = start
        while chunkStart < end {
            try checkTime()
            let chunkEnd = min(cal.date(byAdding: .year, value: 1, to: chunkStart) ?? end, end)
            let started = Date()
            let records = try await source.dailyContext(from: chunkStart, to: chunkEnd)
            let readMs = Self.ms(since: started)
            let header = BatchHeader(type: HealthTypes.dailyId, mode: .stats, seq: try outbox.nextSeq(HealthTypes.dailyId), window: (chunkStart, chunkEnd), checkedAt: end)
            let last = chunkEnd >= end
            try await send(HealthTypes.dailyId, header: header, records: records, anchor: nil, completes: last && full ? .dailyFull(end) : nil, readMs: readMs)
            chunkStart = chunkEnd
        }
    }

    /// One anchored page of workout summaries. Returns true when caught up.
    private func anchoredPage(_ t: SyncType) async throws -> Bool {
        let reconcileId = outbox.state.reconcile[t.id]
        let anchor = outbox.state.anchors[t.id]
        let checked = now()
        let limit = config.workoutPageLimit
        let started = Date()
        let page = try await source.anchoredPage(t, anchor: anchor, limit: limit)
        let readMs = Self.ms(since: started)
        let caughtUp = page.objectCount < limit
        if page.objectCount == 0 && reconcileId == nil {
            // Nothing new: reported in a status batch, at most once an hour once caught up.
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

    /// Reads and uploads the raw data of every workout that has none on the server yet, newest first.
    private func uploadDetails(_ index: [WorkoutRef]) async throws {
        for ref in index where !outbox.state.detailsDone.contains(ref.id) {
            try checkTime()
            try await uploadDetail(ref)
            report(syncing: true)
        }
    }

    private func uploadDetail(_ ref: WorkoutRef) async throws {
        let started = Date()
        let gen = now().msValue
        guard let records = try await source.workoutDetail(id: ref.id, gen: gen) else {
            // The workout no longer exists: nothing to send.
            try outbox.update { $0.detailsDone.insert(ref.id) }
            return
        }
        let readMs = Self.ms(since: started)
        // Only the closing marker: this workout has no raw data (e.g. a manually logged one).
        if records.count <= 1 {
            try outbox.update { $0.detailsDone.insert(ref.id) }
            return
        }
        let id = HealthTypes.streamId
        let header = BatchHeader(type: id, mode: .workoutdata, seq: try outbox.nextSeq(id), checkedAt: now())
        try await send(id, header: header, records: records, anchor: nil, completes: .detailDone(ref.id), readMs: readMs)
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

    private func startReconcileIfNeeded() throws {
        guard let last = outbox.state.lastSyncAt, now().timeIntervalSince(last) > config.reconcileAfter, let wt = scope.workout else { return }
        // Deletions made while we were away may have expired from HealthKit: re-read every workout
        // and let the server remove what no longer exists.
        try outbox.update { s in
            s.reconcile[wt.id] = UUID().uuidString.lowercased()
            s.anchors[wt.id] = nil
            s.caughtUp.remove(wt.id)
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
