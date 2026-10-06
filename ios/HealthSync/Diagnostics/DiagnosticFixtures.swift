import Foundation

/// Read-only known-answer checks; no synthetic readings are written to the phone's HealthKit.
enum DiagnosticFixtures {
    static func run() throws -> [String] {
        var results: [String] = []
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let start = calendar.date(from: DateComponents(year: 2024, month: 3, day: 9))!, end = calendar.date(byAdding: .day, value: 3, to: start)!
        for style in [SampleAggregator.Style.cumulative, .arithmetic, .timeWeighted, .equivalentLevel] {
            var day = SampleAggregator(calendar: calendar, from: start, to: end, style: style, granularity: .day)
            var hour = SampleAggregator(calendar: calendar, from: start, to: end, style: style, granularity: .hour)
            let value = style == .equivalentLevel ? 60.0 : 100.0
            let r = RawReading(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(3660), value: value, source: "com.apple.health.watch", watch: true)
            day.add(r); hour.add(r)
            guard let first = day.daily(style == .cumulative ? .sum : .avg).first, abs(first.1 - value) <= 1e-9 else { throw Failure.knownAnswer(style.rawValue) }
            guard !hour.hourly(avg: true, min: true, max: true).isEmpty else { throw Failure.knownAnswer("hour buckets") }
            results.append("Known-answer \(style.rawValue) daily/hourly: PASS")
        }
        let days = SampleAggregator.localDays(from: start, to: end, calendar: calendar)
        guard days == 3, end.timeIntervalSince(start) == 71 * 3600 else { throw Failure.knownAnswer("DST") }
        results.append("DST: three local days / 71 elapsed hours: PASS")
        var cumulative = SampleAggregator(calendar: calendar, from: start, to: end, style: .cumulative, granularity: .day)
        cumulative.add(RawReading(start: start, end: start.addingTimeInterval(600), value: 100, source: "com.apple.health.watch", watch: true))
        cumulative.add(RawReading(start: start, end: start.addingTimeInterval(600), value: 200, source: "com.apple.health.phone"))
        guard abs(cumulative.daily(.sum).map(\.1).reduce(0, +) - 100) <= 1e-9 else { throw Failure.knownAnswer("Watch selection") }
        results.append("Watch/phone overlap suppression: PASS")
        let p: [String: Any] = ["k": "day", "day": "2024-03-09", "m": ["steps": 100]]
        let q: [String: Any] = ["k": "day", "day": "2024-03-09", "m": ["steps": 101]]
        guard !HistoryRecordComparison.differingFields(p, q).isEmpty else { throw Failure.knownAnswer("numeric diff") }
        results.append("Numeric field differences detected: PASS")
        let data = Data("timestamp,unit,duplicate,route".utf8)
        guard Gzip.decompress(Gzip.compress(data)) == data else { throw Failure.knownAnswer("gzip") }
        results.append("Encoding/compression round-trip: PASS")
        return results
    }
    enum Failure: Error { case knownAnswer(String) }
}
