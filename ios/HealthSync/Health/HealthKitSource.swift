import CoreLocation
import Foundation
import HealthKit

/// Reads Apple Health through HealthKit and converts workouts (with their raw data) and daily
/// context to batch records. Read-only.
final class HealthKitSource: HealthSource, @unchecked Sendable {
    private let store = HKHealthStore()
    /// Extra stores with their own connection to HealthKit, used round-robin for raw workout data reads.
    private let readStores: [HKHealthStore] = (0..<4).map { _ in HKHealthStore() }
    private let storeLock = NSLock()
    private var nextStoreIndex = 0
    private func nextStore() -> HKHealthStore {
        storeLock.withLock {
            defer { nextStoreIndex = (nextStoreIndex + 1) % readStores.count }
            return readStores[nextStoreIndex]
        }
    }
    private let scope: SyncScope
    private let quantitiesById: [String: WorkoutQuantity]
    /// Apple documents no limit on parallel queries, so the number in flight is tuned while syncing (`ReadTuner`).
    private let queryGate = ReadGate(limit: 24)
    var queryConcurrency: Int { queryGate.currentLimit }
    func setQueryConcurrency(_ n: Int) { queryGate.setLimit(n) }
    /// Workouts from the last `workoutIndex()`, so each one is not fetched a second time by uuid before its
    /// raw data is read. An entry is dropped once that workout has been read.
    private let cacheLock = NSLock()
    private var workoutCache: [String: HKWorkout] = [:]

    init(scope: SyncScope) {
        self.scope = scope
        quantitiesById = Dictionary(scope.workoutQuantities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization(scope: SyncScope) async throws {
        try await store.requestAuthorization(toShare: [], read: HealthTypes.readPermissions(for: scope))
    }

    // MARK: Workout summaries

    func workouts(from: Date, to: Date) async throws -> [Record] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples = try await fetch(HKObjectType.workoutType(), predicate: predicate, sort: sort)
        return samples.compactMap { ($0 as? HKWorkout).map(workout) }
    }

    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        guard let sampleType = type.sampleType else { return AnchoredPage(records: [], newAnchor: anchor, objectCount: 0) }
        let hkAnchor = anchor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let (samples, deleted, newAnchor): ([HKSample], [HKDeletedObject], HKQueryAnchor?) = try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: hkAnchor, limit: limit) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor)) }
            }
            store.execute(q)
        }
        var records = samples.compactMap { ($0 as? HKWorkout).map(workout) }
        records.append(contentsOf: deleted.map { ["k": "d", "id": .string($0.uuid.uuidString)] })
        let anchorData = newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return AnchoredPage(records: records, newAnchor: anchorData, objectCount: samples.count + deleted.count)
    }

    func workoutIndex() async throws -> [WorkoutRef] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples = try await fetch(HKObjectType.workoutType(), predicate: nil, sort: sort)
        let workouts = samples.compactMap { $0 as? HKWorkout }
        cacheLock.withLock { workoutCache = Dictionary(workouts.map { ($0.uuid.uuidString, $0) }, uniquingKeysWith: { first, _ in first }) }
        return samples.map { WorkoutRef(id: $0.uuid.uuidString, start: $0.startDate) }
    }

    /// Everything Apple attaches to a workout, as batch records.
    private func workout(_ w: HKWorkout) -> Record {
        var r: Record = ["k": "w", "id": .string(w.uuid.uuidString), "s": w.startDate.ms, "e": w.endDate.ms]
        r["src"] = .string(w.sourceRevision.source.name)
        r["bid"] = .string(w.sourceRevision.source.bundleIdentifier)
        if let model = w.device?.model ?? w.device?.name { r["dev"] = .string(model) }
        if let tz = w.metadata?[HKMetadataKeyTimeZone] as? String { r["tz"] = .string(tz) }
        if let md = metadata(w.metadata, maxBytes: 8_000) { r["md"] = md }
        if let version = w.sourceRevision.version { r["srcVersion"] = .string(String(version.prefix(40))) }
        r["act"] = .int(Int64(w.workoutActivityType.rawValue))
        r["actName"] = .string(WorkoutNames.name(w.workoutActivityType))
        r["dur"] = .double(w.duration)

        // Apple's own statistics for every quantity type it recorded during the workout.
        var stats: [String: RecordValue] = [:]
        for (type, s) in w.allStatistics {
            guard let spec = quantitiesById[type.identifier] else { continue }
            var o: [String: RecordValue] = ["u": .string(spec.unitLabel)]
            if spec.cumulative {
                if let v = s.sumQuantity() { o["sum"] = .double(v.doubleValue(for: spec.unit)) }
            } else {
                if let v = s.averageQuantity() { o["avg"] = .double(v.doubleValue(for: spec.unit)) }
                if let v = s.minimumQuantity() { o["min"] = .double(v.doubleValue(for: spec.unit)) }
                if let v = s.maximumQuantity() { o["max"] = .double(v.doubleValue(for: spec.unit)) }
            }
            if o.count > 1 { stats[spec.name] = .object(o) }
        }
        if !stats.isEmpty { r["stats"] = .object(stats) }
        if case .object(let hr)? = stats["HeartRate"] {
            if let v = hr["avg"] { r["hrAvg"] = v }
            if let v = hr["max"] { r["hrMax"] = v }
        }
        if case .object(let e)? = stats["ActiveEnergyBurned"], let v = e["sum"] { r["en"] = v }
        // Total distance: the first distance type Apple recorded for this workout.
        let distanceNames = ["DistanceWalkingRunning", "DistanceCycling", "DistanceSwimming", "DistanceWheelchair", "DistanceDownhillSnowSports",
                             "DistanceCrossCountrySkiing", "DistancePaddleSports", "DistanceRowing", "DistanceSkatingSports"]
        for name in distanceNames {
            if case .object(let d)? = stats[name], let v = d["sum"] {
                r["dist"] = v
                break
            }
        }

        // Workouts saved by other apps often carry only these totals, not statistics (deprecated on
        // newer iOS, but still filled in for them).
        if r["en"] == nil, let e = w.totalEnergyBurned { r["en"] = .double(e.doubleValue(for: .kilocalorie())) }
        if r["dist"] == nil, let d = w.totalDistance { r["dist"] = .double(d.doubleValue(for: .meter())) }

        if let events = w.workoutEvents, !events.isEmpty {
            r["ev"] = .array(events.prefix(2_000).map { e in
                .object(["t": e.dateInterval.start.ms, "type": .int(Int64(e.type.rawValue)), "dur": .double(e.dateInterval.duration)])
            })
        }
        if w.workoutActivities.count > 1 {
            r["acts"] = .array(w.workoutActivities.map { a in
                .object([
                    "s": a.startDate.ms, "e": (a.endDate ?? w.endDate).ms,
                    "act": .int(Int64(a.workoutConfiguration.activityType.rawValue)),
                    "actName": .string(WorkoutNames.name(a.workoutConfiguration.activityType)),
                ])
            })
        }
        return r
    }

    /// Keeps scalar metadata values (quantities as text, e.g. "24 degC"); drops anything else.
    private func metadata(_ md: [String: Any]?, maxBytes: Int) -> RecordValue? {
        guard let md, !md.isEmpty else { return nil }
        var out: [String: RecordValue] = [:]
        var size = 0
        for (key, value) in md.sorted(by: { $0.key < $1.key }) where key != HKMetadataKeyTimeZone {
            let v: RecordValue
            switch value {
            case let b as Bool: v = .bool(b)
            case let n as NSNumber: v = .double(n.doubleValue)
            case let s as String: v = .string(String(s.prefix(200)))
            case let d as Date: v = d.ms
            case let q as HKQuantity: v = .string(q.description)
            default: continue
            }
            size += key.count + 16
            if size > maxBytes { break }
            out[String(key.prefix(100))] = v
        }
        return out.isEmpty ? nil : .object(out)
    }

    // MARK: Workout raw data

    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let w: HKWorkout
        if let cached = cacheLock.withLock({ workoutCache[id] }) {
            w = cached
        } else {
            let found = try await fetch(HKObjectType.workoutType(), predicate: HKQuery.predicateForObject(with: uuid), sort: nil, limit: 1)
            guard let fetched = found.first as? HKWorkout else { return nil }
            w = fetched
        }
        defer { cacheLock.withLock { workoutCache[id] = nil } }

        var records: [Record] = []
        var expected: [String: Int] = [:]
        // Types Apple recorded for this workout. Heart rate is always tried, because workouts imported
        // from other apps carry no Apple statistics but often have heart rate samples.
        var wanted = Set(w.allStatistics.keys.map(\.identifier))
        wanted.insert(HealthTypes.quantityPrefix + "HeartRate")
        let specs = scope.workoutQuantities.filter { wanted.contains($0.id) }

        // Every quantity type and the route are read at the same time (each is an independent query);
        // results are put back in a fixed order so the output does not depend on which finished first.
        enum Part { case series(Int, [SeriesPoint]), route([RoutePoint]) }
        let timing = SyncTiming.shared
        let parts: [Part] = try await withThrowingTaskGroup(of: Part.self) { group in
            for (i, q) in specs.enumerated() {
                group.addTask {
                    let points = try await timing.measure("hk.quantity") { try await self.quantityPoints(q, workout: w, allowTimeWindow: q.name == "HeartRate") }
                    return .series(i, points)
                }
            }
            group.addTask {
                let points = try await timing.measure("hk.route") { try await self.routePoints(w) }
                return .route(points)
            }
            var out: [Part] = []
            for try await part in group { out.append(part) }
            return out
        }
        var route: [RoutePoint] = []
        var seriesByIndex: [Int: [SeriesPoint]] = [:]
        for part in parts {
            switch part {
            case .series(let i, let points): seriesByIndex[i] = points
            case .route(let points): route = points
            }
        }
        for (i, q) in specs.enumerated() {
            guard let points = seriesByIndex[i], !points.isEmpty else { continue }
            let built = WorkoutRecords.series(wid: id, name: q.name, gen: gen, unit: q.unitLabel, points: points)
            guard built.count > 0 else { continue }
            records.append(contentsOf: built.records)
            expected[q.name] = built.count
        }
        if !route.isEmpty {
            let built = WorkoutRecords.route(wid: id, gen: gen, points: route)
            if built.count > 0 {
                records.append(contentsOf: built.records)
                expected["route"] = built.count
            }
        }
        records.append(WorkoutRecords.mark(wid: id, gen: gen, expected: expected))
        SyncTiming.shared.count("hk.workouts")
        return records
    }

    /// Readings of one quantity type belonging to the workout. Cumulative types (distance, energy,
    /// steps) are increments stamped with the end of their interval; discrete types (heart rate,
    /// speed, power...) are instantaneous readings.
    private func quantityPoints(_ q: WorkoutQuantity, workout w: HKWorkout, allowTimeWindow: Bool) async throws -> [SeriesPoint] {
        var found = try await quantitySamples(q.type, predicate: HKQuery.predicateForObjects(from: w))
        SyncTiming.shared.count("hk.samples", found.count)
        if found.isEmpty && allowTimeWindow {
            let window = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: [])
            let sameSource = HKQuery.predicateForObjects(from: [w.sourceRevision.source])
            found = try await quantitySamples(q.type, predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [window, sameSource]))
        }
        // Plain samples become one point each; series samples (e.g. heart rate recorded as a series)
        // are expanded at the same time, one query each.
        var chunks = [[SeriesPoint]](repeating: [], count: found.count)
        var seriesSamples: [(Int, HKQuantitySample)] = []
        for (i, s) in found.enumerated() {
            if !q.cumulative && s.count > 1 {
                seriesSamples.append((i, s))
            } else {
                let t = q.cumulative ? s.endDate.msValue : s.startDate.msValue
                chunks[i] = [SeriesPoint(t: t, v: s.quantity.doubleValue(for: q.unit))]
            }
        }
        if !seriesSamples.isEmpty {
            let expanded: [(Int, [SeriesPoint])] = try await withThrowingTaskGroup(of: (Int, [SeriesPoint]).self) { group in
                for (i, s) in seriesSamples {
                    group.addTask {
                        let pts = try await self.expandSeries(s, q)
                        return (i, pts)
                    }
                }
                var out: [(Int, [SeriesPoint])] = []
                for try await item in group { out.append(item) }
                return out
            }
            for (i, pts) in expanded { chunks[i] = pts }
        }
        return chunks.flatMap { $0 }
    }

    /// Every individual reading of a series sample (e.g. heart rate every few seconds).
    private func expandSeries(_ sample: HKQuantitySample, _ q: WorkoutQuantity) async throws -> [SeriesPoint] {
        let predicate = HKQuery.predicateForObject(with: sample.uuid)
        await queryGate.acquire()
        defer { queryGate.release() }
        return try await withCheckedThrowingContinuation { cont in
            var acc: [SeriesPoint] = []
            let query = HKQuantitySeriesSampleQuery(quantityType: q.type, predicate: predicate) { _, quantity, interval, _, done, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if let quantity, let interval { acc.append(SeriesPoint(t: interval.start.msValue, v: quantity.doubleValue(for: q.unit))) }
                if done { cont.resume(returning: acc) }
            }
            nextStore().execute(query)
        }
    }

    private func routePoints(_ w: HKWorkout) async throws -> [RoutePoint] {
        let routes = try await fetch(HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: w), sort: nil)
        var out: [RoutePoint] = []
        for case let route as HKWorkoutRoute in routes {
            for loc in try await locations(of: route) {
                out.append(RoutePoint(
                    t: loc.timestamp.msValue, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                    alt: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                    spd: loc.speed >= 0 ? loc.speed : nil,
                    crs: loc.course >= 0 ? loc.course : nil,
                    ha: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                    va: loc.verticalAccuracy >= 0 ? loc.verticalAccuracy : nil))
            }
        }
        return out
    }

    private func locations(of route: HKWorkoutRoute) async throws -> [CLLocation] {
        await queryGate.acquire()
        defer { queryGate.release() }
        return try await withCheckedThrowingContinuation { cont in
            var acc: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                acc.append(contentsOf: batch ?? [])
                if done { cont.resume(returning: acc) }
            }
            nextStore().execute(query)
        }
    }

    // MARK: Daily context

    /// One value of one daily metric on one local day.
    private struct DailyCell: Sendable {
        var day: String
        var key: String
        var value: RecordValue
    }

    func dailyContext(from: Date, to: Date) async throws -> [Record] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let metrics = scope.dailyMetrics
        // The metrics are independent queries (dozens per year of history), so several run at the same time;
        // results are merged in the metrics' order so the output does not depend on which finished first.
        var perMetric = [[DailyCell]?](repeating: nil, count: metrics.count)
        var failures = 0
        var firstError: Error?
        let limit = max(1, Self.dailyConcurrency)
        await withTaskGroup(of: (Int, [DailyCell]?, Error?).self) { group in
            var next = 0
            func startNext() {
                guard next < metrics.count else { return }
                let i = next
                next += 1
                group.addTask {
                    do {
                        return (i, try await SyncTiming.shared.measure("hk.daily") { try await self.dailyCells(metrics[i], start: start, to: to, calendar: cal) }, nil)
                    } catch {
                        // One metric failing (e.g. no permission) must not lose the others.
                        return (i, nil, error)
                    }
                }
            }
            for _ in 0 ..< min(limit, metrics.count) { startNext() }
            while let (i, cells, error) = await group.next() {
                if let error {
                    failures += 1
                    firstError = firstError ?? error
                } else {
                    perMetric[i] = cells
                }
                startNext()
            }
        }
        if failures > 0, failures == metrics.count, let firstError { throw firstError }
        var days: [String: [String: RecordValue]] = [:]
        for cells in perMetric {
            for c in cells ?? [] { days[c.day, default: [:]][c.key] = c.value }
        }
        return days.keys.sorted().map { day in ["k": "day", "day": .string(day), "m": .object(days[day] ?? [:])] }
    }

    /// Metric queries running at once during the daily-context pass.
    private static let dailyConcurrency = 8

    private func dailyCells(_ metric: DailyMetric, start: Date, to: Date, calendar cal: Calendar) async throws -> [DailyCell] {
        var out: [DailyCell] = []
        switch metric.kind {
        case .quantity(let type, let unit, let agg, let scale):
            for (day, value) in try await dailyStatistics(type, unit: unit, agg: agg, scale: scale, from: start, to: to, calendar: cal) {
                out.append(DailyCell(day: day, key: metric.key, value: .double(value)))
            }
        case .category(let type, let mode):
            for (day, value) in try await dailyCategory(type, mode: mode, from: start, to: to, calendar: cal) {
                out.append(DailyCell(day: day, key: metric.key, value: value))
            }
        case .sleep(let type):
            // A night can start the evening before the first day.
            let segments = try await sleepSegments(type, from: start.addingTimeInterval(-86_400), to: to)
            for (day, values) in SleepNights.nights(segments, calendar: cal) where day >= SleepNights.dayKey(start, calendar: cal) {
                for (k, v) in values { out.append(DailyCell(day: day, key: k, value: v)) }
            }
        case .rings:
            for (day, values) in try await activityRings(from: start, to: to, calendar: cal) {
                for (k, v) in values { out.append(DailyCell(day: day, key: k, value: v)) }
            }
        case .stateOfMind:
            if #available(iOS 18.0, *) {
                for (day, values) in try await moods(from: start, to: to, calendar: cal) {
                    for (k, v) in values { out.append(DailyCell(day: day, key: k, value: v)) }
                }
            }
        }
        return out
    }

    func earliestDailyDate() async throws -> Date? {
        // One "oldest sample" query per metric, all at the same time.
        let types: [HKSampleType] = scope.dailyMetrics.compactMap { metric in
            switch metric.kind {
            case .quantity(let t, _, _, _): return t
            case .category(let t, _): return t
            case .sleep(let t): return t
            case .rings: return nil
            case .stateOfMind:
                if #available(iOS 18.0, *) { return HKObjectType.stateOfMindType() }
                return nil
            }
        }
        return await withTaskGroup(of: Date?.self) { group in
            for type in types {
                group.addTask {
                    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                    return try? await self.fetch(type, predicate: nil, sort: sort, limit: 1).first?.startDate
                }
            }
            var earliest: Date?
            for await first in group {
                if let first, earliest.map({ first < $0 }) ?? true { earliest = first }
            }
            return earliest
        }
    }

    private func dailyStatistics(_ type: HKQuantityType, unit: HKUnit, agg: DailyAgg, scale: Double, from: Date, to: Date, calendar: Calendar) async throws -> [(String, Double)] {
        let options: HKStatisticsOptions
        switch agg {
        case .sum: options = .cumulativeSum
        case .avg: options = .discreteAverage
        case .min: options = .discreteMin
        case .max: options = .discreteMax
        case .last: options = .mostRecent
        }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: options, anchorDate: from, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, collection, error in
                if let collection { cont.resume(returning: collection) } else { cont.resume(throwing: error ?? HealthSourceError.noResults) }
            }
            store.execute(q)
        }
        var out: [(String, Double)] = []
        collection.enumerateStatistics(from: from, to: to) { stats, _ in
            let quantity: HKQuantity?
            switch agg {
            case .sum: quantity = stats.sumQuantity()
            case .avg: quantity = stats.averageQuantity()
            case .min: quantity = stats.minimumQuantity()
            case .max: quantity = stats.maximumQuantity()
            case .last: quantity = stats.mostRecentQuantity()
            }
            guard let quantity else { return }
            let v = quantity.doubleValue(for: unit) * scale
            if v.isFinite { out.append((SleepNights.dayKey(stats.startDate, calendar: calendar), v)) }
        }
        return out
    }

    private func dailyCategory(_ type: HKCategoryType, mode: CategoryMode, from: Date, to: Date, calendar: Calendar) async throws -> [(String, RecordValue)] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let found = try await fetch(type, predicate: predicate, sort: nil).compactMap { $0 as? HKCategorySample }
        var out: [(String, RecordValue)] = []
        switch mode {
        case .minutes:
            var minutes: [String: Double] = [:]
            for s in found { minutes[SleepNights.dayKey(s.startDate, calendar: calendar), default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60 }
            for (day, total) in minutes { out.append((day, RecordValue.double((total * 10).rounded() / 10))) }
        case .values:
            var values: [String: Set<Int>] = [:]
            for s in found { values[SleepNights.dayKey(s.startDate, calendar: calendar), default: []].insert(s.value) }
            for (day, set) in values {
                let list: [RecordValue] = set.sorted().map { RecordValue.int(Int64($0)) }
                out.append((day, RecordValue.array(list)))
            }
        }
        return out
    }

    private func sleepSegments(_ type: HKCategoryType, from: Date, to: Date) async throws -> [SleepSegment] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        return try await fetch(type, predicate: predicate, sort: nil).compactMap { sample in
            guard let c = sample as? HKCategorySample else { return nil }
            return SleepSegment(start: c.startDate, end: c.endDate, value: c.value, source: c.sourceRevision.source.name)
        }
    }

    private func activityRings(from: Date, to: Date, calendar: Calendar) async throws -> [(String, [String: RecordValue])] {
        var cal = calendar
        cal.timeZone = calendar.timeZone
        var start = cal.dateComponents([.era, .year, .month, .day], from: from)
        var end = cal.dateComponents([.era, .year, .month, .day], from: to)
        start.calendar = cal
        end.calendar = cal
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: summaries ?? []) }
            }
            store.execute(q)
        }
        return summaries.compactMap { s in
            let dc = s.dateComponents(for: cal)
            guard let y = dc.year, let m = dc.month, let d = dc.day else { return nil }
            var v: [String: RecordValue] = [
                "ringMoveKcal": .double(s.activeEnergyBurned.doubleValue(for: .kilocalorie())),
                "ringExerciseMin": .double(s.appleExerciseTime.doubleValue(for: .minute())),
                "ringStandHours": .double(s.appleStandHours.doubleValue(for: .count())),
            ]
            if s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()) > 0 { v["ringMoveGoalKcal"] = .double(s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())) }
            if let g = s.exerciseTimeGoal { v["ringExerciseGoalMin"] = .double(g.doubleValue(for: .minute())) }
            if let g = s.standHoursGoal { v["ringStandGoalHours"] = .double(g.doubleValue(for: .count())) }
            return (String(format: "%04d-%02d-%02d", y, m, d), v)
        }
    }

    @available(iOS 18.0, *)
    private func moods(from: Date, to: Date, calendar: Calendar) async throws -> [(String, [String: RecordValue])] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let found = try await fetch(HKObjectType.stateOfMindType(), predicate: predicate, sort: nil).compactMap { $0 as? HKStateOfMind }
        var byDay: [String: [Double]] = [:]
        for m in found { byDay[SleepNights.dayKey(m.startDate, calendar: calendar), default: []].append(m.valence) }
        var out: [(String, [String: RecordValue])] = []
        for (day, values) in byDay {
            let mean = values.reduce(0, +) / Double(values.count)
            out.append((day, ["moodValenceAvg": RecordValue.double(mean), "moodEntries": RecordValue.int(Int64(values.count))]))
        }
        return out
    }

    // MARK: Background delivery

    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        let type = HKObjectType.workoutType()
        let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            if error != nil {
                completion()
                return
            }
            onChange { completion() }
        }
        store.execute(q)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    // MARK: Helpers

    private func fetch(_ type: HKSampleType, predicate: NSPredicate?, sort: NSSortDescriptor?, limit: Int = HKObjectQueryNoLimit) async throws -> [HKSample] {
        await queryGate.acquire()
        defer { queryGate.release() }
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sort.map { [$0] }) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            nextStore().execute(q)
        }
    }

    /// Unsorted on purpose: asking HealthKit to sort made each query 7-13x slower in the simulator benchmark
    /// (healthkit-bench workflow). Points are sorted and de-duplicated by time afterwards (WorkoutRecords).
    private func quantitySamples(_ type: HKQuantityType, predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await fetch(type, predicate: predicate, sort: nil).compactMap { $0 as? HKQuantitySample }
    }
}

enum HealthSourceError: Error { case noResults }

// MARK: Speed test

/// Measurements that show what limits HealthKit read speed on this phone. Read-only; results are numbers only.
extension HealthKitSource {
    private static func timed(_ body: () async -> Void) async -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        await body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
    }

    private func benchRaw(_ store: HKHealthStore, _ type: HKSampleType, _ predicate: NSPredicate?, _ limit: Int, _ sort: NSSortDescriptor?) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sort.map { [$0] }) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(q)
        }
    }

    private func benchAnchored(_ type: HKSampleType, anchor: HKQueryAnchor?, limit: Int) async throws -> ([HKSample], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: limit) { _, samples, _, newAnchor, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (samples ?? [], newAnchor)) }
            }
            store.execute(q)
        }
    }

    private func benchSeries(_ sample: HKQuantitySample, _ type: HKQuantityType) async throws -> Int {
        try await withCheckedThrowingContinuation { cont in
            var n = 0
            let q = HKQuantitySeriesSampleQuery(quantityType: type, predicate: HKQuery.predicateForObject(with: sample.uuid)) { _, quantity, _, _, done, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if quantity != nil { n += 1 }
                if done { cont.resume(returning: n) }
            }
            store.execute(q)
        }
    }

    /// Heart rate of each workout (association query), `width` at a time over `stores`, stopping after `cap` seconds.
    private func benchParallel(_ ws: [HKWorkout], stores: [HKHealthStore], width: Int, sorted: Bool, cap: Double) async -> (seconds: Double, workouts: Int, samples: Int) {
        let hr = HKQuantityType(.heartRate)
        let asc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        var samples = 0
        var workouts = 0
        let started = Date()
        let seconds = await Self.timed {
            await withTaskGroup(of: Int.self) { group in
                var next = 0
                func add() {
                    guard next < ws.count, Date().timeIntervalSince(started) < cap else { return }
                    let w = ws[next]
                    let st = stores[next % stores.count]
                    next += 1
                    group.addTask { (try? await self.benchRaw(st, hr, HKQuery.predicateForObjects(from: w), HKObjectQueryNoLimit, sorted ? asc : nil).count) ?? 0 }
                }
                for _ in 0 ..< max(1, min(width, ws.count)) { add() }
                while let c = await group.next() {
                    samples += c
                    workouts += 1
                    add()
                }
            }
        }
        return (seconds, workouts, samples)
    }

    func benchmark(onUpdate: @escaping @Sendable (String) -> Void) async {
        var lines: [String] = ["iOS \(ProcessInfo.processInfo.operatingSystemVersionString) · low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off")"]
        func emit(_ s: String) {
            lines.append(s)
            onUpdate(lines.joined(separator: "\n"))
        }
        onUpdate(lines.joined(separator: "\n") + "\nRunning…")
        let hr = HKQuantityType(.heartRate)
        let desc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let workoutType = HKObjectType.workoutType()
        let ws: [HKWorkout]
        do {
            ws = try await benchRaw(store, workoutType, nil, 400, desc).compactMap { $0 as? HKWorkout }
        } catch {
            emit("Could not read workouts: \((error as NSError).domain) \((error as NSError).code). Keep the phone unlocked and try again.")
            return
        }
        guard !ws.isEmpty else {
            emit("No workouts found.")
            return
        }
        let sample = Array(ws.prefix(40))
        func f(_ v: Double) -> String { String(format: "%.1f", v) }

        // 1. Cost of a query that returns almost nothing.
        let t0 = await Self.timed {
            for _ in 0 ..< 30 { _ = try? await self.benchRaw(self.store, workoutType, nil, 1, nil) }
        }
        emit("1 round trip, 1 workout: \(f(t0 / 30 * 1000)) ms")

        // 2. Heart rate per workout, by how it is asked.
        // Warm-up pass (not reported) so the first measured row is not the only one reading from cold storage.
        _ = await benchParallel(sample, stores: readStores, width: 8, sorted: false, cap: 30)
        let a = await benchParallel(sample, stores: [store], width: 1, sorted: true, cap: 15)
        emit("2 one at a time, sorted: \(f(a.seconds / Double(max(a.workouts, 1)) * 1000)) ms per workout, \(f(Double(a.samples) / max(a.seconds, 0.001))) samples/s (\(a.workouts) workouts, \(a.samples) samples)")
        let b = await benchParallel(sample, stores: [store], width: 1, sorted: false, cap: 15)
        emit("3 one at a time, unsorted: \(f(b.seconds / Double(max(b.workouts, 1)) * 1000)) ms per workout, \(f(Double(b.samples) / max(b.seconds, 0.001))) samples/s")
        let a2 = await benchParallel(sample, stores: [store], width: 1, sorted: true, cap: 15)
        emit("3b sorted again: \(f(a2.seconds / Double(max(a2.workouts, 1)) * 1000)) ms per workout")
        let c = await benchParallel(sample, stores: [store], width: 8, sorted: true, cap: 15)
        emit("4 8 at once, 1 connection: \(f(Double(c.workouts) / max(c.seconds, 0.001))) workouts/s, \(f(Double(c.samples) / max(c.seconds, 0.001))) samples/s")
        let d = await benchParallel(sample, stores: readStores, width: 8, sorted: true, cap: 15)
        emit("5 8 at once, 4 connections: \(f(Double(d.workouts) / max(d.seconds, 0.001))) workouts/s, \(f(Double(d.samples) / max(d.seconds, 0.001))) samples/s")
        let e = await benchParallel(sample, stores: readStores, width: 32, sorted: true, cap: 15)
        emit("6 32 at once, 4 connections: \(f(Double(e.workouts) / max(e.seconds, 0.001))) workouts/s, \(f(Double(e.samples) / max(e.seconds, 0.001))) samples/s")

        // 3. Does a time-window query return the same heart rate as the workout association?
        var same = 0, assoc = 0, window = 0, checkedN = 0
        for w in sample.prefix(10) {
            let asc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            guard let x = try? await benchRaw(store, hr, HKQuery.predicateForObjects(from: w), HKObjectQueryNoLimit, asc),
                  let y = try? await benchRaw(store, hr, HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: []), HKObjectQueryNoLimit, asc) else { continue }
            checkedN += 1
            assoc += x.count
            window += y.count
            if Set(x.map(\.uuid)) == Set(y.map(\.uuid)) { same += 1 }
        }
        emit("7 time window vs association (\(checkedN) workouts): identical in \(same), association \(assoc) samples, window \(window) samples")

        // 4. Whole-history scan of heart rate, oldest first (capped at 20 s each). Later rows may be faster because the first warmed caches.
        var picks: [HKQuantitySample] = []
        for limit in [1_000, 10_000, 50_000] {
            var anchor: HKQueryAnchor?
            var total = 0, seriesCount = 0, pages = 0
            let started = Date()
            let secs = await Self.timed {
                while Date().timeIntervalSince(started) < 20 {
                    guard let (page, next) = try? await self.benchAnchored(hr, anchor: anchor, limit: limit) else { break }
                    pages += 1
                    total += page.count
                    anchor = next
                    for case let s as HKQuantitySample in page where s.count > 1 {
                        seriesCount += 1
                        if picks.count < 10 { picks.append(s) }
                    }
                    if page.count < limit { break }
                }
            }
            emit("8 all heart rate in pages of \(limit): \(f(Double(total) / max(secs, 0.001))) samples/s (\(total) samples in \(f(secs)) s, \(pages) pages, \(seriesCount) are series)")
        }

        // 5. Expanding series samples into individual readings.
        if picks.isEmpty {
            emit("9 series readings: none found")
        } else {
            var points = 0
            let secs = await Self.timed {
                for s in picks { points += (try? await self.benchSeries(s, hr)) ?? 0 }
            }
            emit("9 series readings: \(f(Double(points) / max(secs, 0.001))) points/s (\(points) points from \(picks.count) samples in \(f(secs)) s)")
        }

        // 6. GPS routes.
        var routePoints = 0, routes = 0
        let routeSecs = await Self.timed {
            for w in sample where routes < 10 {
                guard let found = try? await self.benchRaw(self.store, HKSeriesType.workoutRoute(), HKQuery.predicateForObjects(from: w), HKObjectQueryNoLimit, nil) else { continue }
                for case let route as HKWorkoutRoute in found {
                    routes += 1
                    routePoints += (try? await self.locations(of: route))?.count ?? 0
                }
            }
        }
        emit("10 GPS routes: \(routes == 0 ? "none found" : "\(f(Double(routePoints) / max(routeSecs, 0.001))) points/s (\(routePoints) points from \(routes) routes in \(f(routeSecs)) s)")")
        emit("Done.")
    }
}
