#if DEBUG
import CoreLocation
import HealthKit

/// Experiments on phone-shaped synthetic data (debug builds only; see HealthBench). Each one prints
/// one line, so a CI run answers "where does a workout's read time go and what makes it faster".
@MainActor
enum HealthLab {
    static let typesHeavy: [(HKQuantityTypeIdentifier, HKUnit, Double, Bool)] = [
        // (type, unit, seconds between samples, cumulative). Spacing matches the per-workout sample
        // counts measured on a real iPhone (about 900-1,800 per type over ~50 minutes).
        (.heartRate, HKUnit.count().unitDivided(by: .minute()), 3.0, false),
        (.activeEnergyBurned, .kilocalorie(), 1.7, true),
        (.basalEnergyBurned, .kilocalorie(), 1.85, true),
        (.distanceWalkingRunning, .meter(), 2.6, true),
        (.stepCount, .count(), 3.4, true),
        (.runningPower, .watt(), 3.5, false),
        (.runningSpeed, HKUnit.meter().unitDivided(by: .second()), 3.5, false),
        (.runningStrideLength, .meter(), 3.5, false),
        (.runningVerticalOscillation, .meterUnit(with: .centi), 3.5, false),
    ]

    static var shareTypes: Set<HKSampleType> {
        var s: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for t in typesHeavy { s.insert(HKQuantityType(t.0)) }
        return s
    }

    /// Recent "heavy" workouts (9 types, ~9,000 samples, 5,000-point route) and older "light" ones
    /// (heart rate, energy and distance only, no route), like a long real history.
    static func seed(_ store: HKHealthStore, heavy: Int, light: Int, spacingDays: Double = 1.3, _ m: BenchModel) async {
        let t0 = Date()
        var samples = 0, failures = 0
        for i in 0 ..< heavy + light {
            let isHeavy = i < heavy
            let dur: Double = isHeavy ? 3000 : 1800
            let start = Date().addingTimeInterval(-Double(i + 1) * 86_400 * spacingDays - 7200)
            let config = HKWorkoutConfiguration()
            config.activityType = .running
            config.locationType = .outdoor
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
            let types = isHeavy ? typesHeavy : Array(typesHeavy.filter { [.heartRate, .activeEnergyBurned, .distanceWalkingRunning].contains($0.0) })
            do {
                try await builder.beginCollection(at: start)
                var batch: [HKSample] = []
                for (id, unit, step0, cumulative) in types {
                    let step = isHeavy ? step0 : step0 * (id == .heartRate ? 2 : 10)
                    let type = HKQuantityType(id)
                    var t = 0.0
                    while t + step <= dur {
                        let v: Double
                        switch id {
                        case .heartRate: v = 120 + 30 * sin(t / 300)
                        case .runningPower: v = 250 + 20 * sin(t / 90)
                        case .runningSpeed: v = 3 + 0.3 * sin(t / 120)
                        case .runningStrideLength: v = 1.1 + 0.05 * sin(t / 60)
                        case .runningVerticalOscillation: v = 8.5 + 0.4 * sin(t / 45)
                        case .stepCount: v = 9
                        case .distanceWalkingRunning: v = 3.1 * step
                        default: v = 0.05 + 0.01 * sin(t)
                        }
                        let s = start.addingTimeInterval(t)
                        let e = cumulative ? start.addingTimeInterval(t + step) : s
                        batch.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: v), start: s, end: e))
                        t += step
                    }
                }
                try await builder.addSamples(batch)
                try await builder.endCollection(at: start.addingTimeInterval(dur))
                guard let workout = try await builder.finishWorkout() else { failures += 1; continue }
                samples += batch.count
                if isHeavy {
                    let route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
                    var locs: [CLLocation] = []
                    var r = 0.0
                    while r < dur {
                        locs.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 50.4501 + r * 1.3e-5, longitude: 30.5234 + sin(r / 200) * 1e-3),
                                               altitude: 120 + sin(r / 100) * 5, horizontalAccuracy: 4, verticalAccuracy: 3, course: 87.5, speed: 3.05, timestamp: start.addingTimeInterval(r)))
                        r += 0.6
                    }
                    try await route.insertRouteData(locs)
                    _ = try await route.finishRoute(with: workout, metadata: nil)
                }
            } catch {
                failures += 1
                if failures <= 3 { m.log("seed error: \(error)") }
            }
            if (i + 1) % 20 == 0 { m.log(String(format: "seeded %d/%d (%.0f s, %d samples)", i + 1, heavy + light, Date().timeIntervalSince(t0), samples)) }
        }
        m.log(String(format: "seed done: %d heavy + %d light workouts, %d samples, %d failures, %.0f s", heavy, light, samples, failures, Date().timeIntervalSince(t0)))
    }

    static func timed(_ body: () async -> Void) async -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        await body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    }

    nonisolated static func query(_ store: HKHealthStore, _ type: HKSampleType, _ predicate: NSPredicate?) async -> [HKSample] {
        await withCheckedContinuation { c in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, r, _ in c.resume(returning: r ?? []) }
            store.execute(q)
        }
    }

    nonisolated static func locations(_ store: HKHealthStore, _ route: HKWorkoutRoute) async -> Int {
        await withCheckedContinuation { c in
            var n = 0
            let q = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                n += batch?.count ?? 0
                if done || error != nil { c.resume(returning: n) }
            }
            store.execute(q)
        }
    }

    /// Runs `jobs` with at most `width` at once; returns seconds.
    static func parallel(_ jobs: [@Sendable () async -> Void], width: Int) async -> Double {
        await timed {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask { await job() }
                }
                for _ in 0 ..< max(1, width) { add() }
                while await group.next() != nil { add() }
            }
        }
    }

    static func run(_ store: HKHealthStore, scope: SyncScope, _ m: BenchModel) async {
        let all = await query(store, HKObjectType.workoutType(), nil).compactMap { $0 as? HKWorkout }.sorted { $0.startDate > $1.startDate }
        let heavy = Array(all.filter { $0.allStatistics.count > 3 }.prefix(40))
        let light = Array(all.filter { $0.allStatistics.count <= 3 }.prefix(40))
        m.log("lab: \(all.count) workouts, \(heavy.count) heavy and \(light.count) light sampled")
        let source = HealthKitSource(scope: scope)
        source.setQueryConcurrency(96)
        func f(_ v: Double) -> String { String(format: "%.1f", v) }

        // E0: A/B of read settings on the same data, the way the sync reads (24 workouts in progress):
        // A = before (routes behind the shared query gate at 16), B = route lane of 8 + query gate 32.
        let everyId = all.map(\.uuid.uuidString)
        for (label, shared, queries, routes, inProgress) in [("A shared gate 16", true, 16, 8, 24), ("B route lane 8, gate 32", false, 32, 8, 24),
                                                  ("A shared gate 16 (again)", true, 16, 8, 24), ("B route lane 8, gate 32 (again)", false, 32, 8, 24),
                                                  ("D lane 8, gate 64, 48 workouts at once", false, 64, 8, 48),
                                                  ("E lane 8, gate 16, 24 workouts at once", false, 16, 8, 24)] {
            let src = HealthKitSource(scope: scope)
            src.routesShareQueryGate = shared
            src.setQueryConcurrency(queries)
            src.setRouteConcurrency(routes)
            let jobs: [@Sendable () async -> Void] = everyId.map { id in { _ = try? await src.workoutDetail(id: id, gen: 1) } }
            let secs = await parallel(jobs, width: inProgress)
            m.log("E0 \(label): all \(everyId.count) workouts in \(f(secs)) s = \(f(Double(everyId.count) / secs * 60)) workouts/min")
        }

        // E6: the same reads by time window + same source instead of the workout association
        // (cheaper per query in E3), and whether they return exactly the same samples.
        let windowTypes = typesHeavy.map { HKQuantityType($0.0) }
        func windowPredicate(_ w: HKWorkout) -> NSPredicate {
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: [.strictStartDate, .strictEndDate]),
                HKQuery.predicateForObjects(from: [w.sourceRevision.source]),
            ])
        }
        for (name, ws) in [("heavy", heavy), ("light", light)] where !ws.isEmpty {
            var same = 0, total = 0
            for w in ws.prefix(10) {
                for t in windowTypes {
                    let a = Set(await query(store, t, HKQuery.predicateForObjects(from: w)).map(\.uuid))
                    let b = Set(await query(store, t, windowPredicate(w)).map(\.uuid))
                    total += 1
                    if a == b { same += 1 }
                }
            }
            let pairs = ws.flatMap { w in windowTypes.map { (w, $0) } }
            let jobsA: [@Sendable () async -> Void] = pairs.map { p in { _ = await query(store, p.1, HKQuery.predicateForObjects(from: p.0)) } }
            let jobsW: [@Sendable () async -> Void] = pairs.map { p in { _ = await query(store, p.1, windowPredicate(p.0)) } }
            let tA = await parallel(jobsA, width: 9)
            let tW = await parallel(jobsW, width: 9)
            let tA2 = await parallel(jobsA, width: 9)
            m.log("E6 \(name): association \(f(Double(ws.count) / tA * 60))/\(f(Double(ws.count) / tA2 * 60)) vs window+source \(f(Double(ws.count) / tW * 60)) workouts/min (9 at once); identical \(same)/\(total) type-workout pairs")
        }

        // E1: the app's whole per-workout read at several widths.
        for (name, ws) in [("heavy", heavy), ("light", light)] where !ws.isEmpty {
            for width in [1, 8, 32] {
                let ids = ws.map(\.uuid.uuidString)
                let jobs: [@Sendable () async -> Void] = ids.map { id in { _ = try? await source.workoutDetail(id: id, gen: 1) } }
                let secs = await parallel(jobs, width: width)
                m.log("E1 whole \(name) workout, \(width) at once: \(f(Double(ws.count) / secs * 60)) workouts/min")
            }
        }

        // E2: where one heavy workout's time goes (one part at a time).
        var parts: [String: Double] = [:]
        var routePoints = 0
        for w in heavy.prefix(10) {
            for (id, _, _, _) in typesHeavy {
                let t = HKQuantityType(id)
                let d = await timed { _ = await query(store, t, HKQuery.predicateForObjects(from: w)) }
                parts["q " + id.rawValue.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: ""), default: 0] += d
            }
            var routes: [HKWorkoutRoute] = []
            let dLookup = await timed { routes = await query(store, HKSeriesType.workoutRoute(), HKQuery.predicateForObjects(from: w)).compactMap { $0 as? HKWorkoutRoute } }
            parts["route lookup", default: 0] += dLookup
            let dPoints = await timed {
                for r in routes {
                    let n = await locations(store, r)
                    routePoints += n
                }
            }
            parts["route points", default: 0] += dPoints
        }
        let total = parts.values.reduce(0, +)
        m.log("E2 heavy workout parts (ms each, of \(f(total * 100)) ms): " + parts.sorted { $0.value > $1.value }.map { "\($0.key) \(f($0.value * 100))" }.joined(separator: ", ") + " | \(routePoints / 10) route points each")

        // E3: one query per type for a group of workouts (OR of their associations) vs one per workout.
        for (name, ws) in [("heavy", heavy), ("light", light)] where ws.count >= 16 {
            let group = Array(ws.prefix(16))
            let types = typesHeavy.map { HKQuantityType($0.0) }
            var perWorkout: [Int: Int] = [:]
            let tPer = await timed {
                for (i, w) in group.enumerated() {
                    for t in types {
                        let n = await query(store, t, HKQuery.predicateForObjects(from: w)).count
                        perWorkout[i, default: 0] += n
                    }
                }
            }
            var grouped: [Int: Int] = [:]
            let sortedGroup = group.enumerated().sorted { $0.element.startDate < $1.element.startDate }
            let tGroup = await timed {
                let or = NSCompoundPredicate(orPredicateWithSubpredicates: group.map { HKQuery.predicateForObjects(from: $0) })
                for t in types {
                    for s in await query(store, t, or) {
                        // The workout whose time range holds the sample.
                        if let hit = sortedGroup.last(where: { $0.element.startDate <= s.startDate && s.startDate <= $0.element.endDate }) {
                            grouped[hit.offset, default: 0] += 1
                        }
                    }
                }
            }
            let same = (0 ..< group.count).filter { perWorkout[$0, default: 0] == grouped[$0, default: 0] }.count
            m.log("E3 \(name): per workout \(f(tPer * 1000 / 16)) ms/workout, grouped by 16 \(f(tGroup * 1000 / 16)) ms/workout, identical in \(same)/16")
            // Same, by time window (no association): one query per type for the group's whole span.
            let span = HKQuery.predicateForSamples(withStart: group.map(\.startDate).min(), end: group.map(\.endDate).max(), options: [])
            let tSpan = await timed { for t in types { _ = await query(store, t, span) } }
            m.log("E3 \(name): one time-span query per type for 16 workouts: \(f(tSpan * 1000 / 16)) ms/workout")
        }

        // E4: routes.
        var allRoutes: [HKWorkoutRoute] = []
        let tAllRoutes = await timed { allRoutes = await query(store, HKSeriesType.workoutRoute(), nil).compactMap { $0 as? HKWorkoutRoute } }
        m.log("E4 all routes in one query: \(allRoutes.count) in \(f(tAllRoutes * 1000)) ms")
        let some = Array(allRoutes.prefix(16))
        for width in [1, 8] {
            let jobs: [@Sendable () async -> Void] = some.map { r in { _ = await locations(store, r) } }
            let secs = await parallel(jobs, width: width)
            m.log("E4 route points, \(width) at once: \(f(Double(some.count) / secs)) routes/s")
        }

        // E5: per-type queries for heavy workouts at several widths (is HealthKit itself parallel?).
        let pairs = heavy.prefix(20).flatMap { w in typesHeavy.map { (w, HKQuantityType($0.0)) } }
        for width in [1, 9, 36] {
            let jobs: [@Sendable () async -> Void] = pairs.map { p in { _ = await query(store, p.1, HKQuery.predicateForObjects(from: p.0)) } }
            let secs = await parallel(jobs, width: width)
            m.log("E5 heavy per-type queries, \(width) at once: \(f(Double(min(20, heavy.count)) / secs * 60)) workouts/min")
        }
    }
}
#endif
