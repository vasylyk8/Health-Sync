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
    var limitations = ["HealthKit cache cannot be reset; historical data can change.", "Replay timings exclude HealthKit/network latency.", "Reference agreement does not certify Apple's private aggregation.", "Empty reads do not distinguish absent data from denied read permission.", "Operation totals overlap; process CPU cannot be assigned to overlapping tasks."]
}
struct DiagnosticCaseReport: Codable, Sendable {
    var name: String, transfer: String, elapsed: Double, records: Int, complete: Bool, verdict: String
    var changed = 0, maximumDelta = 0.0, fields: [String: Int] = [:]
    var snapshot: SyncProbeRecorder.Snapshot
    /// Machine-readable verdict class, input fingerprints (live cases) for source-stability attribution.
    var kind: String? = nil, inputDigest: String? = nil, rawDigest: String? = nil
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
    func files(_ id: String) -> [URL] { ["txt", "json", "csv"].map { root.appendingPathComponent(id + "." + $0) } }
}
