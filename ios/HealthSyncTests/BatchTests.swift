import XCTest
import HealthKit
@testable import HealthSync

final class BatchTests: XCTestCase {
    func testGzipRoundTripAndHeader() throws {
        let text = Data(String(repeating: "health sync ", count: 10_000).utf8)
        let gz = Gzip.compress(text)
        XCTAssertEqual(Array(gz.prefix(2)), [0x1f, 0x8b])
        XCTAssertLessThan(gz.count, text.count / 10)
        XCTAssertEqual(Gzip.decompress(gz), text)
        XCTAssertEqual(Gzip.decompress(Gzip.compress(Data())), Data())
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testBatchContainsHeaderThenRecords() throws {
        let header = BatchHeader(type: "HKQuantityTypeIdentifierHeartRate", mode: .anchored, seq: 7, caughtUp: true, checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let records: [Record] = [["k": "s", "id": "a", "s": 1, "e": 1, "v": 60.5, "u": "count/min"], ["k": "d", "id": "b"]]
        let batches = try BatchWriter.make(header: header, records: records, nextSeq: { 99 }, tz: "Europe/Kyiv", device: "iPhone", appVersion: "1.0")
        XCTAssertEqual(batches.count, 1)
        let lines = String(data: Gzip.decompress(batches[0].gz)!, encoding: .utf8)!.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let h = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(h["kind"] as? String, "header")
        XCTAssertEqual(h["schema"] as? Int, 1)
        XCTAssertEqual(h["batchId"] as? String, batches[0].id)
        XCTAssertEqual(h["seq"] as? Int, 7)
        XCTAssertEqual(h["caughtUp"] as? Bool, true)
        XCTAssertEqual(h["checkedAt"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(h["tz"] as? String, "Europe/Kyiv")
        XCTAssertNotNil(UUID(uuidString: batches[0].id))
        XCTAssertEqual(batches[0].id, batches[0].id.lowercased())
        XCTAssertEqual(batches[0].sha256.count, 64)
    }

    func testLargeResultsSplitAndOnlyLastPartClaimsCompletion() throws {
        var header = BatchHeader(type: "HKQuantityTypeIdentifierStepCount", mode: .recent, seq: 1, window: (Date(), Date()), caughtUp: true, checkedAt: Date())
        header.caughtUp = true
        let records: [Record] = (0..<(BatchWriter.maxRecords + 10)).map { ["k": "s", "id": .string("id\($0)"), "s": .int(Int64($0)), "e": .int(Int64($0)), "v": 1.0] }
        var seq: Int64 = 1
        let batches = try BatchWriter.make(header: header, records: records, nextSeq: { seq += 1; return seq }, tz: "UTC", device: "x", appVersion: "1")
        XCTAssertEqual(batches.count, 2)
        let headers = try batches.map { b -> [String: Any] in
            let first = String(data: Gzip.decompress(b.gz)!, encoding: .utf8)!.split(separator: "\n")[0]
            return try JSONSerialization.jsonObject(with: Data(first.utf8)) as! [String: Any]
        }
        XCTAssertEqual(headers[0]["caughtUp"] as? Bool, false)
        XCTAssertNil(headers[0]["window"])
        XCTAssertEqual(headers[1]["caughtUp"] as? Bool, true)
        XCTAssertNotNil(headers[1]["window"])
        XCTAssertNotEqual(headers[0]["seq"] as? Int, headers[1]["seq"] as? Int)
        XCTAssertTrue(batches.allSatisfy { $0.gz.count <= BatchWriter.maxCompressedBytes })
    }

    func testCoverageMatrixResolvesOnThisOS() {
        let entries = HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self))
        XCTAssertGreaterThan(entries.count, 150)
        let types = HealthTypes.resolve(entries)
        // Every quantity type's unit must be buildable and compatible, or it is dropped.
        let quantities = entries.filter { $0.kind == "quantity" }
        let resolvedQuantities = types.filter { if case .quantity = $0.kind { return true } else { return false } }
        XCTAssertGreaterThan(Double(resolvedQuantities.count), Double(quantities.count) * 0.9, "too many quantity types failed to resolve")
        for e in quantities where e.unit != "appleEffortScore" { XCTAssertNotNil(HealthTypes.unit(named: e.unit ?? ""), "no unit for \(e.id)") }
        XCTAssertTrue(types.contains { $0.id == "HKWorkoutTypeIdentifier" })
        XCTAssertFalse(HealthTypes.readPermissions(for: types).contains { $0 is HKCorrelationType })
    }

    /// HealthKit raises an exception (crash) for types that may not be requested. This catches
    /// any such type in the coverage matrix before it reaches a user.
    func testReadPermissionsAreAcceptedByHealthKit() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw XCTSkip("HealthKit unavailable") }
        let types = HealthTypes.resolve(HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self)))
        _ = try await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: HealthTypes.readPermissions(for: types))
    }
}
