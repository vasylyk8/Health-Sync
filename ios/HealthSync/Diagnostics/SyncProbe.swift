import Foundation
import Darwin
import UIKit

/// Counts/timings only. Nil outside a selected diagnostic or passive recorder.
enum SyncProbe {
    @TaskLocal static var recorder: SyncProbeRecorder?
    @TaskLocal static var metric = "sync"
    @TaskLocal static var window = ""
    @TaskLocal static var runSalt = UUID().uuidString
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
            if trace { if events.count < 50_000 { events.append(Event(name: t.name, metric: t.metric, window: t.window, start: t.start, end: end, error: error, count: count)) } else { dropped += 1 } }
        }
    }
    @MainActor func sampleDevice() {
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
    func snapshot() -> Snapshot {
        lock.withLock { let elapsed = ProcessInfo.processInfo.systemUptime - origin; return Snapshot(schema: 1, elapsed: elapsed, stats: stats, events: events, devices: devices, counters: counters, droppedTraceEvents: dropped, oldestActiveSeconds: active.values.map { elapsed - $0.start }.max() ?? 0, active: active.count) }
    }
    static func unionDuration(_ events: [Event]) -> Double {
        var end = -Double.infinity, total = 0.0
        for e in events.sorted(by: { $0.start < $1.start }) { total += max(0, e.end - max(e.start, end)); end = max(end, e.end) }
        return total
    }
    func summary() -> String {
        let s = snapshot(), top = s.stats.sorted { $0.value.total > $1.value.total }.prefix(20)
        return "Elapsed \(String(format: "%.2f", s.elapsed))s · \(s.active) operations active · oldest \(Int(s.oldestActiveSeconds))s\n" + top.map { key, v in String(format: "%@: %d calls · %.2fs accumulated (overlaps) · p50 %.3fs · p95≈%.3fs · max %.3fs · %d items · %d errors", key, v.count, v.total, v.p50, v.p95, v.maximum, v.items, v.errors) }.joined(separator: "\n")
    }
}
