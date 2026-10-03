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
        let header = BatchHeader(type: "HKWorkoutTypeIdentifier", mode: .anchored, seq: 7, caughtUp: true, checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let records: [Record] = [["k": "w", "id": "a", "s": 1, "e": 2, "act": 37, "dur": 60.5], ["k": "d", "id": "b"]]
        let batches = try BatchWriter.make(header: header, records: records, nextSeq: { 99 }, tz: "Europe/Kyiv", device: "iPhone", appVersion: "1.0")
        XCTAssertEqual(batches.count, 1)
        let lines = String(data: Gzip.decompress(batches[0].gz)!, encoding: .utf8)!.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let h = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(h["kind"] as? String, "header")
        XCTAssertEqual(h["schema"] as? Int, 2)
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
        var header = BatchHeader(type: "HKWorkoutTypeIdentifier", mode: .recent, seq: 1, window: (Date(), Date()), caughtUp: true, checkedAt: Date())
        header.caughtUp = true
        let records: [Record] = (0..<(BatchWriter.maxRecords + 10)).map { ["k": "w", "id": .string("id\($0)"), "s": .int(Int64($0)), "e": .int(Int64($0)), "act": 37] }
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

    func testCoverageResolvesOnThisOS() throws {
        let file = try XCTUnwrap(HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self)))
        XCTAssertTrue(Set(file.types.map(\.id)).isSuperset(of: ["HKWorkoutTypeIdentifier", "_daily", "_wstream", "_hourly"]))
        XCTAssertTrue(file.types.allSatisfy { t in (file.categories ?? []).contains { $0.id == (t.category ?? "core") } }, "every batch type belongs to a known category")
        let scope = HealthTypes.scope(file)
        // Every unit must be buildable and compatible, or the type is dropped.
        XCTAssertGreaterThan(Double(scope.workoutQuantities.count), Double(file.workoutQuantityTypes.count) * 0.9, "too many workout types failed to resolve")
        XCTAssertGreaterThan(Double(scope.dailyMetrics.count), Double(file.dailyMetrics.count) * 0.9, "too many daily metrics failed to resolve")
        for q in file.workoutQuantityTypes where q.unit != "appleEffortScore" { XCTAssertNotNil(HealthTypes.unit(named: q.unit), "no unit for \(q.id)") }
        for m in file.dailyMetrics { if let u = m.unit, u != "appleEffortScore" { XCTAssertNotNil(HealthTypes.unit(named: u), "no unit for \(m.key)") } }
        XCTAssertNotNil(scope.workout)
        let perms = HealthTypes.readPermissions(for: scope)
        XCTAssertTrue(perms.contains(HKObjectType.workoutType()))
        XCTAssertTrue(perms.contains(HKSeriesType.workoutRoute()), "the GPS route type must be requested")
        XCTAssertTrue(perms.contains(HKObjectType.quantityType(forIdentifier: .heartRate)!))
        XCTAssertFalse(perms.contains { $0 is HKCorrelationType })
        // Metric keys are unique: two metrics writing the same key would overwrite each other.
        XCTAssertEqual(Set(file.dailyMetrics.map(\.key)).count, file.dailyMetrics.count)
        let rawRecovery = Set(file.dailyMetrics.filter { $0.recoverMissingFromRaw == true }.map(\.key))
        XCTAssertTrue(rawRecovery.isSuperset(of: ["restingHr", "hrv", "respiratoryRate", "spo2Avg", "vo2max"]))
    }

    func testCoverageDoesNotAskForUnrelatedHealthData() throws {
        let file = try XCTUnwrap(HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self)))
        let ids = Set(file.workoutQuantityTypes.map(\.id) + file.dailyMetrics.map(\.id) + (file.eventTypes ?? []).map(\.id) + (file.hourlyMetrics ?? []).map(\.id))
        // Left out on purpose (see docs/COVERAGE_MATRIX.md): reproductive and sexual health, ECG, clinical records, questionnaires.
        let forbidden = ["SexualActivity", "Contraceptive", "Pregnancy", "Lactation", "ProgesteroneTest", "Menopause", "Electrocardiogram", "HKClinical", "GAD7", "PHQ9",
                         "PelvicPain", "BreastPain", "VaginalDryness", "HotFlashes", "BladderIncontinence", "Audiogram", "Handwashing", "Toothbrushing", "BloodType", "FitzpatrickSkinType"]
        for item in forbidden {
            XCTAssertFalse(ids.contains { $0.contains(item) }, "\(item) must not be read")
        }
    }

    func testEveryCategoryHasItsOwnTypesAndCoreIsAlwaysRequested() throws {
        let file = try XCTUnwrap(HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self)))
        let scope = HealthTypes.scope(file)
        let coreOnly = HealthTypes.readPermissions(for: scope, categories: ["core"])
        let all = HealthTypes.readPermissions(for: scope, categories: Set((file.categories ?? []).map(\.id)))
        XCTAssertTrue(coreOnly.contains(HKObjectType.workoutType()))
        XCTAssertFalse(coreOnly.contains(HKObjectType.quantityType(forIdentifier: .bloodGlucose)!), "glucose is only requested once its category is on")
        XCTAssertFalse(coreOnly.contains { $0 is HKCharacteristicType })
        XCTAssertTrue(all.contains(HKObjectType.quantityType(forIdentifier: .bloodGlucose)!))
        XCTAssertGreaterThan(all.count, coreOnly.count)
        for event in scope.events { XCTAssertTrue((file.categories ?? []).contains { $0.id == event.category }, "unknown category \(event.category)") }
    }

    /// HealthKit raises an exception (crash) for types that may not be requested. This catches
    /// any such type in the coverage file before it reaches a user.
    func testReadPermissionsAreAcceptedByHealthKit() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw XCTSkip("HealthKit unavailable") }
        let scope = HealthTypes.scope(HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self)))
        _ = try await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: HealthTypes.readPermissions(for: scope, categories: Set((HealthTypes.loadCoverage(bundle: Bundle(for: AppModel.self))?.categories ?? []).map(\.id))))
    }

    func testOnlyPassingHealthKitErrorsAreRetried() {
        func err(_ code: HKError.Code) -> NSError { NSError(domain: HKErrorDomain, code: code.rawValue) }
        XCTAssertTrue(HealthKitSource.isPermanentFailure(err(.errorAuthorizationDenied)))
        XCTAssertTrue(HealthKitSource.isPermanentFailure(err(.errorNoData)))
        XCTAssertFalse(HealthKitSource.isPermanentFailure(err(.errorDatabaseInaccessible)), "a locked phone is retried later")
        XCTAssertFalse(HealthKitSource.isPermanentFailure(NSError(domain: NSURLErrorDomain, code: -1009)))
    }

    func testRawDailyFallbackOnlyFillsMissingDays() {
        let primary = [("2024-03-01", 50.0), ("2024-03-03", 52.0)]
        let authorizedRaw = [("2024-03-01", 99.0), ("2024-03-02", 51.0), ("2024-03-03", 98.0)]
        XCTAssertEqual(HealthKitSource.missingDaily(primary: primary, fallback: authorizedRaw).map(\.0), ["2024-03-02"])
        XCTAssertEqual(HealthKitSource.missingDaily(primary: primary, fallback: authorizedRaw).map(\.1), [51.0])
    }

    func testOutboxFromAnOlderAppAsksForTheDailyHistoryAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let box = Outbox(root: root)
        try box.update { $0.dailyFullAt = Date(); $0.dailyVersion = 0 }
        XCTAssertEqual(Outbox(root: root).state.dailyVersion, 0)
        XCTAssertEqual(SyncEngine.dailyVersion, 12)
        XCTAssertEqual(SyncEngine.hourlyVersion, 8)
        XCTAssertEqual(SyncEngine.detailVersion, 1)
    }
}
