import Foundation

/// Read-only known-answer checks of the production aggregation rules; no synthetic readings are written to the phone's HealthKit.
/// A failed check is reported (and fails the accuracy summary) rather than aborting an hour-long run.
enum DiagnosticFixtures {
    /// Scenarios the phone suite does not exercise itself, so the report never implies they were.
    static let notExercised = [
        "Outbox disk-write failure and corruption (unit tests only)",
        "Auth-token expiry, HTTP throttling and mid-transfer disconnect against the real server (unit tests and one simulated network failure only)",
        "Crash or process-kill checkpoint resume (unit tests; the suite cannot relaunch itself)",
        "Unit and scale conversion of real HealthKit samples (simulator HealthKit CI only)",
        "Malformed or multiple GPS route series and series length limits (workout record unit tests)",
        "Time-zone change while running (the suite refuses to resume, it is not simulated)",
        "Deletion and reconciliation paths (engine and server unit tests; never run against your data)",
        "App switching, lock and background expiration (the suite pauses when KROK leaves the foreground)",
    ]

    static func run() -> [String] {
        var results: [String] = []
        func check(_ name: String, _ body: () throws -> Bool) {
            do { results.append(try body() ? "Known-answer \(name): PASS" : "FAIL Known-answer \(name): result differed from the documented answer") }
            catch { results.append("FAIL Known-answer \(name): \(error)") }
        }
        var toronto = Calendar(identifier: .gregorian); toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date { toronto.date(from: DateComponents(year: y, month: m, day: d))! }
        func aggregator(_ style: SampleAggregator.Style, _ granularity: SampleAggregator.Granularity, from: Date, to: Date) -> SampleAggregator {
            SampleAggregator(calendar: toronto, from: from, to: to, style: style, granularity: granularity)
        }
        func same(_ a: [(String, Double)], _ b: [(String, Double)]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && abs($0.1 - $1.1) <= 1e-9 }
        }

        let spring = date(2024, 3, 9), springEnd = toronto.date(byAdding: .day, value: 3, to: spring)!
        for style in [SampleAggregator.Style.cumulative, .arithmetic, .timeWeighted, .equivalentLevel] {
            check("\(style.rawValue) daily and hourly") {
                var day = aggregator(style, .day, from: spring, to: springEnd), hour = aggregator(style, .hour, from: spring, to: springEnd)
                let value = style == .equivalentLevel ? 60.0 : 100.0
                let r = RawReading(start: spring.addingTimeInterval(3600), end: spring.addingTimeInterval(3660), value: value, source: "com.apple.health.watch", watch: true)
                day.add(r); hour.add(r)
                guard let first = day.daily(style == .cumulative ? .sum : .avg).first, abs(first.1 - value) <= 1e-9 else { return false }
                return !hour.hourly(avg: true, min: true, max: true).isEmpty
            }
        }
        check("spring DST: three local days and 71 elapsed hours") {
            SampleAggregator.localDays(from: spring, to: springEnd, calendar: toronto) == 3 && springEnd.timeIntervalSince(spring) == 71 * 3600
        }
        check("fall DST: one 25-hour day with two separate 1:30 hours") {
            let start = date(2024, 11, 3), end = toronto.date(byAdding: .day, value: 1, to: start)!
            guard end.timeIntervalSince(start) == 25 * 3600, SampleAggregator.localDays(from: start, to: end, calendar: toronto) == 1 else { return false }
            var day = aggregator(.cumulative, .day, from: start, to: end), hour = aggregator(.cumulative, .hour, from: start, to: end)
            for (offset, value) in [(5400.0, 100.0), (9000.0, 200.0)] {
                let r = RawReading(start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 60), value: value, source: "com.apple.health.watch", watch: true)
                day.add(r); hour.add(r)
            }
            return day.daily(.sum).count == 1 && abs(day.daily(.sum)[0].1 - 300) <= 1e-9 && hour.hourly(avg: true, min: true, max: true).count == 2
        }
        check("Watch beats overlapping phone reading") {
            var cumulative = aggregator(.cumulative, .day, from: spring, to: springEnd)
            cumulative.add(RawReading(start: spring, end: spring.addingTimeInterval(600), value: 100, source: "com.apple.health.watch", watch: true))
            cumulative.add(RawReading(start: spring, end: spring.addingTimeInterval(600), value: 200, source: "com.apple.health.phone"))
            return abs(cumulative.daily(.sum).map(\.1).reduce(0, +) - 100) <= 1e-9
        }
        check("known Watch source with missing device metadata is kept") {
            let t = date(2024, 1, 10).addingTimeInterval(3600)
            var cumulative = aggregator(.cumulative, .day, from: date(2024, 1, 10), to: date(2024, 1, 11))
            cumulative.add(RawReading(start: t, end: t.addingTimeInterval(600), value: 100, source: "com.apple.health.W", watch: true))
            cumulative.add(RawReading(start: t.addingTimeInterval(600), end: t.addingTimeInterval(1200), value: 50, source: "com.apple.health.W"))
            return abs(cumulative.daily(.sum).map(\.1).reduce(0, +) - 150) <= 1e-9
        }
        check("48-hour reading splits by time across two days") {
            let from = date(2024, 1, 10), to = date(2024, 1, 12)
            var cumulative = aggregator(.cumulative, .day, from: from, to: to)
            cumulative.add(RawReading(start: from, end: to, value: 480, source: "com.apple.health.watch", watch: true))
            let days = cumulative.daily(.sum)
            return days.count == 2 && days.allSatisfy { abs($0.1 - 240) <= 1e-6 }
        }
        check("timestamp ties average both values") {
            let t = date(2024, 1, 10).addingTimeInterval(7200)
            var day = aggregator(.arithmetic, .day, from: date(2024, 1, 10), to: date(2024, 1, 11))
            day.add(RawReading(start: t, end: t, value: 10, source: "x")); day.add(RawReading(start: t, end: t, value: 20, source: "x"))
            return day.daily(.avg).count == 1 && abs(day.daily(.avg)[0].1 - 15) <= 1e-9
        }
        do {
            let t = date(2024, 1, 10).addingTimeInterval(7200)
            func last(_ values: [Double]) -> Double? {
                var day = aggregator(.arithmetic, .day, from: date(2024, 1, 10), to: date(2024, 1, 11))
                for v in values { day.add(RawReading(start: t, end: t, value: v, source: "x")) }
                return day.daily(.last).first?.1
            }
            results.append("INFO exact-timestamp ties: the day's last value follows delivery order (forward \(last([10, 20]).map { String($0) } ?? "none"), reverse \(last([20, 10]).map { String($0) } ?? "none")). Informational, not a pass/fail.")
        }
        check("non-finite and reversed readings are ignored") {
            let t = date(2024, 1, 10).addingTimeInterval(7200)
            var day = aggregator(.arithmetic, .day, from: date(2024, 1, 10), to: date(2024, 1, 11))
            day.add(RawReading(start: t, end: t, value: .nan, source: "x"))
            day.add(RawReading(start: t.addingTimeInterval(60), end: t, value: 99, source: "x"))
            day.add(RawReading(start: t, end: t, value: 10, source: "x"))
            return day.daily(.avg).count == 1 && abs(day.daily(.avg)[0].1 - 10) <= 1e-9
        }
        check("delivery order does not change daily or hourly results") {
            let from = date(2024, 1, 10), to = date(2024, 1, 11)
            func readings(_ style: SampleAggregator.Style) -> [RawReading] {
                (0..<6).map { i in
                    let s = from.addingTimeInterval(Double(i) * 5000 + 300)
                    return RawReading(start: s, end: s.addingTimeInterval(i % 2 == 0 ? 600 : 60), value: Double(i + 1) * 7, source: i % 3 == 0 ? "com.apple.health.watch" : "com.apple.health.phone", watch: i % 3 == 0)
                }
            }
            for style in [SampleAggregator.Style.cumulative, .arithmetic, .timeWeighted, .equivalentLevel] {
                for granularity in [SampleAggregator.Granularity.day, .hour] {
                    var forward = aggregator(style, granularity, from: from, to: to), backward = aggregator(style, granularity, from: from, to: to)
                    for r in readings(style) { forward.add(r) }
                    for r in readings(style).reversed() { backward.add(r) }
                    if granularity == .day {
                        let agg: DailyAgg = style == .cumulative ? .sum : .avg
                        guard same(forward.daily(agg), backward.daily(agg)) else { return false }
                    } else {
                        let a = forward.hourly(avg: true, min: true, max: true), b = backward.hourly(avg: true, min: true, max: true)
                        guard a.count == b.count, zip(a, b).allSatisfy({ $0.t == $1.t && abs(($0.v ?? 0) - ($1.v ?? 0)) <= 1e-9 && $0.lo == $1.lo && $0.hi == $1.hi }) else { return false }
                    }
                }
            }
            return true
        }
        check("numeric field difference detection and 1e-9 tolerance") {
            let p: [String: Any] = ["k": "day", "day": "2024-03-09", "m": ["steps": 100.0]]
            let tiny: [String: Any] = ["k": "day", "day": "2024-03-09", "m": ["steps": 100.0000000001]]
            let real: [String: Any] = ["k": "day", "day": "2024-03-09", "m": ["steps": 101.0]]
            return HistoryRecordComparison.differingFields(p, tiny, tolerance: 1e-9).isEmpty && !HistoryRecordComparison.differingFields(p, real, tolerance: 1e-9).isEmpty
        }
        check("encoding and compression round trip, small and 3 MB payloads") {
            let small = Data("timestamp,unit,duplicate,route".utf8)
            let large = Data((0..<3_000_000).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: (i % 251) ^ (i / 4096)) })
            return Gzip.decompress(Gzip.compress(small)) == small && Gzip.decompress(Gzip.compress(large)) == large
        }
        return results
    }
}
