#if DEBUG
import CoreLocation
import HealthKit
import SwiftUI

/// Test harness (debug builds only, launched by CI with `-healthBench`): fills the simulator's HealthKit
/// with synthetic workouts, then times reading them back the same way the app does. Never part of a release.
@MainActor
final class BenchModel: ObservableObject {
    @Published var text = "BENCH starting"
    func log(_ s: String) {
        text += "\n" + s
        print("BENCH " + s)
    }
}

struct BenchView: View {
    @StateObject private var model = BenchModel()
    var body: some View {
        ScrollView {
            Text(model.text)
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("benchOutput")
        }
        .task { await HealthBench.run(model) }
    }
}

@MainActor
enum HealthBench {
    static func run(_ m: BenchModel) async {
        let args = ProcessInfo.processInfo.arguments
        let count = args.firstIndex(of: "-benchCount").flatMap { Int(args[$0 + 1]) } ?? 300
        let store = HKHealthStore()
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        let hr = HKQuantityType(.heartRate)
        let energy = HKQuantityType(.activeEnergyBurned)
        let distance = HKQuantityType(.distanceWalkingRunning)
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), hr, energy, distance, HKSeriesType.workoutRoute()]
        let read = HealthTypes.readPermissions(for: scope).union(share)
        m.log("authorizing")
        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            m.log("authorization failed: \(error)")
            m.log("BENCH DONE")
            return
        }
        m.log("authorized")
        let source = HealthKitSource(scope: scope)
        let existing = (try? await source.workoutIndex().count) ?? 0
        if existing < count {
            await seed(store, count: count - existing, m)
        } else {
            m.log("seed: \(existing) workouts already there")
        }

        await source.benchmark { text in
            Task { @MainActor in m.text = text; print("BENCHSUMMARY\n" + text) }
        }
        // Give the last update a moment to land, then replay the summary as plain log lines.
        try? await Task.sleep(for: .seconds(1))
        m.log("--- speed test ---")
        m.log(m.text)

        await endToEnd(source, m)
        m.log("BENCH DONE")
    }

    /// Reads every workout the way the app does (per-workout queries, many at once) and reports the rate.
    private static func endToEnd(_ source: HealthKitSource, _ m: BenchModel) async {
        guard let index = try? await source.workoutIndex() else {
            m.log("e2e: could not list workouts")
            return
        }
        for width in [1, 8, 24] {
            source.setQueryConcurrency(width * 2)
            let ids = Array(index.prefix(120))
            var points = 0
            var done = 0
            let t0 = Date()
            await withTaskGroup(of: Int.self) { group in
                var next = 0
                func add() {
                    guard next < ids.count else { return }
                    let id = ids[next].id
                    next += 1
                    group.addTask {
                        let records = try? await source.workoutDetail(id: id, gen: 1)
                        return records?.count ?? 0
                    }
                }
                for _ in 0 ..< width { add() }
                while let c = await group.next() {
                    points += c
                    done += 1
                    add()
                }
            }
            let secs = Date().timeIntervalSince(t0)
            m.log(String(format: "e2e width %d: %d workouts in %.1f s = %.1f workouts/min (%d records)", width, done, secs, Double(done) / secs * 60, points))
        }
    }

    private static func seed(_ store: HKHealthStore, count: Int, _ m: BenchModel) async {
        let hr = HKQuantityType(.heartRate)
        let energy = HKQuantityType(.activeEnergyBurned)
        let distance = HKQuantityType(.distanceWalkingRunning)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let t0 = Date()
        var samplesTotal = 0
        var failures = 0
        m.log("seeding \(count) workouts")
        for i in 0 ..< count {
            let dur = 1800 + Double(i % 7) * 600
            // One workout every ~10 days going back, so the history spans years like a real one.
            let start = Date().addingTimeInterval(-Double(i + 1) * 864_000 * 0.9 - 7200)
            let config = HKWorkoutConfiguration()
            config.activityType = i % 3 == 0 ? .cycling : .running
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
            do {
                try await builder.beginCollection(at: start)
                var samples: [HKSample] = []
                var t = 0.0
                while t < dur {
                    let v = 125 + 30 * sin(t / 300 + Double(i))
                    samples.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpm, doubleValue: v), start: start.addingTimeInterval(t), end: start.addingTimeInterval(t)))
                    t += 3
                }
                t = 0
                while t + 10 <= dur {
                    let s = start.addingTimeInterval(t), e = start.addingTimeInterval(t + 10)
                    samples.append(HKQuantitySample(type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 0.4), start: s, end: e))
                    samples.append(HKQuantitySample(type: distance, quantity: HKQuantity(unit: .meter(), doubleValue: 28), start: s, end: e))
                    t += 10
                }
                try await builder.addSamples(samples)
                try await builder.endCollection(at: start.addingTimeInterval(dur))
                guard let workout = try await builder.finishWorkout() else { failures += 1; continue }
                samplesTotal += samples.count
                if i % 2 == 0 {
                    let route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
                    var locs: [CLLocation] = []
                    var r = 0.0
                    while r < dur {
                        locs.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 50 + r * 1e-6, longitude: 30 + r * 1e-6), altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3, timestamp: start.addingTimeInterval(r)))
                        r += 3
                    }
                    try await route.insertRouteData(locs)
                    _ = try await route.finishRoute(with: workout, metadata: nil)
                }
            } catch {
                failures += 1
                if failures <= 3 { m.log("seed error: \(error)") }
            }
            if (i + 1) % 25 == 0 {
                m.log(String(format: "seeded %d/%d (%.0f s, %d samples, %d failures)", i + 1, count, Date().timeIntervalSince(t0), samplesTotal, failures))
            }
        }
        m.log(String(format: "seed done: %d workouts, %d samples in %.0f s", count - failures, samplesTotal, Date().timeIntervalSince(t0)))
    }
}
#endif
