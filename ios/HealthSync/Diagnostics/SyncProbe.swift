import Foundation
import Darwin
import UIKit

/// Counts/timings only. Nil outside a selected diagnostic or passive recorder.
enum SyncProbe {
    @TaskLocal static var recorder: SyncProbeRecorder?
    @TaskLocal static var metric = "sync"
    @TaskLocal static var window = ""
    @TaskLocal static var runSalt = UUID().uuidString
    @TaskLocal static var statisticsFault = ""
    @TaskLocal static var rawCapture: RawReplayStore?
    static func begin(_ name: String) -> SyncProbeRecorder.Token? { recorder?.begin(name, metric: metric, window: window) }
    static func end(_ token: SyncProbeRecorder.Token?, error: Bool = false, count: Int = 0) { if let token { recorder?.end(token, error: error, count: count) } }
    static func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let t = begin(name)
        do { let result = try await body(); end(t); return result } catch { end(t, error: true); throw error }
    }
    static func measureSync<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let t = begin(name)
        do { let result = try body(); end(t); return result } catch { end(t, error: true); throw error }
    }
}

final class SyncProbeRecorder: @unchecked Sendable {
    struct Token: Sendable { let id: UUID; let name: String; let metric: String; let window: String; let start: Double }
    struct Event: Codable, Sendable { let name: String; let metric: String; let window: String; let start: Double; let end: Double; let error: Bool; let count: Int }
    struct Stat: Codable, Sendable {
        var count = 0, errors = 0, items = 0
        var total = 0.0, maximum = 0.0
        var samples: [Double] = []
        var p50: Double { percentile(0.5) }; var p95: Double { percentile(0.95) }
        func percentile(_ p: Double) -> Double { let a = samples.sorted(); return a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count - 1) * p))] }
    }
    struct DeviceSample: Codable, Sendable {
        let at: Double; let thermal: Int; let lowPower: Bool; let cpuSeconds: Double; let residentBytes: UInt64
        let battery: Float; let charging: Bool; let foreground: Bool; let protectedData: Bool
    }
    struct Snapshot: Codable, Sendable {
        let schema: Int; let elapsed: Double; let stats: [String: Stat]; let events: [Event]
        let devices: [DeviceSample]; let counters: [String: Int]; let droppedTraceEvents: Int; let oldestActiveSeconds: Double; let active: Int
    }
    private let lock = NSLock()
    private let origin = ProcessInfo.processInfo.systemUptime
    private var stats: [String: Stat] = [:], events: [Event] = [], devices: [DeviceSample] = []
    private var active: [UUID: Token] = [:]
    private var dropped = 0
    private var counters: [String: Int] = [:]
    let trace: Bool
    static let traceCap = 20_000
    init(trace: Bool = true) { self.trace = trace }
    func begin(_ name: String, metric: String, window: String) -> Token {
        let t = Token(id: UUID(), name: name, metric: metric, window: window, start: ProcessInfo.processInfo.systemUptime - origin)
        lock.withLock { active[t.id] = t }; return t
    }
    func end(_ t: Token, error: Bool = false, count: Int = 0) {
        let end = ProcessInfo.processInfo.systemUptime - origin, duration = max(0, end - t.start)
        lock.withLock {
            guard active.removeValue(forKey: t.id) != nil else { return }
            let key = [t.metric, t.window, t.name].joined(separator: "|")
            var s = stats[key] ?? Stat(); s.count += 1; s.errors += error ? 1 : 0; s.items += count; s.total += duration; s.maximum = max(s.maximum, duration)
            if s.samples.count < 512 { s.samples.append(duration) } else { let index = Int.random(in: 0..<s.count); if index < 512 { s.samples[index] = duration } }
            stats[key] = s
            // The few phase.* events carry the timeline and completion-tail analysis, so the cap must never drop them.
            if trace { if events.count < Self.traceCap || t.name.hasPrefix("phase.") { events.append(Event(name: t.name, metric: t.metric, window: t.window, start: t.start, end: end, error: error, count: count)) } else { dropped += 1 } }
        }
    }
    @MainActor func sampleDevice() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        let d = DeviceSample(at: ProcessInfo.processInfo.systemUptime - origin, thermal: ProcessInfo.processInfo.thermalState.rawValue, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, cpuSeconds: cpu, residentBytes: result == KERN_SUCCESS ? info.resident_size : 0, battery: UIDevice.current.batteryLevel, charging: UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full, foreground: UIApplication.shared.applicationState == .active, protectedData: UIApplication.shared.isProtectedDataAvailable)
        lock.withLock { devices.append(d) }
    }
    /// Aggregated loop timings: no fabricated timeline events and no per-sample locking.
    func duration(_ name: String, seconds: Double, items: Int) {
        let key = [SyncProbe.metric, SyncProbe.window, name].joined(separator: "|")
        lock.withLock { var s = stats[key] ?? Stat(); s.count += 1; s.items += items; s.total += max(0, seconds); s.maximum = max(s.maximum, seconds); if s.samples.count < 512 { s.samples.append(seconds) }; stats[key] = s }
    }
    func count(_ name: String, _ value: Int = 1) { lock.withLock { counters[name, default: 0] += value } }
    func set(_ name: String, _ value: Int) { lock.withLock { counters[name] = value } }
    /// `compact` is for the stored report: per-workout operation statistics are kept only for the slowest few hundred, and the
    /// rest are folded into their cohort (same metric, age and type) so a 3,000-workout history does not make a 50 MB report.
    func snapshot(compact: Bool = false) -> Snapshot {
        lock.withLock { let elapsed = ProcessInfo.processInfo.systemUptime - origin; return Snapshot(schema: 1, elapsed: elapsed, stats: compact ? Self.compacted(stats) : stats, events: events, devices: devices, counters: counters, droppedTraceEvents: dropped, oldestActiveSeconds: active.values.map { elapsed - $0.start }.max() ?? 0, active: active.count) }
    }
    static func compacted(_ stats: [String: Stat], keepLocal: Int = 300) -> [String: Stat] {
        let local = stats.filter { $0.key.contains("|local=") }
        guard local.count > keepLocal else { return stats }
        var out = stats.filter { !$0.key.contains("|local=") }
        let keep = Set(local.sorted { $0.value.total > $1.value.total }.prefix(keepLocal).map(\.key))
        for (key, stat) in local {
            if keep.contains(key) { out[key] = stat; continue }
            let folded = key.split(separator: "|", omittingEmptySubsequences: false).filter { !$0.hasPrefix("local=") }.joined(separator: "|")
            var merged = out[folded] ?? Stat()
            merged.count += stat.count; merged.errors += stat.errors; merged.items += stat.items; merged.total += stat.total
            merged.maximum = max(merged.maximum, stat.maximum)
            if merged.samples.count < 512 { merged.samples.append(contentsOf: stat.samples.prefix(512 - merged.samples.count)) }
            out[folded] = merged
        }
        return out
    }
    static func unionDuration(_ events: [Event]) -> Double {
        var end = -Double.infinity, total = 0.0
        for e in events.sorted(by: { $0.start < $1.start }) { total += max(0, e.end - max(e.start, end)); end = max(end, e.end) }
        return total
    }
    func summary() -> String {
        let s = snapshot(), top = s.stats.sorted { $0.value.total > $1.value.total }.prefix(20)
        let phases = Dictionary(grouping: s.events.filter { $0.name.hasPrefix("phase.") }, by: \.name)
        let phaseText = phases.sorted { $0.key < $1.key }.map { key, events in String(format: "%@: %.2fs active, finished at %.2fs", key, Self.unionDuration(events), events.map(\.end).max() ?? 0) }.joined(separator: "\n")
        let finishes = phases.map { ($0.key, $0.value.map(\.end).max() ?? 0) }.sorted { $0.1 > $1.1 }
        let tailText = finishes.count > 1 ? String(format: "Completion tail: %@ finished last at %.2fs, %.2fs after %@ (%.2fs).", finishes[0].0, finishes[0].1, finishes[0].1 - finishes[1].1, finishes[1].0, finishes[1].1) + "\n" : ""
        let deviceText: String
        if let first = s.devices.first, let last = s.devices.last {
            deviceText = String(format: "Process CPU %.2fs · peak resident %.1f MB · thermal max %d · trace dropped %d", last.cpuSeconds - first.cpuSeconds, Double(s.devices.map(\.residentBytes).max() ?? 0) / 1_000_000, s.devices.map(\.thermal).max() ?? 0, s.droppedTraceEvents)
        } else { deviceText = "Device sampling unavailable" }
        return phaseText + "\n" + tailText + deviceText + "\nElapsed \(String(format: "%.2f", s.elapsed))s · \(s.active) operations active · oldest \(Int(s.oldestActiveSeconds))s\n" + top.map { key, v in String(format: "%@: %d calls · %.2fs accumulated (overlaps) · p50 %.3fs · p95≈%.3fs · max %.3fs · %d items · %d errors", key, v.count, v.total, v.p50, v.p95, v.maximum, v.items, v.errors) }.joined(separator: "\n")
    }
}
