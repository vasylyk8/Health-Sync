import XCTest
@testable import HealthSync

/// The same test vectors as the server tests (shared/compact-fixtures.json): input -> compact -> decoded.
final class CompactColumnsTests: XCTestCase {
    private struct Fixture {
        let name: String
        let t: [Int64]
        let cols: [String: [Double?]]
        let plans: [String: CompactColumns.Plan]
        let compact: [String: Any]
        let decoded: [String: [Double?]]
    }

    private func numbers(_ any: Any?) -> [Double?] {
        (any as? [Any] ?? []).map { ($0 is NSNull) ? nil : ($0 as? NSNumber)?.doubleValue }
    }

    private func load() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "compact-fixtures", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]]).map { c in
            let input = c["input"] as! [String: Any]
            let plans = (c["plans"] as! [String: Any]).mapValues { plan -> CompactColumns.Plan in
                if let o = plan as? [String: Any], let m = o["m"] as? NSNumber { return .step(m.int64Value) }
                if let o = plan as? [String: Any], let r = o["rounded"] as? NSNumber { return .rounded(r.intValue) }
                return .exact
            }
            return Fixture(
                name: c["name"] as! String,
                t: (input["t"] as! [NSNumber]).map(\.int64Value),
                cols: (input["cols"] as! [String: Any]).mapValues { numbers($0) },
                plans: plans,
                compact: c["compact"] as! [String: Any],
                decoded: (c["decoded"] as! [String: Any]).mapValues { numbers($0) })
        }
    }

    /// RecordValue -> the JSON the server sees -> Foundation objects, to compare with the fixture's.
    private func json(_ v: RecordValue) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(v), options: [.fragmentsAllowed])
    }

    func testEncodingMatchesTheSharedVectors() throws {
        let fixtures = try load()
        XCTAssertGreaterThanOrEqual(fixtures.count, 7)
        for f in fixtures {
            XCTAssertEqual(try json(CompactColumns.encodeTimes(f.t)) as? NSDictionary, f.compact["t"] as? NSDictionary, "\(f.name): t")
            for (name, values) in f.cols {
                let encoded = CompactColumns.encode(values, plan: f.plans[name] ?? .exact)
                XCTAssertEqual(try json(encoded) as? NSDictionary, f.compact[name] as? NSDictionary, "\(f.name): \(name)")
            }
        }
    }

    func testDecodingMatchesTheSharedVectors() throws {
        for f in try load() {
            let n = f.t.count
            for (name, expected) in f.decoded {
                let column: RecordValue = name == "t" ? CompactColumns.encodeTimes(f.t) : CompactColumns.encode(f.cols[name]!, plan: f.plans[name] ?? .exact)
                XCTAssertEqual(CompactColumns.decode(column, count: n), expected, "\(f.name): \(name)")
            }
        }
    }

    func testRandomWalkRoundTripsWithinHalfAStep() {
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for plan in [CompactColumns.Plan.step(100_000), .step(10), .step(1), .exact] {
            var x = 50.0
            var values: [Double?] = []
            for i in 0..<5000 {
                x += (rnd() - 0.4) * 0.0004
                values.append(i % 97 == 5 ? nil : x)
            }
            guard let back = CompactColumns.decode(CompactColumns.encode(values, plan: plan), count: values.count) else { return XCTFail("could not decode") }
            for (a, b) in zip(values, back) {
                if a == nil { XCTAssertNil(b) } else if case .step(let m) = plan { XCTAssertEqual(b!, a!, accuracy: 0.5 / Double(m) + 1e-12) } else { XCTAssertEqual(b, a) }
            }
        }
    }

    func testRoundedPlanRemovesFloatNoiseAndKeepsShortDecimals() {
        let noisy: [Double?] = [61.99999999999999, 62, 64.00000000000001, 63, 65.4999999, nil, 0.30000000000000004]
        let column = CompactColumns.encode(noisy, plan: .rounded(3))
        guard case .object(let o) = column, case .int(let m)? = o["m"] else { return XCTFail("rounded values must use integer columns, not plain numbers") }
        XCTAssertEqual(m, 10, "the smallest divisor that keeps every rounded value exactly")
        XCTAssertEqual(CompactColumns.decode(column, count: noisy.count)!, [62, 62, 64, 63, 65.5, nil, 0.3])
    }

    func testRoundedPlanStaysWithinHalfAThousandthOfTheInput() {
        var seed: UInt64 = 3
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let values: [Double?] = (0..<2000).map { _ in Optional(rnd() * 300) }
        guard let back = CompactColumns.decode(CompactColumns.encode(values, plan: .rounded(3)), count: values.count) else { return XCTFail("could not decode") }
        for (a, b) in zip(values, back) { XCTAssertEqual(b!, a!, accuracy: 0.0005 + 1e-9) }
    }

    func testAllNullAndSinglePointColumns() {
        XCTAssertEqual(CompactColumns.decode(CompactColumns.encode([nil, nil], plan: .step(10)), count: 2)!, [nil, nil])
        XCTAssertEqual(CompactColumns.decode(CompactColumns.encode([4.5], plan: .exact), count: 1)!, [4.5])
        XCTAssertEqual(CompactColumns.decode(CompactColumns.encodeTimes([1_790_000_000_000]), count: 1)!, [1_790_000_000_000])
    }

    func testNonFiniteValuesBecomeNull() {
        let back = CompactColumns.decode(CompactColumns.encode([1, .nan, .infinity, 4], plan: .exact), count: 4)!
        XCTAssertEqual(back, [1, nil, nil, 4])
    }

    func testAbsurdlyLargeValuesFallBackToPlainNumbers() {
        let values: [Double?] = [1e300, -1e300, 5]
        XCTAssertEqual(CompactColumns.decode(CompactColumns.encode(values, plan: .step(100_000)), count: 3)!, values)
    }
}
