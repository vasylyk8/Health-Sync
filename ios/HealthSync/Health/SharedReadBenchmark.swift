#if DEBUG
import Foundation
import HealthKit
import CryptoKit

@MainActor
enum SharedReadBenchmark {
    static func run(_ scope: SyncScope, store: HKHealthStore, model m: BenchModel, expected: Int) async {
        await seedHistoryDetails(store, m, scope: scope)
        let at = Date()
        let count = (try? await HealthKitSource(scope: scope).workoutIndex().count) ?? 0
        var passed = count == expected && count > 0
        for forced in [true, false] {
            var reference: SharedCapture?
            for (run, legacy) in [true, true, false, false, true].enumerated() {
                let source = HealthKitSource(scope: scope)
                source.debugDisableSharedHistory = legacy
                source.debugFailingStatistics = forced
                let net = SharedCapture()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString)")
                let box = Outbox(root: root)
                let engine = SyncEngine(source: source, uploader: net, outbox: box, scope: scope, now: { at })
                let started = Date()
                do {
                    let outcome = try await engine.run()
                    let wall = Date().timeIntervalSince(started)
                    if reference == nil { reference = net }
                    let comparison = try net.comparison(to: reference!)
                    let complete = outcome == .finished && box.state.detailsDone.count == count && box.pending().isEmpty
                    passed = passed && comparison.equivalent && complete
                    m.log("SHARED result legacy=\(legacy) forced=\(forced) warmup=\(run == 0): wall=\(String(format: "%.2f", wall))s details=\(box.state.detailsDone.count)/\(count) equal=\(comparison.equivalent) exact=\(comparison.exact) maxDelta=\(comparison.maximumDelta) complete=\(complete)")
                } catch {
                    passed = false
                    m.log("SHARED failed: \(error)")
                }
                try? FileManager.default.removeItem(at: root)
            }
        }
        m.log(passed ? "SHARED CHECK OK" : "SHARED CHECK FAILED")
    }

    private static func seedHistoryDetails(_ store: HKHealthStore, _ m: BenchModel, scope: SyncScope) async {
        let workouts = (try? await HealthKitSource(scope: scope).workoutIndex()) ?? []
        guard let oldest = workouts.min(by: { $0.start < $1.start })?.start else { return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: oldest)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = []
        var day = start
        var index = 0
        while day < Date() {
            let t = day.addingTimeInterval(9 * 3600)
            samples.append(HKQuantitySample(type: HKQuantityType(.restingHeartRate), quantity: HKQuantity(unit: bpm, doubleValue: Double(45 + index % 20)), start: t, end: t.addingTimeInterval(1800)))
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN), quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: Double(30 + index % 60)), start: t, end: t))
            day = cal.date(byAdding: .day, value: 1, to: day)!
            index += 1
        }
        let boundary = cal.date(byAdding: .month, value: 3, to: start.addingTimeInterval(-300))!
        samples += [
            HKQuantitySample(type: HKQuantityType(.stepCount), quantity: HKQuantity(unit: .count(), doubleValue: 4321), start: boundary.addingTimeInterval(-2 * 86400), end: boundary.addingTimeInterval(86400)),
            HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: bpm, doubleValue: 72), start: boundary.addingTimeInterval(-2 * 86400), end: boundary.addingTimeInterval(3600)),
        ]
        do {
            var i = 0
            while i < samples.count {
                try await store.save(Array(samples[i..<min(i + 1000, samples.count)]))
                i += 1000
            }
            m.log("history recovery/boundaries: seeded \(samples.count) samples")
        } catch { m.log("SHARED seed failed: \(error)") }
    }

}

private final class SharedCapture: Uploader, @unchecked Sendable {
    private let net = SimNet(perUploadMBs: 0.6, capMBs: 0.6)
    private let lock = NSLock()
    private var records: [String] = []
    private var hourlyBytes = 0, hourlyUploads = 0
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        guard let raw = Gzip.decompress(gz), let text = String(data: raw, encoding: .utf8) else { throw NSError(domain: "SharedCapture", code: 1) }
        let lines = try text.split(separator: "\n").dropFirst().map { line -> String in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return typeId + ":" + String(decoding: data, as: UTF8.self)
        }
        try await net.upload(batchId: batchId, gz: gz, sha256: sha256, typeId: typeId)
        lock.withLock {
            records.append(contentsOf: lines)
            if typeId == HealthTypes.hourlyId { hourlyBytes += gz.count; hourlyUploads += 1 }
        }
    }
    var fingerprint: String {
        let data = lock.withLock { Data(records.sorted().joined(separator: "\n").utf8) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private var snapshot: [String] { lock.withLock { records } }
    func comparison(to reference: SharedCapture) throws -> HistoryRecordComparison {
        try HistoryRecordComparison.compare(reference.snapshot, snapshot)
    }
    func differences(to reference: SharedCapture) -> [String] {
        let a = Set(reference.snapshot), b = Set(snapshot)
        return a.subtracting(b).sorted().prefix(1).map { "reference " + $0 } + b.subtracting(a).sorted().prefix(1).map { "candidate " + $0 }
    }
    func summary(wall: Double) -> String { net.summary(wall: wall) }
}

#endif
