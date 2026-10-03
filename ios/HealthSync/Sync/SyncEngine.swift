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
    /// Which of the four steps are finished (for the step bar on Home).
    var recentDone = false
    var dailyDone = false
    var historyDone = false
    /// Running totals for the big numbers on Home.
    var stats = SyncStatsSnapshot()
    /// Finished flags for [recent workouts, daily context, workout history, workout details].
    var stepFlags: [Bool] { [recentDone, dailyDone, historyDone, historyComplete] }
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
        case 0: return "Getting ready…"
        case 1: return "Reading your recent workouts…"
        case 2: return "Reading years of daily history (sleep, heart rate, steps…). The first time this can take a minute or two."
        case 3: return "Reading your list of workouts…"
        default: return nil
        }
    }
    var fraction: Double { stepsTotal > 0 ? min(1, Double(stepsDone) / Double(stepsTotal)) : 0 }
    var historyComplete: Bool { stepsTotal > 0 && stepsDone >= stepsTotal }
    /// What the progress bar shows. The number of workouts is only known once the workout list is read, so until
    /// then the share is not real yet: it stays in the first quarter instead of jumping ahead.
    var uploadFraction: Double { historyDone || historyComplete ? fraction : min(fraction, 0.24) }
}

/// Orchestrates reading Apple Health and uploading batches. Order is chosen so the AI becomes
/// useful fast: recent workouts → daily context → all workout summaries → raw detail of every
/// workout (newest first).
actor SyncEngine {
    /// 1: effort scores and one-minute heart-rate recovery are also read through their workout time window.
    static let detailVersion = 1

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
        var uploadConcurrency = 6
        /// Workouts whose raw data goes into one upload (fewer round trips and file writes).
        var detailGroupSize = 48
        /// Smaller groups when there is a deadline (background wake-ups) so the time limit is respected.
        var detailGroupSizeWithDeadline = 4
        /// Raw-data groups still uploading while the next ones are read and compressed. 1 = wait for each
        /// group's upload before the next (as before; kept for the simulator A/B).
        var detailGroupsUploading = 3
        /// Uncompressed size of one raw-data upload part. Parts are compressed in parallel, off the sync actor,
        /// and stay under the server's compressed limit without being split again.
        var detailPartBytes = 4_000_000
        /// Events (readings, entries) per anchored page; glucose has a reading every few minutes.
        var eventPageLimit = 5_000
        /// Hourly series: how many recent days are re-read on each pass, and how often a pass runs.
        var hourlyIncrementalDays = 3
        var hourlyEvery: TimeInterval = 3_600
        /// Events and the incremental daily rows are not re-read more often than this.
        var minRefresh: TimeInterval = 900
        var profileEvery: TimeInterval = 7 * 86_400
    }

    private let source: HealthSource
    private let uploader: Uploader
    private let outbox: Outbox
    private let scope: SyncScope
    private let config: Config
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> String
    private let telemetry: Telemetry
    /// Consent categories switched on right now ("core" is always on).
    private let categories: @Sendable () -> Set<String>
    private var lastDailyAt: Date?
    private var lastEventsAt: Date?
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
    /// Outbox entries being uploaded by a raw-data upload task (a flush skips them, so nothing is sent twice).
    private var uploading: Set<String> = []
    private var lastEmptyCheck: [String: Date] = [:]
    /// Totals behind the big numbers on Home (kept next to the outbox so they survive relaunches).
    private let stats: SyncStatsStore

    init(source: HealthSource, uploader: Uploader, outbox: Outbox, scope: SyncScope, config: Config = Config(),
         now: @escaping @Sendable () -> Date = Date.init, timeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier },
         telemetry: Telemetry = NoTelemetry(), stats: SyncStatsStore? = nil,
         categories: @escaping @Sendable () -> Set<String> = { ["core"] }) {
        self.categories = categories
        self.source = source
        self.uploader = uploader
        self.outbox = outbox
        self.scope = scope
        self.config = config
        self.now = now
        self.timeZone = timeZone
        self.telemetry = telemetry
        let s = outbox.state
        let hasHistory = !s.recentDone.isEmpty || !s.caughtUp.isEmpty || !s.detailsDone.isEmpty || s.dailyFullAt != nil
        self.stats = stats ?? SyncStatsStore(url: outbox.root.appendingPathComponent("stats.json"), historyExists: hasHistory)
    }

    /// Forgets the totals (Delete All My Data).
    func resetStats() {
        stats.reset()
    }

    /// Writes the totals to disk (when the app goes to the background).
    func flushStats() {
        stats.flush()
    }

    func onProgress(_ handler: @escaping @Sendable (SyncProgress) -> Void) {
        progressHandler = handler
        lastReported = nil
        report(syncing: running)
    }

    private var workoutId: String { scope.workout?.id ?? HealthTypes.workoutId }
    private var enabledCategories: Set<String> { categories().union(["core"]) }

    var progress: SyncProgress {
        let s = outbox.state
        let detailTotal = max(s.workoutTotal, s.detailsDone.count)
        let done = (s.recentDone.contains(workoutId) ? 1 : 0) + (s.dailyFullAt != nil ? 1 : 0) + (s.caughtUp.contains(workoutId) ? 1 : 0) + s.detailsDone.count
        var p = SyncProgress(detailsDone: s.detailsDone.count, detailsTotal: detailTotal, isSyncing: running,
                             stepsDone: done, stepsTotal: 3 + detailTotal, phase: running ? phase : 0,
                             recentReady: s.recentDone.contains(workoutId) && s.dailyFullAt != nil)
        p.recentDone = s.recentDone.contains(workoutId)
        p.dailyDone = s.dailyFullAt != nil
        p.historyDone = s.caughtUp.contains(workoutId)
        p.stats = stats.snapshot()
        return p
    }

    /// Notifies the UI only when something visible changes (whole percent, step, flags).
    private func report(syncing: Bool) {
        var p = progress
        p.isSyncing = syncing
        let key = [Int(p.fraction * 100), p.phase, p.isSyncing ? 1 : 0, p.recentReady ? 1 : 0, p.historyComplete ? 1 : 0, p.detailsDone,
                   p.recentDone ? 1 : 0, p.dailyDone ? 1 : 0, p.historyDone ? 1 : 0, p.stats.version]
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
        // Steps that run alongside the workout raw data; always finished (or stopped) before the run returns,
        // so two runs never overlap.
        var background: [Task<Void, Error>] = []
        func stopBackground() async {
            for task in background { task.cancel() }
            for task in background { _ = await task.result }
        }
        do {
            // Listing every workout is slow on a large history, so it runs alongside the other startup steps.
            let source = self.source
            let indexTask = Task { try await SyncTiming.shared.measure("phase.index") { try await source.workoutIndex() } }
            defer { indexTask.cancel() }
            phase = 1
            try await step { try await SyncTiming.shared.measure("phase.recent") { try await self.recentWorkouts() } }
            // Years of daily history and the summaries of every workout take a minute or more on a large
            // history and do not depend on the raw data (or on each other), so they run alongside it: the raw
            // data starts as soon as the list of workouts is known.
            background.append(Task { try await self.step { try await SyncTiming.shared.measure("phase.daily") { try await self.dailyContext() } } })
            let history = Task {
                try await self.step {
                    guard let wt = self.scope.workout else { return }
                    try await SyncTiming.shared.measure("phase.history") {
                        while true {
                            try self.checkTime()
                            if try await self.anchoredPage(wt) { break }
                            self.report(syncing: true)
                        }
                    }
                }
            }
            background.append(history)
            background.append(Task { try await self.step { try await SyncTiming.shared.measure("phase.hourly") { try await self.hourlyHistory() } } })
            background.append(Task {
                try await self.step {
                    try await SyncTiming.shared.measure("phase.events") {
                        try await self.eventsSync()
                        try await self.profileSync()
                        try await self.medicationSync()
                    }
                }
            })
            phase = 4
            try await step {
                let index = try await indexTask.value
                try self.outbox.update { $0.workoutTotal = index.count }
                self.report(syncing: true)
                try await self.uploadDetails(index)
            }
            phase = 3
            report(syncing: true)
            try await history.value
            phase = 2
            report(syncing: true)
            for task in background { try await task.value }
            try await sendStatus()
        } catch is OutOfTime {
            await stopBackground()
            try? await sendStatus()
            return .outOfTime
        } catch {
            await stopBackground()
            throw error
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
            // A wake for new readings (glucose, a logged meal, heart rate) also sends those, not only workouts.
            try await eventsSync(force: true)
            try await hourlyHistory()
            try await profileSync()
            try await medicationSync()
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
        let records = try await SyncTiming.shared.measure("hk.recent") { try await source.workouts(from: start, to: end) }
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
    /// later is included), otherwise just the last few days. Rows go out per consent category, and a chunk whose
    /// content did not change since it was last sent is not sent again.
    /// Bump when daily rows sent by an older app may be incomplete: the next run re-reads the whole history once.
    /// 2: a failed HealthKit query used to drop its metric silently and the pass was recorded as complete.
    /// 3: the daily statistics queries now share the read gate (they failed under load and left their metrics out).
    /// 4: results of the daily metric queries were not all collected (most metrics never reported back).
    /// 5: the results were collected through captured variables and mostly lost on the phone's optimized build.
    /// 6: the same read again with the per-year probe that shows which way of asking Apple Health returns the older data.
    /// 7: read alone instead of next to the workout reads (older years came back empty under that load), with a retry of empty key metrics.
    /// 8: fall back to source-explicit statistics (and raw discrete samples) when HealthKit returns an empty collection for existing samples.
    static let dailyVersion = 9

    private func dailyContext() async throws {
        guard !scope.dailyMetrics.isEmpty else { return }
        if outbox.state.dailyVersion < Self.dailyVersion {
            try outbox.update { s in
                s.dailyFullAt = nil
                s.dailyHashes = [:]
                s.dailyVersion = Self.dailyVersion
            }
            lastDailyAt = nil
        }
        let end = now()
        // An update of an app that already synced reads the whole history once more, only to fill the totals on Home
        // (rows whose content did not change are not sent again).
        let full = (outbox.state.dailyFullAt.map { end.timeIntervalSince($0) > config.dailyFullEvery } ?? true) || stats.needsDailyBackfill
        if !full, let last = lastDailyAt, end.timeIntervalSince(last) < config.minRefresh { return }
        var start: Date
        if full {
            start = try await SyncTiming.shared.measure("hk.earliest") { try await source.earliestDailyDate() } ?? end.addingTimeInterval(-365 * 86_400)
        } else {
            start = end.addingTimeInterval(-Double(config.dailyIncrementalDays) * 86_400)
        }
        let cal = Calendar.current
        start = cal.startOfDay(for: start)
        let categories = enabledCategories
        // One year per batch set keeps memory and batch sizes bounded.
        var chunkStart = start
        // A year that cannot be read (Apple Health busy or locked) must not hold back the years after it, and the history is
        // then not recorded as complete, so the next run reads that year again (years already on the server are not re-sent).
        var firstReadFailure: Error?
        var pendingNotes: [String] = []
        var incomplete = false
        while chunkStart < end {
            try checkTime()
            let chunkEnd = min(cal.date(byAdding: .year, value: 1, to: chunkStart) ?? end, end)
            let started = Date()
            let batches: [DailyBatch]
            do {
                batches = try await SyncTiming.shared.measure("hk.dailyChunk") { try await source.dailyContextBatches(from: chunkStart, to: chunkEnd, categories: categories) }
            } catch is CancellationError {
                throw CancellationError()
            } catch is OutOfTime {
                throw OutOfTime()
            } catch {
                firstReadFailure = firstReadFailure ?? error
                pendingNotes.append("FAILED " + (source.dailyDiagnosticNote() ?? "daily read failed") + " err=\((error as NSError).domain)/\((error as NSError).code)")
                chunkStart = chunkEnd
                continue
            }
            let readMs = Self.ms(since: started)
            for batch in batches {
                // Categories other than core send nothing when they have no rows; core always reports (it advances the covered window).
                if batch.records.isEmpty && batch.category != "core" { continue }
                // The totals on Home come from the core rows (activity, sleep, recovery), counted even when they are not sent again.
                if batch.incomplete { incomplete = true }
                if batch.category == "core" {
                    stats.addDays(batch.records)
                    report(syncing: running)
                }
                let lines = try BatchWriter.encodeLines(batch.records)
                var digest = SHA256()
                for line in lines { digest.update(data: line) }
                let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                let key = full ? "full|\(batch.typeId)|\(Int64(chunkStart.timeIntervalSince1970))" : "inc|\(batch.typeId)"
                if outbox.state.dailyHashes[key] == hash && !batch.records.isEmpty { continue }
                var header = BatchHeader(type: batch.typeId, mode: .stats, seq: try outbox.nextSeq(batch.typeId), window: (chunkStart, chunkEnd), checkedAt: end)
                if batch.category == "core" || batch.note != nil {
                    header.note = (pendingNotes + [batch.note].compactMap { $0 }).joined(separator: " || ")
                    pendingNotes = []
                }
                try await sendLines(batch.typeId, header: header, lines: lines, anchor: nil, completes: .dailyHash(key: key, hash: hash), readMs: readMs)
            }
            chunkStart = chunkEnd
        }
        if let firstReadFailure { throw firstReadFailure }
        if full {
            // A chunk that lost values is read again in about six hours, not left as complete for a week.
            try outbox.update { $0.dailyFullAt = incomplete ? end.addingTimeInterval(-(config.dailyFullEvery - 6 * 3600)) : end }
            stats.markDailyBackfilled()
        }
        lastDailyAt = end
    }

    /// Hourly heart rate, steps and HRV: the whole history the first time (a year per batch), then the last few days
    /// about once an hour.
    /// Bump when hourly rows sent by an older app may be incomplete: the next run re-reads the whole history once.
    /// 2: a failed HealthKit query used to drop its series silently and the chunk was recorded as complete.
    /// 3: the same collection fix for the hourly queries' older chunks.
    /// 4: read alone instead of next to the workout reads.
    /// 5: use the same source-explicit fallback as daily history when older hourly collections are empty.
    static let hourlyVersion = 6

    private func hourlyHistory() async throws {
        guard !scope.hourly.isEmpty else { return }
        if outbox.state.hourlyVersion < Self.hourlyVersion {
            try outbox.update { s in
                s.hourlyThrough = nil
                s.hourlyAt = nil
                s.hourlyVersion = Self.hourlyVersion
            }
        }
        let end = now()
        var start: Date
        if let through = outbox.state.hourlyThrough {
            if let at = outbox.state.hourlyAt, end.timeIntervalSince(at) < config.hourlyEvery { return }
            start = through.addingTimeInterval(-Double(config.hourlyIncrementalDays) * 86_400)
        } else {
            start = try await SyncTiming.shared.measure("hk.earliest") { try await source.earliestDailyDate() } ?? end.addingTimeInterval(-365 * 86_400)
        }
        let cal = Calendar.current
        start = cal.startOfDay(for: start)
        var chunkStart = start
        while chunkStart < end {
            try checkTime()
            let chunkEnd = min(cal.date(byAdding: .year, value: 1, to: chunkStart) ?? end, end)
            let started = Date()
            let records = try await SyncTiming.shared.measure("hk.hourlyChunk") { try await source.hourlySeries(from: chunkStart, to: chunkEnd) }
            let readMs = Self.ms(since: started)
            let last = chunkEnd >= end
            if records.isEmpty {
                try outbox.update { s in
                    s.hourlyThrough = max(s.hourlyThrough ?? chunkEnd, chunkEnd)
                    if last { s.hourlyAt = end }
                }
            } else {
                let id = HealthTypes.hourlyId
                var header = BatchHeader(type: id, mode: .stats, seq: try outbox.nextSeq(id), window: (chunkStart, chunkEnd), checkedAt: end)
                header.note = source.hourlyDiagnosticNote()
                try await send(id, header: header, records: records, anchor: nil, completes: .hourly(through: chunkEnd, at: last ? end : nil), readMs: readMs)
            }
            chunkStart = chunkEnd
        }
    }

    /// Events and timed entries of every switched-on category, each type as its own anchored pass.
    private func eventsSync(force: Bool = false) async throws {
        let categories = enabledCategories
        let now = self.now()
        if !force, let last = lastEventsAt, now.timeIntervalSince(last) < config.minRefresh { return }
        for event in scope.events where categories.contains(event.category) && event.sampleType != nil {
            let type = SyncType(id: event.typeId, kind: .events, sampleType: event.sampleType, event: event)
            while true {
                try checkTime()
                if try await anchoredPage(type) { break }
            }
        }
        lastEventsAt = now
    }

    /// The profile entry (date of birth, sex, wheelchair use, move mode): sent once, then about weekly.
    private func profileSync() async throws {
        guard enabledCategories.contains("profile"), scope.events.contains(where: { $0.kind == .characteristic }) else { return }
        let at = now()
        if let last = outbox.state.profileAt, at.timeIntervalSince(last) < config.profileEvery { return }
        let records = try await source.profileRecords()
        guard !records.isEmpty else { return }
        let type = "_events_profile"
        let header = BatchHeader(type: type, mode: .anchored, seq: try outbox.nextSeq(type), checkedAt: at)
        try await send(type, header: header, records: records, anchor: nil, completes: .profileAt(at))
    }

    /// The medication list (names only) the user chose to share: sent once, then about weekly.
    private func medicationSync() async throws {
        guard enabledCategories.contains("medications"), scope.events.contains(where: { $0.kind == .medication }) else { return }
        let at = now()
        if let last = outbox.state.medicationsAt, at.timeIntervalSince(last) < config.profileEvery { return }
        let records = try await source.medicationRecords()
        guard !records.isEmpty else { return }
        let type = "_events_medications"
        let header = BatchHeader(type: type, mode: .anchored, seq: try outbox.nextSeq(type), checkedAt: at)
        try await send(type, header: header, records: records, anchor: nil, completes: .medicationsAt(at))
    }

    /// A category was switched off: forget what was synced for it, so switching it on again sends it from the beginning.
    func categoryDisabled(_ id: String) throws {
        let eventIds = scope.events.filter { $0.category == id }.map(\.typeId)
        let daily = HealthTypes.dailyBatchType(id)
        try outbox.update { s in
            for key in eventIds {
                s.anchors[key] = nil
                s.caughtUp.remove(key)
            }
            s.dailyHashes = s.dailyHashes.filter { !$0.key.contains("|\(daily)|") && $0.key != "inc|\(daily)" }
            if id == "profile" { s.profileAt = nil }
            if id == "medications" { s.medicationsAt = nil }
        }
    }

    /// A category was switched on: re-read the daily history so its rows are included.
    func categoryEnabled(_ id: String) throws {
        try outbox.update { $0.dailyFullAt = nil }
        lastDailyAt = nil
        lastEventsAt = nil
    }

    /// One anchored page of workout summaries. Returns true when caught up.
    private func anchoredPage(_ t: SyncType) async throws -> Bool {
        let reconcileId = outbox.state.reconcile[t.id]
        let anchor = outbox.state.anchors[t.id]
        let checked = now()
        let limit = t.kind == .events ? config.eventPageLimit : config.workoutPageLimit
        let started = Date()
        let page = try await SyncTiming.shared.measure(t.kind == .events ? "hk.events" : "hk.history") { try await source.anchoredPage(t, anchor: anchor, limit: limit) }
        let readMs = Self.ms(since: started)
        let caughtUp = page.objectCount < limit
        if page.objectCount == 0 && reconcileId == nil {
            if t.kind == .events {
                // Nothing (new): remember the position so the next pass starts here; nothing to report to the server.
                try outbox.update { s in
                    if let a = page.newAnchor { s.anchors[t.id] = a }
                    s.caughtUp.insert(t.id)
                }
                return true
            }
            // Nothing new: reported in a status batch, at most once an hour once caught up.
            if outbox.state.caughtUp.contains(t.id), let last = lastEmptyCheck[t.id], checked.timeIntervalSince(last) < 3600 { return true }
            lastEmptyCheck[t.id] = checked
            statusPending[t.id] = checked
            return true
        }
        let header = BatchHeader(
            type: t.headerType, mode: reconcileId == nil ? .anchored : .reconcile, seq: try outbox.nextSeq(t.id),
            caughtUp: caughtUp, checkedAt: checked, reconcileId: reconcileId, reconcileDone: reconcileId == nil ? nil : caughtUp)
        let completes: Outbox.Completion? = caughtUp ? (reconcileId == nil ? .caughtUp : .reconcileDone) : nil
        try await send(t.id, header: header, records: page.records, anchor: page.newAnchor, completes: completes, readMs: readMs)
        return caughtUp
    }

    /// Reads and uploads the raw data of every workout that has none on the server yet, newest first.
    /// Workouts are read several at a time and sent in groups (one upload per group). While one group
    /// is being written and uploaded, the next is already being read from HealthKit.
    private func uploadDetails(_ index: [WorkoutRef]) async throws {
        if outbox.state.detailVersion < Self.detailVersion {
            try outbox.update {
                $0.detailsDone = []
                $0.detailVersion = Self.detailVersion
            }
        }
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
        // The next two groups are read while this one is still finishing and while earlier ones upload.
        var reads: [Int: Task<[EncodedWorkout?], Error>] = [:]
        defer { reads.values.forEach { $0.cancel() } }
        // Uploads of earlier groups, oldest first; they finish while later groups are read.
        var sending: [Task<Void, Error>] = []
        do {
            for (i, group) in groups.enumerated() {
                for j in i ... min(i + 2, groups.count - 1) where reads[j] == nil { reads[j] = read(groups[j]) }
                let results = try await timing.measure("detail.readWait") { try await reads[i]!.value }
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
                        stats.setDetail(workoutId: ref.id, heartRate: found.heartRate, gpsPoints: found.gpsPoints)
                    } else {
                        empty.append(ref.id)
                    }
                }
                if lines.isEmpty {
                    if !empty.isEmpty { try outbox.update { $0.detailsDone.formUnion(empty) } }
                } else {
                    // Workouts without raw data ride along in the same completion: one state write per group.
                    let completes = Outbox.Completion.detailsDone(withData + empty)
                    if config.detailGroupsUploading > 1 {
                        let entry = try await enqueueDetails(lines, completes: completes)
                        sending.append(Task { try await self.flushEntry(entry) })
                        while sending.count >= config.detailGroupsUploading {
                            let oldest = sending.removeFirst()
                            try await timing.measure("detail.send") { try await oldest.value }
                        }
                    } else {
                        let id = HealthTypes.streamId
                        let header = BatchHeader(type: id, mode: .workoutdata, seq: try outbox.nextSeq(id), checkedAt: now())
                        try await timing.measure("detail.send") {
                            try await self.sendLines(id, header: header, lines: lines, anchor: nil, completes: completes)
                        }
                    }
                }
                timing.count("detail.records", recordCount)
                timing.count("detail.workouts", group.count)
                timing.checkpoint("details \(min((i + 1) * size, todo.count))/\(todo.count)")
                report(syncing: true)
            }
            while !sending.isEmpty {
                let oldest = sending.removeFirst()
                try await timing.measure("detail.send") { try await oldest.value }
                report(syncing: true)
            }
            timing.markDetailsEnd()
        } catch {
            // Stop the uploads still running; what they did not finish stays in the outbox for the next run.
            sending.forEach { $0.cancel() }
            for task in sending { _ = try? await task.value }
            throw error
        }
    }

    /// Compresses one group's raw data into parts (at the same time, off the actor) and saves them to the outbox.
    private func enqueueDetails(_ lines: [Data], completes: Outbox.Completion) async throws -> Outbox.Entry {
        let id = HealthTypes.streamId
        let limit = max(1, config.detailPartBytes)
        var parts: [[Data]] = [[]]
        var bytes = 0
        for line in lines {
            if !parts[parts.count - 1].isEmpty && bytes + line.count + 1 > limit {
                parts.append([])
                bytes = 0
            }
            parts[parts.count - 1].append(line)
            bytes += line.count + 1
        }
        // One sequence number per part, plus spares in case a part still has to be split (gaps are harmless).
        let first = try outbox.reserveSeqs(id, count: parts.count * 2)
        let spares = SeqPool(start: first + Int64(parts.count))
        var header = BatchHeader(type: id, mode: .workoutdata, seq: first, checkedAt: now())
        header.uploadMs = lastUploadMs
        let (device, appVersion, tz, at) = (config.device, config.appVersion, timeZone(), now())
        let batches: [Batch] = try await SyncTiming.shared.measure("batch.compress") {
            try await withThrowingTaskGroup(of: (Int, [Batch]).self) { group in
                for (i, part) in parts.enumerated() {
                    var h = header
                    h.seq = first + Int64(i)
                    let partHeader = h
                    group.addTask {
                        (i, try BatchWriter.make(header: partHeader, lines: part, nextSeq: { spares.take() }, now: at, tz: tz, device: device, appVersion: appVersion))
                    }
                }
                var out = [[Batch]](repeating: [], count: parts.count)
                for try await (i, made) in group { out[i] = made }
                return out.flatMap { $0 }
            }
        }
        SyncTiming.shared.count("upload.bytes", batches.reduce(0) { $0 + $1.gz.count })
        SyncTiming.shared.count("upload.batches", batches.count)
        return try SyncTiming.shared.measureSync("outbox.enqueue") { try outbox.enqueue(typeId: id, batches: batches, anchor: nil, completes: completes) }
    }

    /// A workout's raw-data records, already encoded as JSON lines (done while reading, in parallel).
    private struct EncodedWorkout: Sendable {
        var lines: [Data]
        var recordCount: Int
        /// Heart rate readings and GPS points promised by the workout's closing marker.
        var heartRate = 0
        var gpsPoints = 0
    }

    /// Point counts per stream from a workout's closing `wd` marker.
    private static func pointCounts(_ records: [Record]) -> (heartRate: Int, gps: Int) {
        guard let mark = records.last(where: { $0["k"]?.statText == "wd" }), let expected = mark["expected"]?.statObject else { return (0, 0) }
        return (Int(expected["HeartRate"]?.statNumber ?? 0), Int(expected["route"]?.statNumber ?? 0))
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
                    let counts = Self.pointCounts(records)
                    return (i, EncodedWorkout(lines: lines, recordCount: records.count, heartRate: counts.heartRate, gpsPoints: counts.gps))
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
        // Totals for the big numbers on Home: workout summaries and daily rows are counted as they are read.
        if typeId == workoutId {
            stats.addWorkoutSummaries(records)
        }
        report(syncing: running)
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
        for entry in outbox.pending() where (typeId == nil || entry.typeId == typeId) && !uploading.contains(entry.id) {
            try await flushEntry(entry)
        }
    }

    /// Uploads what is left of one outbox entry and completes it.
    private func flushEntry(_ entry: Outbox.Entry) async throws {
        uploading.insert(entry.id)
        defer { uploading.remove(entry.id) }
        var entry = entry
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
            return
        }
        try outbox.complete(entry)
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

/// Spare sequence numbers handed out from any thread (reserved in advance; the server only needs batch ids unique).
private final class SeqPool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(start: Int64) { value = start }

    func take() -> Int64 {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
