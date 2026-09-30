import Foundation
import os

/// On-device timing of the sync, for finding where time goes. Intervals show up in Instruments
/// (os_signpost / Points of Interest, subsystem "app.healthsync", category "sync"), a summary is
/// logged as it goes and written to `sync-timing.json` in Application Support. Never contains health values.
final class SyncTiming: @unchecked Sendable {
    static let shared = SyncTiming()

    private let log = Logger(subsystem: "app.healthsync", category: "sync")
    private let signposter = OSSignposter(subsystem: "app.healthsync", category: "sync")
    private let lock = NSLock()

    private struct Stat: Codable {
        var count = 0
        var totalMs = 0.0
        var maxMs = 0.0
    }

    private var stats: [String: Stat] = [:]
    private var counters: [String: Int] = [:]
    private let started = Date()
    private var lastWrite = Date.distantPast

    /// Times `body` under `name` (a phase such as "detail.read", "upload", "outbox.enqueue").
    func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            record("\(name)", ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return try await body()
    }

    func measureSync<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            record("\(name)", ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return try body()
    }

    func count(_ name: String, _ n: Int = 1) {
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
