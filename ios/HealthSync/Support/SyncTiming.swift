import Foundation
import os

/// On-device timing of the sync, for finding where time goes. Intervals show up in Instruments
/// (os_signpost / Points of Interest, subsystem "app.healthsync", category "sync"), a summary is
/// logged as it goes and written to `sync-timing.json` in Application Support. Never contains health values.
final class SyncTiming: @unchecked Sendable {
    private static let production = SyncTiming()
    @TaskLocal static var diagnostic: SyncTiming?
    static var shared: SyncTiming { diagnostic ?? production }

    private let persistEnabled: Bool
    init(persistEnabled: Bool = true) { self.persistEnabled = persistEnabled }

    private let log = Logger(subsystem: "app.healthsync", category: "sync")
    private let signposter = OSSignposter(subsystem: "app.healthsync", category: "sync")
    private let lock = NSLock()

    private struct Stat: Codable {
        var count = 0
        var totalMs = 0.0
        var maxMs = 0.0
    }

    private var stats: [String: Stat] = [:]
    /// Operations still running (name -> start times), to show what a stalled sync is waiting on.
    private var inFlight: [String: [UUID: Date]] = [:]
    private var counters: [String: Int] = [:]
    private let started = Date()
    private var detailStart: Date?
    private var detailEnd: Date?
    /// CPU seconds used by this process (all threads), to tell whether the app itself is the limit.
    private var cpuAtStart = 0.0
    private var lastCpu = 0.0
    private var lastWall = Date()
    private var recentCores = 0.0

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }
    private var lastWrite = Date.distantPast

    /// Times `body` under `name` (a phase such as "detail.read", "upload", "outbox.enqueue").
    func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let probe = SyncProbe.begin("\(name)"); defer { SyncProbe.end(probe) }
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let token = UUID()
        lock.withLock { inFlight["\(name)", default: [:]][token] = Date() }
        defer {
            signposter.endInterval(name, state)
            lock.withLock { inFlight["\(name)"]?[token] = nil }
            record("\(name)", ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return try await body()
    }

    func measureSync<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let probe = SyncProbe.begin("\(name)"); defer { SyncProbe.end(probe) }
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            record("\(name)", ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return try body()
    }

    /// Counts and durations only; run-local diagnostics never reuse the production session.
    func diagnosticSummary() -> String {
        lock.withLock {
            let names = ["detail.readWait", "detail.send", "detail.encode", "batch.encode", "batch.compress", "outbox.enqueue", "upload"]
            return names.map { name in
                String(format: "%@=%.2fs", name, (stats[name]?.totalMs ?? 0) / 1000)
            }.joined(separator: " ")
        }
    }

    /// Marks the start of Step 4 (raw workout data) so the live speed is measured from there.
    func markDetailsStart() {
        lock.withLock {
            guard detailStart == nil else { return }
            detailStart = Date()
            cpuAtStart = Self.cpuSeconds()
            lastCpu = cpuAtStart
            lastWall = Date()
        }
    }

    /// Marks the end of Step 4, so its total time and upload speed can be reported.
    func markDetailsEnd() {
        lock.withLock { if detailStart != nil { detailEnd = Date() } }
    }

    /// What the sync is doing right now, for the sync screen during steps 1-3 (and when it seems stuck):
    /// finished steps with their time, the running step with its time so far, and HealthKit reads and
    /// uploads still in progress with the age of the oldest. No health data.
    func startupSummary() -> String {
        lock.withLock {
            let now = Date()
            var parts: [String] = []
            for (key, label) in [("phase.index", "list"), ("phase.recent", "recent"), ("phase.daily", "daily"), ("phase.history", "history")] {
                if let running = inFlight[key]?.values.min() {
                    parts.append("\(label) \(Int(now.timeIntervalSince(running)))s so far")
                } else if let s = stats[key] {
                    parts.append("\(label) \(Int(s.totalMs / 1000))s")
                }
            }
            func busy(_ key: String, _ label: String) -> String? {
                guard let starts = inFlight[key], let oldest = starts.values.min() else { return nil }
                return "\(starts.count) \(label) running (oldest \(Int(now.timeIntervalSince(oldest)))s)"
            }
            let waits = [busy("hk.recent", "recent-workout reads"), busy("hk.earliest", "oldest-date reads"),
                         busy("hk.dailyChunk", "daily-year reads"), busy("hk.daily", "daily metric reads"),
                         busy("hk.history", "workout-list pages"), busy("upload", "uploads")].compactMap { $0 }
            let uploads = stats["upload"]?.count ?? 0
            return (["startup: " + (parts.isEmpty ? "starting" : parts.joined(separator: " · "))] + waits + ["\(uploads) uploads done"]).joined(separator: "\n")
        }
    }

    /// One line for the sync screen while Step 4 runs, so speed can be read (and screenshotted) without files.
    func liveSummary() -> String? {
        lock.withLock {
            guard let start = detailStart, let workouts = counters["detail.workouts"], workouts > 0 else { return nil }
            let minutes = max(Date().timeIntervalSince(start) / 60, 0.01)
            func avg(_ key: String, _ scale: Double = 1000) -> String {
                guard let s = stats[key], s.count > 0 else { return "-" }
                return String(format: "%.2f", s.totalMs / Double(s.count) / scale)
            }
            let uploads = stats["upload"]?.count ?? 0
            let mb = uploads > 0 ? Double(counters["upload.bytes"] ?? 0) / Double(uploads) / 1_000_000 : 0
            let rate = String(format: "%.1f", Double(workouts) / minutes)
            let perWorkout = String(format: "%.0f", Double(counters["hk.samples"] ?? 0) / Double(max(counters["hk.workouts"] ?? 0, 1)))
            func secs(_ key: String) -> String { stats[key].map { String(format: "%.0f", $0.totalMs / 1000) } ?? "-" }
            let wall = max(Date().timeIntervalSince(start), 0.001)
            let waits = String(format: "waiting on uploads %.0f%%, on Apple Health %.0f%%", (stats["detail.send"]?.totalMs ?? 0) / 10 / wall, (stats["detail.readWait"]?.totalMs ?? 0) / 10 / wall)
            let startup = "startup: list \(secs("phase.index"))s · recent \(secs("phase.recent"))s · daily \(secs("phase.daily"))s · history \(secs("phase.history"))s"
            // CPU used by the app (1.0 = one core fully busy): near a full core means the app's own work is the limit.
            let cpuNow = Self.cpuSeconds()
            let wallNow = Date()
            let avgCores = (cpuNow - cpuAtStart) / max(wallNow.timeIntervalSince(start), 0.1)
            if wallNow.timeIntervalSince(lastWall) >= 10 {
                recentCores = (cpuNow - lastCpu) / wallNow.timeIntervalSince(lastWall)
                lastCpu = cpuNow
                lastWall = wallNow
            }
            let heat: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: heat = "normal"
            case .fair: heat = "warm"
            case .serious: heat = "hot"
            case .critical: heat = "critical"
            @unknown default: heat = "?"
            }
            let device = "app cpu \(String(format: "%.2f", avgCores)) cores avg, \(String(format: "%.2f", recentCores)) now (of \(ProcessInfo.processInfo.activeProcessorCount)) · heat \(heat) · low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off")"
            return startup + "\n" + device + "\n" + "\(rate) workouts/min · \(counters["read.limit"] ?? 0) queries in flight · \(perWorkout) samples per workout · \(String(format: "%.0f", Double(counters["hk.samples"] ?? 0) / max(Date().timeIntervalSince(start), 1))) samples/s · read \(avg("detail.read"))s per workout · encode \(avg("detail.encode"))s per workout · compress \(avg("batch.compress"))s · save \(avg("outbox.enqueue"))s · upload \(avg("upload"))s per batch (\(String(format: "%.1f", mb)) MB) · \(uploads) uploads · \(waits)"
        }
    }

    var experimentSummary: String {
        lock.withLock { counters.keys.filter { $0.hasPrefix("experiment.") }.sorted().map { "\($0)=\(counters[$0]!)" }.joined(separator: " ") }
    }

    /// Upload numbers of this app session's sync, for the speed test (nil before the first upload).
    func uploadSummary() -> String? {
        lock.withLock {
            guard let s = stats["upload"], s.count > 0 else { return nil }
            let bytes = Double(counters["upload.bytes"] ?? 0)
            let batches = Double(max(counters["upload.batches"] ?? s.count, 1))
            let avgSecs = s.totalMs / Double(s.count) / 1000
            let mb = bytes / batches / 1_000_000
            let workouts = counters["detail.workouts"] ?? 0
            var line = String(format: "last sync: %d uploads, %.2f MB each, %.2f s each (max %.1f s), %.2f MB/s per upload, %d workouts read, %.1f workouts per upload",
                              s.count, mb, avgSecs, s.maxMs / 1000, mb / max(avgSecs, 0.001), workouts, Double(workouts) / Double(s.count))
            if let start = detailStart {
                let wall = max((detailEnd ?? Date()).timeIntervalSince(start), 0.001)
                func share(_ key: String) -> Double { (stats[key]?.totalMs ?? 0) / 1000 / wall * 100 }
                // Mostly waiting on uploads: the network is the limit. Mostly waiting on reads: Apple Health is.
                line += String(format: " · step 4 %@ %.0f s, %.0f workouts/min, %.2f MB/s all uploads together, %.0f%% waiting on uploads, %.0f%% waiting on Apple Health",
                               detailEnd == nil ? "so far" : "took", wall, Double(workouts) / wall * 60, bytes / wall / 1_000_000, share("detail.send"), share("detail.readWait"))
            }
            return line
        }
    }

    /// A value that is replaced, not added to (for example the current number of parallel readers).
    func set(_ name: String, _ value: Int) {
        SyncProbe.recorder?.set(name, value)
        lock.withLock { counters[name] = value }
    }

    func count(_ name: String, _ n: Int = 1) {
        SyncProbe.recorder?.count(name, n)
        lock.withLock { counters[name, default: 0] += n }
    }

    private func record(_ name: String, ms: Double) {
        lock.withLock {
            var s = stats[name, default: Stat()]
            s.count += 1
            s.totalMs += ms
            s.maxMs = max(s.maxMs, ms)
            stats[name] = s
        }
    }

    /// Logs (and every 30 s persists) the running summary. Call after each group of workouts.
    func checkpoint(_ label: String) {
        let text: String = lock.withLock {
            let parts = stats.sorted { $0.key < $1.key }.map { k, s in
                "\(k)=\(s.count)x avg \(Int(s.totalMs / Double(max(s.count, 1))))ms max \(Int(s.maxMs))ms total \(Int(s.totalMs / 1000))s"
            }
            let c = counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return "\(label) elapsed \(Int(Date().timeIntervalSince(started)))s | " + (parts + c).joined(separator: " | ")
        }
        log.info("\(text, privacy: .public)")
        persistIfDue()
    }

    private func persistIfDue() {
        guard persistEnabled else { return }
        let snapshot: (Data, Bool) = lock.withLock {
            guard Date().timeIntervalSince(lastWrite) > 30 else { return (Data(), false) }
            lastWrite = Date()
            struct Dump: Codable {
                var elapsedS: Int
                var stats: [String: Stat]
                var counters: [String: Int]
            }
            let dump = Dump(elapsedS: Int(Date().timeIntervalSince(started)), stats: stats, counters: counters)
            return ((try? JSONEncoder().encode(dump)) ?? Data(), true)
        }
        guard snapshot.1, let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? snapshot.0.write(to: base.appendingPathComponent("sync-timing.json"), options: .atomic)
    }
}
