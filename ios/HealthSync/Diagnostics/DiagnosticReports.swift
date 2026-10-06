import Foundation
import HealthKit

struct DiagnosticCoverage: Codable, Sendable {
    let family: String, metric: String, category: String
    var enabled: Bool, status: String, records: Int = 0
    static func inventory(_ scope: SyncScope, categories: Set<String>) -> [Self] {
        var a = scope.dailyMetrics.map { Self(family: "daily", metric: $0.key, category: $0.category, enabled: categories.contains($0.category), status: "not tested") }
        a += scope.hourly.map { Self(family: "hourly", metric: $0.name, category: "core", enabled: true, status: "not tested") }
        a += scope.workoutQuantities.map { Self(family: "workout quantity", metric: $0.name, category: "core", enabled: true, status: "not tested") }
        a += scope.events.map { Self(family: "event", metric: $0.name, category: $0.category, enabled: categories.contains($0.category), status: "not tested") }
        a += ["summaries", "routes", "series", "profile"].map { Self(family: "other", metric: $0, category: "core", enabled: true, status: "not tested") }
        if let file = HealthTypes.loadCoverage() {
            let supported = HealthTypes.scope(file)
            for m in file.dailyMetrics where !supported.dailyMetrics.contains(where: { $0.key == m.key }) { a.append(Self(family: "daily", metric: m.key, category: m.category ?? "core", enabled: false, status: "unavailable type/unit on this OS")) }
            for m in file.hourlyMetrics ?? [] where !supported.hourly.contains(where: { $0.name == m.name }) { a.append(Self(family: "hourly", metric: m.name, category: "core", enabled: false, status: "unavailable type/unit on this OS")) }
            for m in file.workoutQuantityTypes where !supported.workoutQuantities.contains(where: { $0.id == m.id }) { a.append(Self(family: "workout quantity", metric: HealthTypes.shortName(m.id), category: "core", enabled: false, status: "unavailable type/unit on this OS")) }
            for m in file.eventTypes ?? [] where !supported.events.contains(where: { $0.name == m.name }) { a.append(Self(family: "event", metric: m.name, category: m.category, enabled: false, status: "unavailable type/unit on this OS")) }
        }
        return a.map { var row = $0; if !row.enabled && row.status == "not tested" { row.status = "disabled" }; return row }
    }
}
struct DiagnosticRunReport: Codable, Sendable, Identifiable {
    var id = UUID().uuidString
    var date = Date(), schema = 1
    var build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var zone = TimeZone.current.identifier
    var preset = "", cutoff = Date(), configuration: [String: String] = [:]
    var text = "", status = "running", cases: [DiagnosticCaseReport] = [], coverage: [DiagnosticCoverage] = []
    var limitations = ["HealthKit cache cannot be reset; historical data can change.", "Replay timings exclude HealthKit/network latency.", "Reference agreement does not certify Apple's private aggregation.", "Empty reads do not distinguish absent data from denied read permission.", "Operation totals overlap; process CPU cannot be assigned to overlapping tasks.", "Network interface changes, battery drain and energy use are not measured; battery level, thermal state, low-power mode, CPU and memory are sampled every 2 seconds.", "Live cases include private capture and instrumentation overhead; compare the minimal-recorder and no-raw-capture cases to see its size."]
}
struct DiagnosticCaseReport: Codable, Sendable {
    var name: String, transfer: String, elapsed: Double, records: Int, complete: Bool, verdict: String
    var changed = 0, maximumDelta = 0.0, fields: [String: Int] = [:]
    var snapshot: SyncProbeRecorder.Snapshot
    /// Machine-readable verdict class, input fingerprints (live cases) for source-stability attribution.
    var kind: String? = nil, inputDigest: String? = nil, rawDigest: String? = nil
    /// True when every record is byte-identical to the reference; false with a tiny maximumDelta means floating-point noise inside the declared 1e-9 tolerance.
    var exact: Bool? = nil
    /// Records not byte-identical but inside the tolerance, records that differed on the still-changing cutoff day, and dated differences beyond tolerance.
    var noiseRecords: Int? = nil, currentDayChanged: Int? = nil, changedDays: [String: Int]? = nil
}
final class DiagnosticReportStore: @unchecked Sendable {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SyncDiagnostics")
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var url = self.root; var v = URLResourceValues(); v.isExcludedFromBackup = true; try? url.setResourceValues(v)
    }
    func save(_ report: DiagnosticRunReport) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601
        try e.encode(report).write(to: root.appendingPathComponent(report.id + ".json"), options: [.atomic, .completeFileProtection])
        try Data(report.text.utf8).write(to: root.appendingPathComponent(report.id + ".txt"), options: [.atomic, .completeFileProtection])
        var csv = "case,metric_window_operation,calls,total_overlapping_seconds,p50,p95_approx,max,items,errors\n"
        for c in report.cases { for (key, s) in c.snapshot.stats.sorted(by: { $0.key < $1.key }) { csv += "\"\(c.name)\",\"\(key.replacingOccurrences(of: "\"", with: "\"\""))\",\(s.count),\(s.total),\(s.p50),\(s.p95),\(s.maximum),\(s.items),\(s.errors)\n" } }
        try Data(csv.utf8).write(to: root.appendingPathComponent(report.id + ".csv"), options: [.atomic, .completeFileProtection])
    }
    func reports() -> [DiagnosticRunReport] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { try? d.decode(DiagnosticRunReport.self, from: Data(contentsOf: $0)) }.sorted { $0.date > $1.date }
    }
    /// A report still marked running while no suite is active means KROK stopped mid-run (crash, force-quit, restart).
    /// Mark it paused so it can be resumed from its saved cases and replay captures.
    func recoverInterrupted() {
        for var report in reports() where report.status == "running" {
            report.status = "paused"
            report.text += "\nInterrupted: KROK stopped before this run finished (crash, force-quit or restart). Completed cases and replay captures are saved; Resume continues from the next step.\n"
            try? save(report)
        }
    }
    /// Keeps the newest reports (and every paused one, which can still be resumed); older reports and their private captures go.
    func prune(keep: Int = 20) {
        let all = reports()
        for report in all.dropFirst(keep) where report.status != "paused" {
            for file in files(report.id) { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(report.id + "-private"))
        }
    }
    func files(_ id: String) -> [URL] { ["txt", "json", "csv"].map { root.appendingPathComponent(id + "." + $0) } }
}

#if DEBUG
extension DiagnosticReportStore {
    /// UI-test fixtures only: one finished and one paused report, so the saved, export and resume screens can be inspected.
    static func seedSamples() {
        let store = DiagnosticReportStore()
        var done = DiagnosticRunReport(); done.id = "ui-seed-complete"; done.preset = "Full initial-sync diagnosis"; done.status = "complete"
        done.configuration["accuracyGate"] = "NO REGRESSION DETECTED in the tested cases (agreement with this phone's own reference reader only)"
        done.text = "ACCURACY SUMMARY\nKnown-answer fixtures: all passed\nRepeat live baseline: stable\nOVERALL: NO REGRESSION DETECTED in the tested cases\nSuite finished. Finishing is not an accuracy pass."
        var paused = DiagnosticRunReport(); paused.id = "ui-seed-paused"; paused.preset = "Deep investigation"; paused.status = "paused"
        paused.text = "Paused: completed cases saved. Resume starts an interrupted case from the beginning; history may have changed."
        try? store.save(done); try? store.save(paused)
    }
}
#endif
