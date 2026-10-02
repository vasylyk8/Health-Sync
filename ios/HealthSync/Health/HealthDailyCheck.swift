#if DEBUG
import HealthKit

/// Test harness (debug builds only, launched by CI with `-healthBench -dailyCheck`): writes a few days of ordinary
/// readings into the simulator's HealthKit, reads them back through the app's own daily-metrics code and checks that
/// every metric that has data comes out. This is the end-to-end test of the daily pass against real HealthKit.
@MainActor
enum DailyCheck {
    /// (type, unit, value per reading, cumulative)
    private static let seeds: [(HKQuantityTypeIdentifier, HKUnit, Double, Bool)] = [
        (.stepCount, .count(), 800, true),
        (.activeEnergyBurned, .kilocalorie(), 40, true),
        (.distanceWalkingRunning, .meter(), 600, true),
        (.flightsClimbed, .count(), 4, true),
        (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), 54, false),
        (.heartRateVariabilitySDNN, .secondUnit(with: .milli), 62, false),
        (.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), 15, false),
        (.oxygenSaturation, .percent(), 0.97, false),
        (.vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), 48, false),
        (.walkingSpeed, HKUnit.meter().unitDivided(by: .second()), 1.3, false),
        (.environmentalAudioExposure, .decibelAWeightedSoundPressureLevel(), 70, false),
        (.bodyMass, .gramUnit(with: .kilo), 75, false),
    ]

    static func run(_ m: BenchModel) async {
        let store = HKHealthStore()
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        var share: Set<HKSampleType> = [HKCategoryType(.sleepAnalysis)]
        for s in seeds { share.insert(HKQuantityType(s.0)) }
        m.log("DAILYCHECK authorizing")
        do {
            try await store.requestAuthorization(toShare: share, read: HealthTypes.readPermissions(for: scope).union(share))
        } catch {
            m.log("DAILYCHECK FAIL authorization failed: \(error)")
            m.log("BENCH DONE")
            return
        }
        // Ten days of readings: cumulative types get three readings a day, the others one.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var samples: [HKSample] = []
        for d in 1 ... 10 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            for (id, unit, value, cumulative) in seeds {
                let hours = cumulative ? [8, 12, 16] : [9]
                for h in hours {
                    let start = cal.date(byAdding: .hour, value: h, to: day)!
                    let q = HKQuantity(unit: unit, doubleValue: value + Double(d))
                    samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: q, start: start, end: start.addingTimeInterval(1800)))
                }
            }
            // The night that ends on this day.
            let bed = cal.date(byAdding: .hour, value: -1, to: day)!
            samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue, start: bed, end: bed.addingTimeInterval(7 * 3600)))
        }
        do {
            try await store.save(samples)
            m.log("DAILYCHECK seeded \(samples.count) readings")
        } catch {
            m.log("DAILYCHECK FAIL could not save readings: \(error)")
            m.log("BENCH DONE")
            return
        }

        // What the app should produce: every core metric whose HealthKit type was seeded, plus sleep.
        let seeded = Set(seeds.map { HKQuantityType($0.0).identifier })
        let coverage = HealthTypes.loadCoverage()
        let expected = Set((coverage?.dailyMetrics ?? []).filter { ($0.category ?? "core") == "core" && seeded.contains($0.id) }.map(\.key)).union(["sleepAsleepMin"])
        let source = HealthKitSource(scope: scope)
        do {
            let records = try await source.dailyContext(from: cal.date(byAdding: .day, value: -11, to: today)!, to: Date())
            var found = Set<String>()
            var rows = 0
            for r in records {
                guard case .object(let metrics)? = r["m"] else { continue }
                rows += 1
                found.formUnion(metrics.keys)
            }
            let missing = expected.subtracting(found).sorted()
            m.log("DAILYCHECK \(rows) day rows; \(expected.subtracting(missing).count) of \(expected.count) expected metrics came out")
            m.log("DAILYCHECK found: \(found.sorted().joined(separator: ", "))")
            m.log("DAILYCHECK report: \(source.dailyReport)")
            if missing.isEmpty {
                m.log("DAILYCHECK OK")
            } else {
                m.log("DAILYCHECK FAIL missing: \(missing.joined(separator: ", "))")
            }
        } catch {
            m.log("DAILYCHECK FAIL daily pass threw: \(error) · report: \(source.dailyReport)")
        }
        m.log("BENCH DONE")
    }
}
#endif
