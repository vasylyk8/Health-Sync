#if DEBUG
import Foundation
import HealthKit

@MainActor
enum HistorySchedulingBenchmark {
    static func run(_ scope: SyncScope, store: HKHealthStore, model m: BenchModel, expected: Int) async {
        await SharedReadBenchmark.seedHistoryDetails(store, m, scope: scope)
        let at = Date()
        let count = (try? await HealthKitSource(scope: scope).workoutIndex().count) ?? 0
        var passed = count == expected && count > 0
        // Warm-up excluded; each variant appears twice in opposite order to expose cache/order effects.
        let order = ["warmup", "baseline", "cap4", "cap8", "historyFirst", "historyFirst", "cap8", "cap4", "baseline"]
        for forced in [true, false] {
            var reference: SharedCapture?
            var appleChecked = Set<String>()
            for variant in order {
                let source = HealthKitSource(scope: scope)
                source.debugFailingStatistics = forced
                let capture = SharedCapture()
                let phases = SchedulingPhaseCapture()
                var config = SyncEngine.Config()
                if variant == "cap4" { config.historyWorkoutReadLimit = 4 }
                if variant == "cap8" { config.historyWorkoutReadLimit = 8 }
                config.historyBeforeDetails = variant == "historyFirst"
                config.phaseObserver = { phases.record($0, start: $1, end: $2) }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-\(UUID().uuidString)")
                let box = Outbox(root: root)
                let engine = SyncEngine(source: source, uploader: capture, outbox: box, scope: scope, config: config, now: { at })
                let started = Date()
                do {
                    let outcome = try await engine.run()
                    let wall = Date().timeIntervalSince(started)
                    if reference == nil { reference = capture }
                    let comparison = try capture.comparison(to: reference!)
                    let complete = outcome == .finished && box.state.detailsDone.count == count && box.pending().isEmpty && box.state.dailyFullAt != nil && box.state.hourlyAt != nil
                    passed = passed && comparison.equivalent && complete
                    m.log("SCHEDULE result variant=\(variant) forced=\(forced) wall=\(String(format: "%.2f", wall)) details=\(box.state.detailsDone.count)/\(count) equal=\(comparison.equivalent) exact=\(comparison.exact) maxDelta=\(comparison.maximumDelta) complete=\(complete) \(phases.summary(start: started.timeIntervalSince1970, wall: wall))")
                    if !forced && variant != "warmup" && appleChecked.insert(variant).inserted {
                        let check = try await SharedRawHistory.withFreshCache {
                            try await source.statisticsVersusRaw(from: at.addingTimeInterval(-10 * 86400), to: at)
                        }
                        passed = passed && check.compared > 0 && check.differences.isEmpty
                        m.log("SCHEDULE APPLE variant=\(variant) compared=\(check.compared) differences=\(check.differences.count)")
                        for difference in check.differences.prefix(5) { m.log("SCHEDULE APPLE DIFFERENCE \(difference)") }
                    }
                } catch {
                    passed = false
                    m.log("SCHEDULE failed variant=\(variant) forced=\(forced): \(error)")
                }
                try? FileManager.default.removeItem(at: root)
            }
        }
        m.log(passed ? "SCHEDULE CHECK OK" : "SCHEDULE CHECK FAILED")
    }
}

private final class SchedulingPhaseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String: (start: Double, end: Double)] = [:]
    func record(_ name: String, start: Double, end: Double) { lock.withLock { phases[name] = (start, end) } }
    func summary(start: Double, wall: Double) -> String {
        lock.withLock {
            var result = [String]()
            for name in ["daily", "hourly", "details"] {
                guard let phase = phases[name] else { result.append("\(name)=MISSING"); continue }
                result.append(String(format: "%@Duration=%.2f %@End=%.2f", name, phase.end - phase.start, name, phase.end - start))
            }
            if let details = phases["details"] { result.append(String(format: "tailAfterDetails=%.2f", max(0, wall - (details.end - start)))) }
            return result.joined(separator: " ")
        }
    }
}
#endif
