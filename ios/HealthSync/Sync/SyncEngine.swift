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
    /// What the app is doing in the early steps, which show no percentage for a while on a large history.
    var phaseHint: String? {
        switch phase {
        case 1: return "Reading your recent workouts…"
        case 2: return "Reading years of daily history (sleep, heart rate, steps…). The first time this can take a minute or two."
        case 3: return "Reading your list of workouts…"
        default: return nil
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
        /// Workouts read from HealthKit at the same time while raw data is collected.
        var detailReadConcurrency = 24
        /// Batches of one raw-data upload sent at the same time (only for `_wstream`, whose parts have no ordering).
        var uploadConcurrency = 3
        /// Workouts whose raw data goes into one upload (fewer round trips and file writes).
        var detailGroupSize = 48
        /// Smaller groups when there is a deadline (background wake-ups) so the time limit is respected.
        var detailGroupSizeWithDeadline = 4
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
    /// Workouts are read several at a time and sent in groups (one upload per group). While one group
    /// is being written and uploaded, the next is already being read from HealthKit.
    private func uploadDetails(_ index: [WorkoutRef]) async throws {
        let todo = index.filter { !outbox.state.detailsDone.contains($0.id) }
        guard !todo.isEmpty else { return }
        SyncTiming.shared.markDetailsStart()
        let size = max(1, deadline == nil ? config.detailGroupSize : config.detailGroupSizeWithDeadline)
        let groups = stride(from: 0, to: todo.count, by: size).map { Array(todo[$0 ..< min($0 + size, todo.count)]) }
        let source = self.source
        let clock = now
        let timing = SyncTiming.shared
        // Workouts in progress are bounded by a fixed gate (memory); how many HealthKit queries run at once
        // is tuned to what this iPhone answers fastest, since Apple documents no limit.
        let gate = ReadGate(limit: config.detailReadConcurrency)
        let tuner = ReadTuner(
            current: { [source] in source.queryConcurrency }, apply: { [source] in source.setQueryConcurrency($0) },
            minLimit: 4, maxLimit: 96, step: 8, windowSize: 24)
        timing.set("read.limit", source.queryConcurrency)

        func read(_ group: [WorkoutRef]) -> Task<[EncodedWorkout?], Error> {
            Task { try await Self.readGroup(group, source: source, gate: gate, tuner: tuner, now: clock) }
        }

        try checkTime()
        // The next group is read while this one is still finishing and while the previous one is uploaded.
        var reads: [Int: Task<[EncodedWorkout?], Error>] = [:]
        defer { reads.values.forEach { $0.cancel() } }
        for (i, group) in groups.enumerated() {
            for j in i ... min(i + 1, groups.count - 1) where reads[j] == nil { reads[j] = read(groups[j]) }
            let results = try await reads[i]!.value
            reads[i] = nil
            try checkTime()

            var lines: [Data] = []
            var recordCount = 0
            var withData: [String] = []
            var empty: [String] = []
            for (ref, found) in zip(group, results) {
                // Nil: the workout no longer exists. Only the closing marker: no raw data (e.g. logged by hand).
                if let found, found.recordCount > 1 {
                    lines.append(contentsOf: found.lines)
                    recordCount += found.recordCount
                    withData.append(ref.id)
                } else {
                    empty.append(ref.id)
                }
            }
            if lines.isEmpty {
                if !empty.isEmpty { try outbox.update { $0.detailsDone.formUnion(empty) } }
            } else {
                // Workouts without raw data ride along in the same completion: one state write per group.
                let id = HealthTypes.streamId
                let header = BatchHeader(type: id, mode: .workoutdata, seq: try outbox.nextSeq(id), checkedAt: now())
                try await timing.measure("detail.send") {
                    try await self.sendLines(id, header: header, lines: lines, anchor: nil, completes: .detailsDone(withData + empty))
                }
            }
            timing.count("detail.records", recordCount)
            timing.count("detail.workouts", group.count)
            timing.checkpoint("details \(min((i + 1) * size, todo.count))/\(todo.count)")
            report(syncing: true)
        }
    }

    /// A workout's raw-data records, already encoded as JSON lines (done while reading, in parallel).
    private struct EncodedWorkout: Sendable {
        var lines: [Data]
        var recordCount: Int
    }

    /// Reads a group of workouts (all at once, throttled by the shared gate); results keep the group's order.
    /// Each workout is also JSON-encoded here, so encoding runs in parallel and not on the sync actor.
    private static func readGroup(_ group: [WorkoutRef], source: HealthSource, gate: ReadGate, tuner: ReadTuner, now: @escaping @Sendable () -> Date) async throws -> [EncodedWorkout?] {
        try await withThrowingTaskGroup(of: (Int, EncodedWorkout?).self) { tasks in
            for (i, ref) in group.enumerated() {
                tasks.addTask {
                    await gate.acquire()
                    let records: [Record]?
                    do {
                        try Task.checkCancellation()
                        let gen = now().msValue
                        records = try await SyncTiming.shared.measure("detail.read") { try await source.workoutDetail(id: ref.id, gen: gen) }
                    } catch {
                        gate.release()
                        throw error
                    }
                    gate.release()
                    tuner.completed()
                    guard let records else { return (i, nil) }
                    let lines = try SyncTiming.shared.measureSync("detail.encode") { try BatchWriter.encodeLines(records) }
                    return (i, EncodedWorkout(lines: lines, recordCount: records.count))
                }
            }
            var results = [EncodedWorkout?](repeating: nil, count: group.count)
            while let (i, encoded) = try await tasks.next() { results[i] = encoded }
            return results
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

    private func startReconcileIfNeeded() throws {
        guard let last = outbox.state.lastSyncAt, now().timeIntervalSince(last) > config.reconcileAfter, let wt = scope.workout else { return }
        // A pass that was interrupted (out of time, offline) continues where it stopped: restarting it
        // would re-read everything again and could never finish on a slow connection.
        guard outbox.state.reconcile[wt.id] == nil else { return }
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
        let lines = try SyncTiming.shared.measureSync("batch.encode") { try BatchWriter.encodeLines(records) }
        try await sendLines(typeId, header: header, lines: lines, anchor: anchor, completes: completes, readMs: readMs)
    }

    private func sendLines(_ typeId: String, header: BatchHeader, lines: [Data], anchor: Data?, completes: Outbox.Completion?, readMs: Int? = nil) async throws {
        let outbox = self.outbox
        var header = header
        header.readMs = readMs
        header.uploadMs = lastUploadMs
        let (device, appVersion, tz, at) = (config.device, config.appVersion, timeZone(), now())
        let batches = try SyncTiming.shared.measureSync("batch.compress") {
            try BatchWriter.make(
                header: header, lines: lines, nextSeq: { (try? outbox.nextSeq(typeId)) ?? header.seq },
                now: at, tz: tz, device: device, appVersion: appVersion)
        }
        SyncTiming.shared.count("upload.bytes", batches.reduce(0) { $0 + $1.gz.count })
        SyncTiming.shared.count("upload.batches", batches.count)
        _ = try SyncTiming.shared.measureSync("outbox.enqueue") { try outbox.enqueue(typeId: typeId, batches: batches, anchor: anchor, completes: completes) }
        try await flush(typeId: typeId)
    }

    /// Uploads everything pending (or only one type's entries), in order. Stops at the first
    /// failure (retried next run).
    func flush(typeId: String? = nil) async throws {
        for var entry in outbox.pending() where typeId == nil || entry.typeId == typeId {
            // Files first: stop at the first missing one (the earlier ones are still uploaded and recorded).
            var jobs: [(id: String, gz: Data)] = []
            var lost = false
            for id in entry.batchIds where !entry.uploaded.contains(id) {
                guard let gz = outbox.batchData(id) else {
                    lost = true
                    break
                }
                jobs.append((id, gz))
            }
            // Parts of a raw-data upload carry no completion flag and can arrive in any order. Other types
            // (history pages, daily rows) must arrive in order: only their last part claims completion.
            let limit = entry.typeId == HealthTypes.streamId ? max(1, config.uploadConcurrency) : 1
            let results = await Self.uploadAll(jobs, typeId: entry.typeId, uploader: uploader, limit: limit)
            var failure: Error?
            for r in results {
                if let error = r.error {
                    uploadFailed = true
                    failure = failure ?? error
                } else {
                    lastUploadMs = r.ms
                    try outbox.markUploaded(&entry, batchId: r.id)
                }
            }
            if let failure { throw failure }
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

    private struct UploadResult {
        var id: String
        var ms: Int
        var error: Error?
    }

    /// Uploads the batches with at most `limit` in flight. A failure does not cancel the others (their
    /// results are recorded, so a retry only sends what is missing); with limit 1 it stops at the first.
    private static func uploadAll(_ jobs: [(id: String, gz: Data)], typeId: String, uploader: Uploader, limit: Int) async -> [UploadResult] {
        var results: [UploadResult] = []
        await withTaskGroup(of: UploadResult.self) { group in
            var next = 0
            var stop = false
            func startNext() {
                guard !stop, next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    let sha = SHA256.hash(data: job.gz).map { String(format: "%02x", $0) }.joined()
                    let started = Date()
                    do {
                        try await SyncTiming.shared.measure("upload") { try await uploader.upload(batchId: job.id, gz: job.gz, sha256: sha, typeId: typeId) }
                        return UploadResult(id: job.id, ms: Self.ms(since: started), error: nil)
                    } catch {
                        return UploadResult(id: job.id, ms: Self.ms(since: started), error: error)
                    }
                }
            }
            for _ in 0 ..< min(limit, jobs.count) { startNext() }
            while let r = await group.next() {
                results.append(r)
                if r.error != nil { stop = true }
                startNext()
            }
        }
        return results
    }
}
