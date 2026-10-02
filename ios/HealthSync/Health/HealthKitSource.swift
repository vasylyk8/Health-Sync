import CoreLocation
import CryptoKit
import Foundation
import HealthKit
import WorkoutKit

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
    /// Separate lane for GPS route points, off for now: the speed test compares it with the shared
    /// query gate on real data (row E) before the sync uses it.
    private let routeGate = ReadGate(limit: 8)
    var routesShareQueryGate = true
    func setRouteConcurrency(_ n: Int) { routeGate.setLimit(n) }
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
        try await requestAuthorization(scope: scope, categories: ["core"])
    }

    func requestAuthorization(scope: SyncScope, categories: Set<String>) async throws {
        let types = HealthTypes.readPermissions(for: scope, categories: categories.union(["core"]))
        do {
            try await store.requestAuthorization(toShare: [], read: types)
        if categories.contains("medications") { await requestMedicationAuthorization() }
        } catch let error as NSError where error.domain == HKErrorDomain && error.code == HKError.Code.errorInvalidArgument.rawValue
                    && !error.localizedDescription.localizedCaseInsensitiveContains("source") {
            // (A "failed to look up source" error is about the app itself, not a type: nothing to skip.)
            // iOS rejects the whole request if it no longer accepts one type (e.g. after an iOS update).
            // Find those types without showing anything (a status check fails the same way) and ask for the rest.
            var accepted = Set<HKObjectType>()
            var rejected: [String] = []
            for type in types {
                do {
                    _ = try await store.statusForAuthorizationRequest(toShare: [], read: [type])
                    accepted.insert(type)
                } catch {
                    rejected.append(type.identifier)
                }
            }
            rejectedPermissionTypes = rejected.sorted()
            guard !rejected.isEmpty, !accepted.isEmpty else { throw error }
            try await store.requestAuthorization(toShare: [], read: accepted)
        }
    }

    /// Types iOS refused to ask permission for at the last request (identifiers only), for diagnostics.
    private(set) var rejectedPermissionTypes: [String] = []

    // MARK: Workout summaries

    func workouts(from: Date, to: Date) async throws -> [Record] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples = try await fetch(HKObjectType.workoutType(), predicate: predicate, sort: sort)
        return await withPlans(samples.compactMap { $0 as? HKWorkout })
    }

    /// Summary records of these workouts, each with the plan it was run from (when it has one).
    private func withPlans(_ workouts: [HKWorkout]) async -> [Record] {
        var records = workouts.map(workout)
        guard #available(iOS 17.0, *), !records.isEmpty else { return records }
        // Read concurrently (a few at a time); each answer goes to its own slot, so the order stays the same.
        let plans: [Int: RecordValue] = await SyncTiming.shared.measure("hk.plans") {
            await withTaskGroup(of: (Int, RecordValue?).self) { group in
                var next = 0
                var found: [Int: RecordValue] = [:]
                func addNext() {
                    guard next < workouts.count else { return }
                    let i = next
                    next += 1
                    group.addTask { (i, await Self.plan(of: workouts[i])) }
                }
                for _ in 0..<8 { addNext() }
                while let (i, plan) = await group.next() {
                    if let plan { found[i] = plan }
                    addNext()
                }
                return found
            }
        }
        for (i, plan) in plans {
            records[i]["plan"] = plan
            // Which apps' workouts carry a plan (counted for the speed test and diagnostics; no health data).
            SyncTiming.shared.count("plans.found")
            SyncTiming.shared.count("plans.\(workouts[i].sourceRevision.source.bundleIdentifier)")
        }
        return records
    }

    /// The plan a workout was run from (scheduled in Apple's Workout app by any app), as a short summary: its id, kind
    /// (goal, pacer, custom, swimBikeRun) and a compact description of its steps.
    @available(iOS 17.0, *)
    private static func plan(of w: HKWorkout) async -> RecordValue? {
        guard let plan = try? await w.workoutPlan else { return nil }
        let kind = Mirror(reflecting: plan.workout).children.first?.label ?? "unknown"
        return .object(["id": .string(plan.id.uuidString), "kind": .string(kind), "desc": .string(String(String(describing: plan.workout).prefix(800)))])
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
        var records: [Record]
        if let event = type.event {
            records = eventRecords(samples, event: event)
            // Dense series carry no ids, so a deleted reading cannot be matched on the server.
            if !event.dense { records.append(contentsOf: deleted.map { ["k": "d", "id": .string($0.uuid.uuidString)] }) }
        } else {
            records = await withPlans(samples.compactMap { $0 as? HKWorkout })
            records.append(contentsOf: deleted.map { ["k": "d", "id": .string($0.uuid.uuidString)] })
        }
        let anchorData = newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return AnchoredPage(records: records, newAnchor: anchorData, objectCount: samples.count + deleted.count)
    }

    func workoutIndex() async throws -> [WorkoutRef] {
        // Unsorted and sorted here: asking HealthKit to sort is much slower (speed test row B1).
        let samples = try await fetch(HKObjectType.workoutType(), predicate: nil, sort: nil)
            .sorted { $0.startDate != $1.startDate ? $0.startDate > $1.startDate : $0.uuid.uuidString < $1.uuid.uuidString }
        let workouts = samples.compactMap { $0 as? HKWorkout }
        cacheLock.withLock { workoutCache = Dictionary(workouts.map { ($0.uuid.uuidString, $0) }, uniquingKeysWith: { first, _ in first }) }
        return samples.map { WorkoutRef(id: $0.uuid.uuidString, start: $0.startDate) }
    }

    /// Apple's own zones for this workout (the boundaries Apple used and the time spent in each zone), per quantity such as
    /// heart rate. Needs the iOS 27 SDK to compile and iOS 27 to run, so it is behind the `IOS27_SDK` compilation flag:
    /// once the build machine has Xcode 27, add `SWIFT_ACTIVE_COMPILATION_CONDITIONS: IOS27_SDK` to the app target in project.yml.
    /// (The CI Xcode today has a new enough Swift but an older SDK, so a compiler-version check is not enough.)
    private func appleZones(_ w: HKWorkout) -> RecordValue? {
        #if IOS27_SDK
        guard #available(iOS 27.0, *), let groups = w.zoneGroupsByType, !groups.isEmpty else { return nil }
        var out: [String: RecordValue] = [:]
        for (type, group) in groups {
            guard let spec = quantitiesById[type.identifier] else { continue }
            let source: String
            switch group.configuration.source {
            case .system: source = "system"
            case .user: source = "user"
            case .app: source = "app"
            @unknown default: source = "unknown"
            }
            let zones: [RecordValue] = group.zoneDurations.map { d in
                var o: [String: RecordValue] = ["i": .int(Int64(d.zone.index)), "sec": .double(d.duration)]
                if let lo = d.zone.minimum { o["min"] = .double(lo.doubleValue(for: spec.unit)) }
                if let hi = d.zone.maximum { o["max"] = .double(hi.doubleValue(for: spec.unit)) }
                return .object(o)
            }
            out[spec.name] = .object(["src": .string(source), "u": .string(spec.unitLabel), "z": .array(zones)])
        }
        return out.isEmpty ? nil : .object(out)
        #else
        return nil
        #endif
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
        if let zones = appleZones(w) { r["zones"] = zones }
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
            r["ev"] = .array(events.prefix(2_000).map { e -> RecordValue in
                var o: [String: RecordValue] = ["t": e.dateInterval.start.ms, "type": .int(Int64(e.type.rawValue)), "dur": .double(e.dateInterval.duration)]
                // Laps and segments carry their stroke style, lap length and similar details.
                if case .object(let md)? = metadata(e.metadata, maxBytes: 400) { o["md"] = .object(md) }
                return .object(o)
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

    /// What one workout's raw data consists of, as read from Apple Health (before it is turned into records).
    struct WorkoutParts {
        var series: [(name: String, unit: String?, points: [SeriesPoint])]
        var route: [RoutePoint]
    }

    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? {
        guard let parts = try await workoutParts(id: id) else { return nil }
        let records = Self.records(id: id, gen: gen, parts: parts)
        SyncTiming.shared.count("hk.workouts")
        return records
    }

    /// The `ws` / `wd` records of a workout's raw data.
    static func records(id: String, gen: Int64, parts: WorkoutParts, format: WorkoutRecords.Format = .compact,
                        routePlans: [String: CompactColumns.Plan] = WorkoutRecords.routePlans, includeRoute: Bool = true) -> [Record] {
        var records: [Record] = []
        var expected: [String: Int] = [:]
        for s in parts.series where !s.points.isEmpty {
            let built = WorkoutRecords.series(wid: id, name: s.name, gen: gen, unit: s.unit, points: s.points, format: format)
            guard built.count > 0 else { continue }
            records.append(contentsOf: built.records)
            expected[s.name] = built.count
        }
        if includeRoute, !parts.route.isEmpty {
            let built = WorkoutRecords.route(wid: id, gen: gen, points: parts.route, format: format, plans: routePlans)
            if built.count > 0 {
                records.append(contentsOf: built.records)
                expected["route"] = built.count
            }
        }
        records.append(WorkoutRecords.mark(wid: id, gen: gen, expected: expected))
        return records
    }

    func workoutParts(id: String) async throws -> WorkoutParts? {
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

        // Types Apple recorded for this workout. Heart rate is always tried, because workouts imported
        // from other apps carry no Apple statistics but often have heart rate samples.
        var wanted = Set(w.allStatistics.keys.map(\.identifier))
        wanted.insert(HealthTypes.quantityPrefix + "HeartRate")
        let specs = scope.workoutQuantities.filter { wanted.contains($0.id) && $0.stream }

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
        return WorkoutParts(series: specs.enumerated().map { (name: $0.element.name, unit: $0.element.unitLabel, points: seriesByIndex[$0.offset] ?? []) }, route: route)
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
        let gate = routesShareQueryGate ? queryGate : routeGate
        await gate.acquire()
        defer { gate.release() }
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
        try await dailyRecords(scope.dailyMetrics.filter { $0.category == "core" }, from: from, to: to)
    }

    func dailyContextBatches(from: Date, to: Date, categories: Set<String>) async throws -> [DailyBatch] {
        var out: [DailyBatch] = []
        for category in categories.union(["core"]).sorted() {
            let metrics = scope.dailyMetrics.filter { $0.category == category }
            guard !metrics.isEmpty else { continue }
            out.append(DailyBatch(typeId: HealthTypes.dailyBatchType(category), category: category, records: try await dailyRecords(metrics, from: from, to: to)))
        }
        return out
    }

    private func dailyRecords(_ metrics: [DailyMetric], from: Date, to: Date) async throws -> [Record] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
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
            for (day, value) in try await dailyStatistics(type, unit: unit, agg: agg, scale: scale, from: start, to: to, calendar: cal, appleOnly: metric.appleOnly) {
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

    private func dailyStatistics(_ type: HKQuantityType, unit: HKUnit, agg: DailyAgg, scale: Double, from: Date, to: Date, calendar: Calendar, appleOnly: Bool = false) async throws -> [(String, Double)] {
        let options: HKStatisticsOptions
        switch agg {
        case .sum: options = .cumulativeSum
        case .avg: options = .discreteAverage
        case .min: options = .discreteMin
        case .max: options = .discreteMax
        case .last: options = .mostRecent
        }
        var predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        if appleOnly, let sources = await appleSourcesPredicate(type) { predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, sources]) }
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
        case .count:
            var counts: [String: Int] = [:]
            for s in found { counts[SleepNights.dayKey(s.startDate, calendar: calendar), default: 0] += 1 }
            for (day, n) in counts { out.append((day, RecordValue.int(Int64(n)))) }
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

    // MARK: Hourly series, events, profile

    private let sourceLock = NSLock()
    private var appleSourceCache: [String: NSPredicate?] = [:]

    /// Predicate matching only samples written by Apple's own sources (Apple Watch, iPhone) for `type`, or nil when
    /// there is no such source (then nothing is filtered). Some apps write their own resting heart rate or HRV.
    private func appleSourcesPredicate(_ type: HKQuantityType) async -> NSPredicate? {
        if let cached = sourceLock.withLock({ appleSourceCache[type.identifier] }) { return cached }
        let sources: Set<HKSource> = await withCheckedContinuation { cont in
            let q = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, _ in cont.resume(returning: sources ?? []) }
            store.execute(q)
        }
        let apple = sources.filter { $0.bundleIdentifier.hasPrefix("com.apple.health") }
        let predicate: NSPredicate? = apple.isEmpty ? nil : HKQuery.predicateForObjects(from: apple)
        sourceLock.withLock { appleSourceCache[type.identifier] = .some(predicate) }
        return predicate
    }

    func hourlySeries(from: Date, to: Date) async throws -> [Record] {
        var records: [Record] = []
        var firstError: Error?
        for metric in scope.hourly {
            do {
                let buckets = try await SyncTiming.shared.measure("hk.hourly") { try await self.hourlyBuckets(metric, from: from, to: to) }
                records.append(contentsOf: SeriesRecords.hourlyChunks(name: metric.name, unit: metric.unitLabel, hours: buckets))
            } catch {
                // One series failing (no permission, a type this iOS lacks) must not lose the others.
                firstError = firstError ?? error
            }
        }
        if records.isEmpty, let firstError { throw firstError }
        return records
    }

    private func hourlyBuckets(_ metric: HourlyMetric, from: Date, to: Date) async throws -> [HourBucket] {
        var options: HKStatisticsOptions = []
        if metric.cumulative {
            options = .cumulativeSum
        } else {
            if metric.cols.contains("avg") { options.insert(.discreteAverage) }
            if metric.cols.contains("min") { options.insert(.discreteMin) }
            if metric.cols.contains("max") { options.insert(.discreteMax) }
        }
        var predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        if metric.appleOnly, let sources = await appleSourcesPredicate(metric.type) { predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, sources]) }
        let anchor = Calendar.current.dateInterval(of: .hour, for: from)?.start ?? from
        await queryGate.acquire()
        defer { queryGate.release() }
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: metric.type, quantitySamplePredicate: predicate, options: options, anchorDate: anchor, intervalComponents: DateComponents(hour: 1))
            q.initialResultsHandler = { _, collection, error in
                if let collection { cont.resume(returning: collection) } else { cont.resume(throwing: error ?? HealthSourceError.noResults) }
            }
            store.execute(q)
        }
        var out: [HourBucket] = []
        let unit = metric.unit
        collection.enumerateStatistics(from: anchor, to: to) { stats, _ in
            func value(_ q: HKQuantity?) -> Double? { q.map { $0.doubleValue(for: unit) }.flatMap { $0.isFinite ? $0 : nil } }
            let bucket: HourBucket
            if metric.cumulative {
                bucket = HourBucket(t: stats.startDate.msValue, v: value(stats.sumQuantity()), lo: nil, hi: nil)
            } else {
                bucket = HourBucket(t: stats.startDate.msValue, v: value(stats.averageQuantity()), lo: value(stats.minimumQuantity()), hi: value(stats.maximumQuantity()))
            }
            if bucket.v != nil || bucket.lo != nil || bucket.hi != nil { out.append(bucket) }
        }
        return out
    }

    /// Turns the samples of one event type into `ev` chunks, one group per writing app.
    private func eventRecords(_ samples: [HKSample], event: EventType) -> [Record] {
        let scale: Double = event.unitLabel == "%" ? 100 : 1
        var groups: [String: (source: HKSource, points: [EventPoint])] = [:]
        for sample in samples {
            var point = EventPoint(start: sample.startDate.msValue, end: sample.endDate.msValue)
            switch event.kind {
            case .quantity:
                guard let q = sample as? HKQuantitySample, let unit = event.unit else { continue }
                let v = q.quantity.doubleValue(for: unit) * scale
                guard v.isFinite else { continue }
                point.v = v
            case .category:
                guard let c = sample as? HKCategorySample else { continue }
                point.c = c.value
            default:
                continue
            }
            if !event.dense {
                point.id = sample.uuid.uuidString
                var md = sample.metadata ?? [:]
                for key in SeriesRecords.ignoredMetadataKeys { md[key] = nil }
                if case .object(let o)? = metadata(md, maxBytes: 1_000), !o.isEmpty { point.meta = o }
            }
            let key = sample.sourceRevision.source.bundleIdentifier + "|" + sample.sourceRevision.source.name
            var group = groups[key] ?? (sample.sourceRevision.source, [])
            group.points.append(point)
            groups[key] = group
        }
        var out: [Record] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            out.append(contentsOf: SeriesRecords.eventChunks(type: event.name, unit: event.unitLabel, source: group.source.name, bundle: group.source.bundleIdentifier, points: group.points))
        }
        return out
    }

    /// Medications use per-object authorization: the user picks which ones to share on Apple's own sheet.
    private func requestMedicationAuthorization() async {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            try? await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
        }
        #endif
    }

    func medicationRecords() async throws -> [Record] {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *) else { return [] }
        let meds = try await HKUserAnnotatedMedicationQueryDescriptor(predicate: nil, limit: nil).result(for: store)
        guard !meds.isEmpty else { return [] }
        var ids: [RecordValue] = []
        var metas: [RecordValue] = []
        for m in meds {
            // A stable short id from Apple's concept identifier (which may contain characters the batch format does not allow).
            let digest = SHA256.hash(data: Data(String(describing: m.medication.identifier).utf8))
            ids.append(.string("med-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()))
            var meta: [String: RecordValue] = ["name": .string(String(m.medication.displayText.prefix(200))), "archived": .bool(m.isArchived), "scheduled": .bool(m.hasSchedule)]
            if let nick = m.nickname, !nick.isEmpty { meta["nickname"] = .string(String(nick.prefix(100))) }
            metas.append(.object(meta))
        }
        let now = Date().ms
        return [["k": "ev", "ty": "Medication", "s": .array(Array(repeating: now, count: meds.count)), "ids": .array(ids), "meta": .array(metas)]]
        #else
        return []
        #endif
    }

    func profileRecords() async throws -> [Record] {
        var meta: [String: RecordValue] = [:]
        if let dob = try? store.dateOfBirthComponents(), let y = dob.year, let m = dob.month, let d = dob.day {
            meta["dob"] = .string(String(format: "%04d-%02d-%02d", y, m, d))
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: meta["sex"] = "female"
            case .male: meta["sex"] = "male"
            case .other: meta["sex"] = "other"
            default: break
            }
        }
        if let wheelchair = try? store.wheelchairUse().wheelchairUse, wheelchair != .notSet { meta["wheelchair"] = .bool(wheelchair == .yes) }
        if let mode = try? store.activityMoveMode().activityMoveMode { meta["moveMode"] = mode == .appleMoveTime ? "appleMoveTime" : "activeEnergy" }
        guard !meta.isEmpty else { return [] }
        return [["k": "ev", "ty": "Profile", "s": .array([Date().ms]), "ids": .array(["profile"]), "meta": .array([.object(meta)])]]
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

    private var observedTypes = Set<String>()

    /// Heart rate and steps (hourly series) and every event type of the switched-on categories wake the app in the
    /// background too, so new readings (a CGM, a logged meal) reach the server without opening the app. iOS decides
    /// when and how often (at most about hourly for most types), and only while the phone is unlocked.
    func observeOtherData(categories: Set<String>, onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        var types: [HKSampleType] = scope.hourly.map { $0.type }
        for e in scope.events where categories.contains(e.category) { if let t = e.sampleType { types.append(t) } }
        for type in types {
            let fresh = sourceLock.withLock { observedTypes.insert(type.identifier).inserted }
            guard fresh else { continue }
            let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if error != nil {
                    completion()
                    return
                }
                onChange { completion() }
            }
            store.execute(q)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
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


    /// Runs `jobs` with at most `width` at a time and returns the wall time in seconds.
    private static func parallel(_ jobs: [@Sendable () async -> Void], width: Int) async -> Double {
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

    /// CPU seconds used by this process so far (all threads).
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }

    private static func heat() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    /// App that recorded a workout: "Apple" for the Watch, iPhone and Health app, otherwise its bundle id (never a person's name).
    private static func sourceLabel(_ s: HKSource) -> String {
        s.bundleIdentifier.lowercased().hasPrefix("com.apple.health") ? "Apple" : s.bundleIdentifier
    }

    /// Types the app reads for a workout (as in `workoutDetail`).
    private func specs(for w: HKWorkout) -> [WorkoutQuantity] {
        var wanted = Set(w.allStatistics.keys.map(\.identifier))
        wanted.insert(HealthTypes.quantityPrefix + "HeartRate")
        return scope.workoutQuantities.filter { wanted.contains($0.id) && $0.stream }
    }

    private func windowPredicate(_ w: HKWorkout, strict: Bool) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: strict ? [.strictStartDate, .strictEndDate] : []),
            HKQuery.predicateForObjects(from: [w.sourceRevision.source]),
        ])
    }

    /// The app's whole read of `ws` (`width` workouts at once, as the sync does); workouts per minute.
    private func wholeRead(_ ws: [HKWorkout], width: Int) async -> Double {
        let jobs: [@Sendable () async -> Void] = ws.map { w in { _ = try? await self.workoutDetail(id: w.uuid.uuidString, gen: 1) } }
        let secs = await Self.parallel(jobs, width: width)
        return Double(ws.count) / max(secs, 0.001) * 60
    }

    /// Measurements that answer the open questions about Step 4 on the user's own data. Read-only; numbers only.
    /// Rows: A device, B what the workouts look like, C cost per workout by age, D time window vs association,
    /// E route lane on/off, F read settings, G daily history, H uploads of the last sync, I projection.
    func benchmark(onUpdate: @escaping @Sendable (String) -> Void) async {
        var lines: [String] = []
        func emit(_ s: String) {
            lines.append(s)
            onUpdate(lines.joined(separator: "\n"))
        }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func n0(_ v: Double) -> String { String(format: "%.0f", v) }
        let info = ProcessInfo.processInfo

        // A. Device.
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        emit("A \(machine) · iOS \(info.operatingSystemVersionString) · \(info.activeProcessorCount) cores · \(n0(Double(info.physicalMemory) / 1_073_741_824)) GB · heat \(Self.heat()) · low power \(info.isLowPowerModeEnabled ? "ON" : "off")")
        onUpdate(lines.joined(separator: "\n") + "\nRunning… (about 4 minutes, keep the app open)")

        // B. What the workouts look like.
        let desc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        var all: [HKWorkout] = []
        var listError: Error?
        let tList = await Self.timed {
            do { all = try await self.benchRaw(self.store, HKObjectType.workoutType(), nil, HKObjectQueryNoLimit, desc).compactMap { $0 as? HKWorkout } } catch { listError = error }
        }
        if let listError {
            emit("Could not read workouts: \((listError as NSError).domain) \((listError as NSError).code). Keep the phone unlocked and try again.")
            return
        }
        guard !all.isEmpty else {
            emit("No workouts found.")
            return
        }
        let now = Date()
        let year = 31_557_600.0
        let buckets: [(label: String, lo: Double, hi: Double)] = [("<1y", 0, 1), ("1-3y", 1, 3), ("3-6y", 3, 6), ("6y+", 6, 1000)]
        func bucketOf(_ d: Date) -> Int {
            let age = now.timeIntervalSince(d) / year
            return buckets.firstIndex { age >= $0.lo && age < $0.hi } ?? buckets.count - 1
        }
        var byBucket = [[HKWorkout]](repeating: [], count: buckets.count)
        for w in all { byBucket[bucketOf(w.startDate)].append(w) }
        let hours = all.reduce(0) { $0 + $1.duration } / 3600
        let withStats = all.filter { !$0.allStatistics.isEmpty }.count
        let typesAvg = Double(all.reduce(0) { $0 + specs(for: $1).count }) / Double(all.count)
        var unsortedCount = 0
        let tUnsorted = await Self.timed { unsortedCount = (try? await self.benchRaw(self.store, HKObjectType.workoutType(), nil, HKObjectQueryNoLimit, nil))?.count ?? 0 }
        let desc2 = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let tSorted2 = await Self.timed { _ = try? await self.benchRaw(self.store, HKObjectType.workoutType(), nil, HKObjectQueryNoLimit, desc2) }
        let tUnsorted2 = await Self.timed { _ = try? await self.benchRaw(self.store, HKObjectType.workoutType(), nil, HKObjectQueryNoLimit, nil) }
        emit("B0 listing all workouts (start of every sync): sorted by Apple Health \(f(tList))/\(f(tSorted2)) s, unsorted \(f(tUnsorted))/\(f(tUnsorted2)) s (\(unsortedCount))")
        emit("B1 \(all.count) workouts listed in \(f(tList)) s · \(n0(hours)) h total · by age " + buckets.indices.map { "\(buckets[$0].label) \(byBucket[$0].count)" }.joined(separator: ", ") + " · \(withStats) with Apple statistics · \(f(typesAvg)) types to read per workout")
        var bySource: [String: Int] = [:]
        for w in all { bySource[Self.sourceLabel(w.sourceRevision.source), default: 0] += 1 }
        var byActivity: [UInt: Int] = [:]
        for w in all { byActivity[w.workoutActivityType.rawValue, default: 0] += 1 }
        emit("B2 \(bySource.count) apps: " + bySource.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
             + " · activity types (id count): " + byActivity.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        var routeList: [HKSample] = []
        let tRoutes = await Self.timed { routeList = (try? await self.benchRaw(self.store, HKSeriesType.workoutRoute(), nil, HKObjectQueryNoLimit, nil)) ?? [] }
        var routesByBucket = [Int](repeating: 0, count: buckets.count)
        for r in routeList { routesByBucket[bucketOf(r.startDate)] += 1 }
        emit("B3 \(routeList.count) GPS routes listed in \(f(tRoutes)) s · by age " + buckets.indices.map { "\(buckets[$0].label) \(routesByBucket[$0])" }.joined(separator: ", "))

        // Up to 32 workouts spread evenly through each age group.
        let picks: [[HKWorkout]] = byBucket.map { ws in
            guard ws.count > 32 else { return ws }
            return (0 ..< 32).map { ws[$0 * ws.count / 32] }
        }

        // C. Cost per workout by age. C1 is the app's whole read (cold, 16 at once, like the sync) plus
        // encoding; C2 splits one workout at a time into its parts; C3 is what was found.
        var rates = [Double?](repeating: nil, count: buckets.count)
        for (b, ws) in picks.enumerated() where !ws.isEmpty {
            let cpu0 = Self.cpuSeconds()
            let box = BenchBox()
            let jobs: [@Sendable () async -> Void] = ws.map { w in {
                guard let records = try? await self.workoutDetail(id: w.uuid.uuidString, gen: 1) else { return }
                let t0 = DispatchTime.now().uptimeNanoseconds
                let encoded = (try? BatchWriter.encodeLines(records)) ?? []
                var joined = Data()
                for line in encoded {
                    joined.append(line)
                    joined.append(0x0a)
                }
                let gz = Gzip.compress(joined)
                box.add(records: records.count, raw: joined.count, gz: gz.count, encodeMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            } }
            let secs = await Self.parallel(jobs, width: 16)
            let cores = (Self.cpuSeconds() - cpu0) / max(secs, 0.001)
            let rate = Double(ws.count) / max(secs, 0.001) * 60
            rates[b] = rate
            let k = Double(max(box.workouts, 1))
            emit("C1 \(buckets[b].label) (\(ws.count)): \(n0(rate)) workouts/min · app cpu \(String(format: "%.2f", cores)) cores · per workout \(n0(Double(box.records) / k)) records, \(n0(Double(box.raw) / k / 1000)) KB → \(n0(Double(box.gz) / k / 1000)) KB gzip, encode+gzip \(f(box.encodeMs / k)) ms · heat \(Self.heat())")

            var qMs = 0.0, seriesMs = 0.0, fallbackMs = 0.0, lookupMs = 0.0, pointsMs = 0.0
            var types = 0, samples = 0, series = 0, seriesPoints = 0, fallbackUsed = 0, routes = 0, routePoints = 0
            var perType: [String: Double] = [:]
            for w in ws {
                for q in specs(for: w) {
                    types += 1
                    var found: [HKQuantitySample] = []
                    let tq = await Self.timed { found = (try? await self.quantitySamples(q.type, predicate: HKQuery.predicateForObjects(from: w))) ?? [] }
                    qMs += tq * 1000
                    perType[q.name, default: 0] += tq * 1000
                    if found.isEmpty && q.name == "HeartRate" {
                        var extra: [HKQuantitySample] = []
                        let tf = await Self.timed { extra = (try? await self.quantitySamples(q.type, predicate: self.windowPredicate(w, strict: false))) ?? [] }
                        fallbackMs += tf * 1000
                        if !extra.isEmpty { fallbackUsed += 1 }
                        found = extra
                    }
                    samples += found.count
                    let multi = found.filter { !q.cumulative && $0.count > 1 }
                    series += multi.count
                    let ts = await Self.timed {
                        for s in multi {
                            let pts = (try? await self.expandSeries(s, q))?.count ?? 0
                            seriesPoints += pts
                        }
                    }
                    seriesMs += ts * 1000
                }
                var rs: [HKWorkoutRoute] = []
                let tl = await Self.timed { rs = ((try? await self.fetch(HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: w), sort: nil)) ?? []).compactMap { $0 as? HKWorkoutRoute } }
                lookupMs += tl * 1000
                routes += rs.count
                let tp = await Self.timed {
                    for r in rs {
                        let pts = (try? await self.locations(of: r))?.count ?? 0
                        routePoints += pts
                    }
                }
                pointsMs += tp * 1000
            }
            let c = Double(ws.count)
            emit("C2 \(buckets[b].label) ms per workout, one at a time: quantity \(n0(qMs / c)) (\(f(Double(types) / c)) queries), series \(n0(seriesMs / c)), HR fallback \(n0(fallbackMs / c)), route lookup \(n0(lookupMs / c)), route points \(n0(pointsMs / c)) · slowest types " + perType.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \(n0($0.value / c))" }.joined(separator: ", "))
            emit("C3 \(buckets[b].label) per workout: \(n0(Double(samples) / c)) samples, \(f(Double(series) / c)) series → \(n0(Double(seriesPoints) / c)) points, \(f(Double(routes) / c)) routes → \(n0(Double(routePoints) / c)) points · HR only by time window in \(fallbackUsed)/\(ws.count)")
        }

        // J. Upload size of the raw data by format, on the same workouts, and a check of the encoding on real data.
        var projected = [Double](repeating: 0, count: 5)
        var rawColumns: [String: (raw: Int, all: Int)] = [:]
        var exactChecked = 0, exactDiffering = 0
        var routeErr: [String: Double] = [:]
        func gzBytes(_ records: [Record]) -> Int {
            var body = Data()
            for line in (try? BatchWriter.encodeLines(records)) ?? [] {
                body.append(line)
                body.append(0x0a)
            }
            return Gzip.compress(body).count
        }
        for (b, ws) in picks.enumerated() where !ws.isEmpty {
            var sizes = [Int](repeating: 0, count: 5)
            var done = 0
            for w in ws.prefix(24) {
                let id = w.uuid.uuidString
                guard let parts = try? await workoutParts(id: id) else { continue }
                done += 1
                let variants: [[Record]] = [
                    Self.records(id: id, gen: 1, parts: parts, format: .plain),
                    Self.records(id: id, gen: 1, parts: parts),
                    Self.records(id: id, gen: 1, parts: parts, routePlans: WorkoutRecords.fineRoutePlans),
                    Self.records(id: id, gen: 1, parts: parts, includeRoute: false),
                    Self.records(id: id, gen: 1, parts: parts, format: .plain, includeRoute: false),
                ]
                for (k, recs) in variants.enumerated() { sizes[k] += gzBytes(recs) }
                // Does the compact form give back what was read?
                let original = Dictionary(parts.series.map { ($0.name, WorkoutRecords.dedupe($0.points)) }, uniquingKeysWith: { first, _ in first })
                var seen: [String: Int] = [:]
                for r in variants[1] {
                    guard case .string("ws")? = r["k"], case .string(let name)? = r["st"], case .int(let n)? = r["n"] else { continue }
                    let offset = seen[name, default: 0]
                    seen[name] = offset + Int(n)
                    if name == "route" {
                        let pts = WorkoutRecords.thinned(WorkoutRecords.dedupe(parts.route))
                        let slice = Array(pts[offset ..< offset + Int(n)])
                        let fields: [(String, [Double?], Double)] = [
                            ("lat", slice.map { Optional($0.lat) }, 111_195), ("lon", slice.map { Optional($0.lon) }, 111_195 * cos(slice[0].lat * .pi / 180)),
                            ("alt", slice.map(\.alt), 1), ("spd", slice.map(\.spd), 1), ("crs", slice.map(\.crs), 1),
                        ]
                        for (col, values, perUnit) in fields {
                            guard let rec = r[col], let back = CompactColumns.decode(rec, count: Int(n)) else { continue }
                            var worst = 0.0
                            for (x, y) in zip(values, back) { if let x, let y { worst = max(worst, abs(x - y) * perUnit) } else if (x == nil) != (y == nil) { worst = .infinity } }
                            routeErr[col] = max(routeErr[col] ?? 0, worst)
                        }
                    } else if let points = original[name], case let v? = r["v"] {
                        rawColumns[name, default: (0, 0)].all += 1
                        if case .object(let o) = v, o["r"] != nil { rawColumns[name]!.raw += 1 }
                        let slice = Array(points[offset ..< offset + Int(n)])
                        exactChecked += 1
                        // Quantity values are rounded to 3 decimals before encoding: the check allows exactly that.
                        let expectedValues: [Double?] = slice.map { Optional($0.v) }
                        let matches: Bool = {
                            guard let back = CompactColumns.decode(v, count: Int(n)), back.count == expectedValues.count else { return false }
                            return zip(back, expectedValues).allSatisfy { a, b in
                                if let a, let b { return abs(a - b) <= 0.0005 + 1e-9 }
                                return a == nil && b == nil
                            }
                        }()
                        if !matches { exactDiffering += 1 }
                    }
                }
            }
            guard done > 0 else { continue }
            func kb(_ i: Int) -> String { n0(Double(sizes[i]) / Double(done) / 1000) }
            emit("J \(buckets[b].label) per workout, KB gzip: today \(kb(0)) → new \(kb(1)) (finer course/speed/accuracy \(kb(2))) · without the route: today \(kb(4)) → new \(kb(3))")
            for i in 0 ..< 5 { projected[i] += Double(sizes[i]) / Double(done) * Double(byBucket[b].count) / 1_000_000 }
        }
        let raws = rawColumns.sorted { $0.value.all > $1.value.all }.prefix(6).map { "\($0.key) \(n0(Double($0.value.raw) / Double(max($0.value.all, 1)) * 100))%" }
        emit("K projected upload for all \(all.count) workouts: today \(n0(projected[0])) MB → new \(n0(projected[1])) MB (finer precision \(n0(projected[2])) MB) · without routes: today \(n0(projected[4])) MB → new \(n0(projected[3])) MB")
        emit("K2 encoding check on your data: \(exactChecked) quantity chunks, \(exactDiffering) differ from what was read by more than the 0.0005 rounding (must be 0) · route worst error: " + ["lat", "lon", "alt", "spd", "crs"].map { "\($0) \(String(format: "%.2f", routeErr[$0] ?? 0))\($0 == "lat" || $0 == "lon" || $0 == "alt" ? " m" : "")" }.joined(separator: ", ") + " · chunks stored as plain numbers (not a short decimal): " + raws.joined(separator: ", "))

        // D. Time window + same app vs the workout association: exactly the same samples? Faster?
        for (b, ws) in picks.enumerated() where !ws.isEmpty {
            let group = Array(ws.prefix(24))
            var pairs = 0, sameLoose = 0, sameStrict = 0, missingLoose = 0, extraLoose = 0, missingStrict = 0, extraStrict = 0, assocTotal = 0
            for w in group {
                for q in specs(for: w) {
                    guard let a = try? await quantitySamples(q.type, predicate: HKQuery.predicateForObjects(from: w)),
                          let loose = try? await quantitySamples(q.type, predicate: windowPredicate(w, strict: false)),
                          let strict = try? await quantitySamples(q.type, predicate: windowPredicate(w, strict: true)) else { continue }
                    let sa = Set(a.map(\.uuid)), sl = Set(loose.map(\.uuid)), ss = Set(strict.map(\.uuid))
                    pairs += 1
                    assocTotal += sa.count
                    if sa == sl { sameLoose += 1 }
                    if sa == ss { sameStrict += 1 }
                    missingLoose += sa.subtracting(sl).count
                    extraLoose += sl.subtracting(sa).count
                    missingStrict += sa.subtracting(ss).count
                    extraStrict += ss.subtracting(sa).count
                }
            }
            let jobsFor: (Bool) -> [@Sendable () async -> Void] = { window in
                group.flatMap { w in self.specs(for: w).map { q in { @Sendable in
                    _ = try? await self.quantitySamples(q.type, predicate: window ? self.windowPredicate(w, strict: false) : HKQuery.predicateForObjects(from: w))
                } } }
            }
            let tA = await Self.parallel(jobsFor(false), width: 32)
            let tW = await Self.parallel(jobsFor(true), width: 32)
            let tA2 = await Self.parallel(jobsFor(false), width: 32)
            let gc = Double(group.count)
            emit("D \(buckets[b].label) (\(group.count) workouts, \(pairs) type reads, \(assocTotal) samples): window identical \(sameLoose)/\(pairs) (missing \(missingLoose), extra \(extraLoose)), strict window identical \(sameStrict)/\(pairs) (missing \(missingStrict), extra \(extraStrict)) · speed association \(n0(gc / tA * 60))/\(n0(gc / tA2 * 60)) vs window \(n0(gc / tW * 60)) workouts/min")
        }

        // E/F. Read settings on the same 48 newest workouts (read again each time, so later runs are warmer:
        // each setting is measured twice, in A B A B order).
        let fresh = Array(all.prefix(48))
        let savedLimit = queryConcurrency
        var e: [String] = []
        for shared in [false, true, false, true] {
            routesShareQueryGate = shared
            let r = await wholeRead(fresh, width: 24)
            e.append("\(shared ? "off" : "on") \(n0(r))")
        }
        routesShareQueryGate = true
        emit("E route lane (\(fresh.count) newest, 24 at once, workouts/min): " + e.joined(separator: ", "))
        var g: [String] = []
        for limit in [32, 8, 16, 64, 32] {
            setQueryConcurrency(limit)
            let r = await wholeRead(fresh, width: 24)
            g.append("\(limit) \(n0(r))")
        }
        setQueryConcurrency(32)
        var wd: [String] = []
        for width in [4, 24, 64, 24] {
            let r = await wholeRead(fresh, width: width)
            wd.append("\(width) \(n0(r))")
        }
        setQueryConcurrency(savedLimit)
        emit("F queries in flight (24 workouts at once): " + g.joined(separator: ", ") + " · workouts at once (32 queries): " + wd.joined(separator: ", ") + " · heat \(Self.heat())")

        // G. Daily history (runs alongside Step 4).
        var earliest: Date?
        let eSecs = await Self.timed { earliest = try? await self.earliestDailyDate() }
        let years = earliest.map { Date().timeIntervalSince($0) / year } ?? 0
        let oneYear = await Self.timed { _ = try? await self.dailyContext(from: Date().addingTimeInterval(-365 * 86_400), to: Date()) }
        emit("G daily: oldest date \(f(eSecs)) s (\(f(years)) years), one year of daily metrics \(f(oneYear)) s")

        // H. Uploads from the sync that ran before this test (same app session).
        emit("H " + (SyncTiming.shared.uploadSummary() ?? "no uploads yet in this app session (run the test during Step 4 to include them)"))

        // I. Reading time for all workouts at the C1 speeds.
        var minutes = 0.0
        var known = true
        for b in buckets.indices where !byBucket[b].isEmpty {
            guard let r = rates[b], r > 0 else { known = false; continue }
            minutes += Double(byBucket[b].count) / r
        }
        emit("I reading all \(all.count) workouts at C1 speeds: \(known ? "" : "at least ")\(f(minutes)) min · heat \(Self.heat())")
        emit("Done.")
    }
}

/// Totals collected from parallel speed-test jobs.
private final class BenchBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var workouts = 0, records = 0, raw = 0, gz = 0
    private(set) var encodeMs = 0.0
    func add(records r: Int, raw w: Int, gz z: Int, encodeMs e: Double) {
        lock.withLock {
            workouts += 1
            records += r
            raw += w
            gz += z
            encodeMs += e
        }
    }
}
