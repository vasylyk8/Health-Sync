import Foundation

/// Compact encoding of the columns of a raw stream chunk (docs/DATA_CONTRACT.md, "Compact `ws` chunk").
///
/// A column is a list of integers `X[i]` with a divisor `m`: the value is `X[i] / m`. The integers are sent
/// as differences, so they are small and compress well. `o: 2` sends differences of differences, which is
/// near zero for steady motion and regular timestamps. Values that are not an exact short decimal are sent
/// as plain numbers (`r`), so nothing is lost there.
enum CompactColumns {
    enum Plan: Equatable, Sendable {
        /// Keep every value exactly: the smallest divisor in 1, 10, ... 10^6 that reproduces all values, else plain numbers.
        case exact
        /// Round to a multiple of 1/m (e.g. `.step(100_000)` is 0.00001, about 1.1 m of latitude).
        case step(Int64)
    }

    private static let exactDivisors: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]
    /// Integers above 2^53 do not survive the server's JSON parser.
    private static let limit = 9e15

    /// Whole milliseconds: always exact, never null.
    static func encodeTimes(_ t: [Int64]) -> RecordValue {
        delta(t, divisor: 1, nulls: [])
    }

    static func encode(_ values: [Double?], plan: Plan) -> RecordValue {
        let m: Int64
        switch plan {
        case .step(let s): m = max(1, s)
        case .exact:
            guard let found = exactDivisor(values) else { return plain(values) }
            m = found
        }
        let scale = Double(m)
        var x: [Int64] = []
        x.reserveCapacity(values.count)
        var nulls: [Int64] = []
        var previous: Int64 = 0
        for (i, value) in values.enumerated() {
            if let value, value.isFinite {
                let q = (value * scale).rounded()
                guard abs(q) < limit else { return plain(values) }
                previous = Int64(q)
                x.append(previous)
            } else {
                nulls.append(Int64(i))
                x.append(previous)
            }
        }
        return delta(x, divisor: m, nulls: nulls)
    }

    /// Reads a column back (the same rules as the server). Used by the speed test to check the encoding on real data.
    static func decode(_ column: RecordValue, count n: Int) -> [Double?]? {
        guard case .object(let o) = column else { return nil }
        if case .array(let r)? = o["r"] {
            guard r.count == n else { return nil }
            return r.map { v -> Double? in
                switch v {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return nil
                }
            }
        }
        guard case .int(let m)? = o["m"], case .int(let order)? = o["o"], case .array(let d)? = o["d"], d.count == n, m >= 1 else { return nil }
        var nulls = Set<Int>()
        if case .array(let xs)? = o["x"] { for case .int(let i) in xs { nulls.insert(Int(i)) } }
        var out: [Double?] = []
        out.reserveCapacity(n)
        var x: Int64 = 0
        var step: Int64 = 0
        for i in 0 ..< n {
            guard case .int(let di) = d[i] else { return nil }
            if i == 0 {
                x = di
            } else if order == 1 || i == 1 {
                step = di
                x += step
            } else {
                step += di
                x += step
            }
            out.append(nulls.contains(i) ? nil : Double(x) / Double(m))
        }
        return out
    }

    /// Plain numbers (null for no value).
    private static func plain(_ values: [Double?]) -> RecordValue {
        .object(["r": .array(values.map { value -> RecordValue in
            if let value, value.isFinite { return .double(value) }
            return .null
        })])
    }

    private static func exactDivisor(_ values: [Double?]) -> Int64? {
        for m in exactDivisors {
            let scale = Double(m)
            let ok = values.allSatisfy { value in
                guard let value else { return true }
                guard value.isFinite else { return true }
                let scaled = value * scale
                return abs(scaled) < limit && scaled.rounded() / scale == value
            }
            if ok { return m }
        }
        return nil
    }

    private static func delta(_ x: [Int64], divisor: Int64, nulls: [Int64]) -> RecordValue {
        var d1 = x
        if x.count > 1 { for i in 1 ..< x.count { d1[i] = x[i] - x[i - 1] } }
        var d2 = d1
        if d1.count > 2 { for i in 2 ..< d1.count { d2[i] = d1[i] - d1[i - 1] } }
        func cost(_ d: [Int64]) -> Double { d.dropFirst(2).reduce(0) { $0 + Double(abs($1)) } }
        // Second differences only when strictly cheaper.
        let useSecond = cost(d2) < cost(d1)
        let d = useSecond ? d2 : d1
        if d.contains(where: { Double(abs($0)) >= limit }) { return plain(x.enumerated().map { nulls.contains(Int64($0.offset)) ? nil : Double($0.element) / Double(divisor) }) }
        var object: [String: RecordValue] = ["m": .int(divisor), "o": .int(useSecond ? 2 : 1), "d": .array(d.map { .int($0) })]
        if !nulls.isEmpty { object["x"] = .array(nulls.map { .int($0) }) }
        return .object(object)
    }
}
