import Foundation
import CoreFoundation

struct HistoryRecordComparison: Sendable {
    var exact: Bool
    var equivalent: Bool
    var maximumDelta: Double
    var changedRecords: Int
    var changedFields: [String: Int] = [:]
    var examples: [String] = []
    var detailSummary: String {
        let fields = changedFields.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "Changed fields: \(fields.isEmpty ? "none" : fields)" + (examples.isEmpty ? "" : "\n" + examples.joined(separator: "\n"))
    }
    /// Field paths/counts and a bounded set of values. No account/workout/source identifiers.
    static func differingFields(_ a: Any, _ b: Any, path: String = "", tolerance: Double = 1e-9) -> [(String, Double?, Double?)] {
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            return Set(a.keys).union(b.keys).sorted().flatMap { key in
                let next = path.isEmpty ? key : path + "." + key
                guard let av = a[key], let bv = b[key] else { return [(next, nil, nil)] }
                return differingFields(av, bv, path: next, tolerance: tolerance)
            }
        }
        if let a = a as? [Any], let b = b as? [Any] {
            guard a.count == b.count else { return [(path + ".count", Double(a.count), Double(b.count))] }
            return zip(a, b).flatMap { differingFields($0, $1, path: path + "[]", tolerance: tolerance) }
        }
        if let delta = distance(a, b), delta <= tolerance { return [] }
        return [(path, (a as? NSNumber)?.doubleValue, (b as? NSNumber)?.doubleValue)]
    }

    static func compare(_ reference: [String], _ candidate: [String], tolerance: Double = 1e-9) throws -> Self {
        func groups(_ records: [String]) throws -> [String: [(String, Any)]] {
            var result: [String: [(String, Any)]] = [:]
            for record in records {
                guard let colon = record.firstIndex(of: ":") else { throw BadRecord() }
                let type = String(record[..<colon])
                let body = try JSONSerialization.jsonObject(with: Data(record[record.index(after: colon)...].utf8))
                let shape = try JSONSerialization.data(withJSONObject: signature(body), options: [.sortedKeys])
                result[type + ":" + String(decoding: shape, as: UTF8.self), default: []].append((record, body))
            }
            return result
        }
        let a = try groups(reference), b = try groups(candidate)
        var result = Self(exact: reference.sorted() == candidate.sorted(), equivalent: reference.count == candidate.count && Set(a.keys) == Set(b.keys), maximumDelta: 0, changedRecords: 0)
        for key in a.keys {
            let originals = a[key] ?? []
            var remaining = b[key] ?? []
            guard originals.count == remaining.count else { result.equivalent = false; continue }
            for (line, original) in originals {
                let matches = remaining.enumerated().compactMap { index, value -> (Int, Double)? in
                    guard let delta = distance(original, value.1) else { return nil }
                    return (index, delta)
                }
                guard let best = matches.min(by: { $0.1 < $1.1 }) else { result.equivalent = false; continue }
                result.maximumDelta = max(result.maximumDelta, best.1)
                if best.1 > tolerance { result.equivalent = false }
                if line != remaining[best.0].0 { result.changedRecords += 1 }
                remaining.remove(at: best.0)
            }
        }
        return result
    }

    static func signature(_ value: Any) -> Any {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? value : 0
        }
        if let array = value as? [Any] { return array.map(signature) }
        if let object = value as? [String: Any] { return object.mapValues(signature) }
        return value
    }

    static func distance(_ a: Any, _ b: Any) -> Double? {
        if let a = a as? NSNumber, let b = b as? NSNumber {
            let ab = CFGetTypeID(a) == CFBooleanGetTypeID(), bb = CFGetTypeID(b) == CFBooleanGetTypeID()
            if ab || bb { return ab == bb && a == b ? 0 : nil }
            return abs(a.doubleValue - b.doubleValue)
        }
        if let a = a as? String, let b = b as? String { return a == b ? 0 : nil }
        if a is NSNull, b is NSNull { return 0 }
        if let a = a as? [Any], let b = b as? [Any], a.count == b.count {
            var maximum = 0.0
            for (a, b) in zip(a, b) { guard let d = distance(a, b) else { return nil }; maximum = max(maximum, d) }
            return maximum
        }
        if let a = a as? [String: Any], let b = b as? [String: Any], Set(a.keys) == Set(b.keys) {
            var maximum = 0.0
            for key in a.keys { guard let d = distance(a[key]!, b[key]!) else { return nil }; maximum = max(maximum, d) }
            return maximum
        }
        return nil
    }
    private struct BadRecord: Error {}
}
