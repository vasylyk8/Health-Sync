import Foundation
import HealthKit

/// One entry of `types` in shared/coverage.json.
struct CoverageEntry: Decodable, Sendable {
    let id: String
    let kind: String
    let group: String
    let record: String
    /// Consent category the type belongs to (default "core").
    let category: String?
}

/// A quantity type read for every workout (raw series and Apple's statistics).
struct WorkoutQuantitySpec: Decodable, Sendable {
    let id: String
    let unit: String
    let agg: String
    /// `false`: Apple's workout statistics are kept but the per-sample stream is not read or uploaded.
    let stream: Bool?
}

/// One daily-context metric (see docs/DATA_CONTRACT.md §2).
struct DailyMetricSpec: Decodable, Sendable {
    let key: String
    let kind: String
    let id: String
    let unit: String?
    let agg: String?
    let mode: String?
    let outputs: [String]?
    /// Consent category (default "core").
    let category: String?
    /// "apple": read only samples written by Apple's own sources (Apple Watch, iPhone), so another app that also
    /// writes (for example) a resting heart rate does not blend into the average.
    let source: String?
}

/// A group of data the user switches on or off as a whole (coverage.json `categories`).
struct CoverageCategory: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let `default`: Bool?
}

/// A quantity read as hourly buckets (average/min/max, or a sum) over the whole history.
struct HourlyMetricSpec: Decodable, Sendable {
    let name: String
    let id: String
    let unit: String
    let cols: [String]
}

/// A kind of event or timed entry (symptom, glucose reading, nutrient...) uploaded as `ev` chunks.
struct EventTypeSpec: Decodable, Sendable {
    let name: String
    let id: String
    let kind: String
    let category: String
    let unit: String?
    let dense: Bool?
}

struct CoverageFile: Decodable, Sendable {
    let types: [CoverageEntry]
    let workoutQuantityTypes: [WorkoutQuantitySpec]
    let dailyMetrics: [DailyMetricSpec]
    let categories: [CoverageCategory]?
    let hourlyMetrics: [HourlyMetricSpec]?
    let eventTypes: [EventTypeSpec]?
}

/// A batch type this app syncs: workouts (anchored) or the daily context pseudo-type.
struct SyncType: @unchecked Sendable, Hashable {
    enum Kind: Hashable { case workout, daily, events }

    let id: String
    let kind: Kind
    /// Sample type for workouts and events (nil for the daily-context pseudo-type).
    let sampleType: HKSampleType?
    /// Set for `.events`: which event type this anchored pass reads.
    var event: EventType? = nil

    static func == (a: SyncType, b: SyncType) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isAnchored: Bool { kind != .daily }
    /// Batch type (header `type`) uploads of this pass use.
    var headerType: String { event?.headerType ?? id }
}

/// A quantity type that is read for each workout.
struct WorkoutQuantity: @unchecked Sendable {
    let id: String
    /// Short name used as the stream name on the server (e.g. "HeartRate").
    let name: String
    let type: HKQuantityType
    let unit: HKUnit
    let unitLabel: String
    let cumulative: Bool
    /// Whether the per-sample stream is read and uploaded (statistics are always kept).
    let stream: Bool
}

/// A quantity read as hourly buckets.
struct HourlyMetric: @unchecked Sendable {
    let name: String
    let type: HKQuantityType
    let unit: HKUnit
    let unitLabel: String
    let cumulative: Bool
    let cols: [String]
    let appleOnly: Bool
}

enum EventKind: Sendable { case quantity, category, medication, characteristic }

/// One kind of event or timed entry, uploaded in its category's `_events_<category>` batches.
struct EventType: @unchecked Sendable {
    let name: String
    let category: String
    let kind: EventKind
    let sampleType: HKSampleType?
    let unit: HKUnit?
    let unitLabel: String?
    /// Dense series (a reading every few minutes) are sent without ids and without per-reading metadata.
    let dense: Bool

    /// Key of this event type in the outbox (anchor, completion).
    var typeId: String { "ev:\(name)" }
    var headerType: String { "_events_\(category)" }
}

enum DailyAgg: String, Sendable { case sum, avg, min, max, last }
enum CategoryMode: String, Sendable { case minutes, values, count }

struct DailyMetric: @unchecked Sendable {
    enum Kind {
        case quantity(HKQuantityType, unit: HKUnit, agg: DailyAgg, scale: Double)
        case category(HKCategoryType, CategoryMode)
        case sleep(HKCategoryType)
        case rings
        case stateOfMind
    }

    let key: String
    let kind: Kind
    /// Consent category this metric belongs to.
    var category = "core"
    var appleOnly = false

    /// Batch type of the daily rows of this metric's category ("_daily" for the core category).
    var batchType: String { HealthTypes.dailyBatchType(category) }
}

/// Everything this device can sync, resolved from the coverage file for the running iOS version.
struct SyncScope: @unchecked Sendable {
    var types: [SyncType]
    var workoutQuantities: [WorkoutQuantity]
    var dailyMetrics: [DailyMetric]
    var hourly: [HourlyMetric] = []
    var events: [EventType] = []
    var categories: [CoverageCategory] = []

    static let empty = SyncScope(types: [], workoutQuantities: [], dailyMetrics: [])

    var workout: SyncType? { types.first { $0.kind == .workout } }
}

enum HealthTypes {
    static let workoutId = "HKWorkoutTypeIdentifier"
    /// Batch type for raw workout streams.
    static let streamId = "_wstream"
    /// Batch type for daily-context rows.
    static let dailyId = "_daily"
    /// Batch type for "checked, nothing new" reports.
    static let statusId = "_status"
    /// Batch type for hourly series (heart rate, steps, HRV).
    static let hourlyId = "_hourly"
    static let quantityPrefix = "HKQuantityTypeIdentifier"
    static let categoryPrefix = "HKCategoryTypeIdentifier"

    /// Daily rows of a category go in their own batch type, so switching a category off removes exactly its rows.
    static func dailyBatchType(_ category: String) -> String { category == "core" ? dailyId : "\(dailyId)_\(category)" }

    static func loadCoverage(bundle: Bundle = .main) -> CoverageFile? {
        guard let url = bundle.url(forResource: "coverage", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CoverageFile.self, from: data)
    }

    /// "HKQuantityTypeIdentifierHeartRate" -> "HeartRate".
    static func shortName(_ id: String) -> String {
        id.hasPrefix(quantityPrefix) ? String(id.dropFirst(quantityPrefix.count)) : id
    }

    /// Resolves the coverage file for this iOS version. Unknown or unavailable identifiers are
    /// skipped, so new types simply start syncing on newer phones.
    static func scope(_ file: CoverageFile?) -> SyncScope {
        guard let file else { return .empty }
        var types: [SyncType] = []
        for e in file.types where e.kind == "workout" {
            types.append(SyncType(id: e.id, kind: .workout, sampleType: HKObjectType.workoutType()))
        }
        let quantities: [WorkoutQuantity] = file.workoutQuantityTypes.compactMap { s in
            guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: s.id)),
                  let unit = unit(named: s.unit), qt.is(compatibleWith: unit) else { return nil }
            return WorkoutQuantity(id: s.id, name: shortName(s.id), type: qt, unit: unit, unitLabel: s.unit, cumulative: s.agg == "cumulative", stream: s.stream ?? true)
        }
        let metrics: [DailyMetric] = file.dailyMetrics.compactMap(dailyMetric)
        let hourly: [HourlyMetric] = (file.hourlyMetrics ?? []).compactMap { h in
            guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: h.id)),
                  let unit = unit(named: h.unit), qt.is(compatibleWith: unit) else { return nil }
            return HourlyMetric(name: h.name, type: qt, unit: unit, unitLabel: h.unit, cumulative: qt.aggregationStyle == .cumulative,
                                cols: h.cols, appleOnly: h.name.hasPrefix("HeartRateVariability"))
        }
        let events: [EventType] = (file.eventTypes ?? []).compactMap(eventType)
        var scope = SyncScope(types: types, workoutQuantities: quantities, dailyMetrics: metrics)
        scope.hourly = hourly
        scope.events = events
        scope.categories = file.categories ?? []
        return scope
    }

    /// Resolves one event type for this iOS version; nil when HealthKit (or the unit) does not know it.
    static func eventType(_ s: EventTypeSpec) -> EventType? {
        let dense = s.dense ?? false
        switch s.kind {
        case "quantity":
            guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: s.id)),
                  let unitName = s.unit, let unit = unit(named: unitName), qt.is(compatibleWith: unit) else { return nil }
            return EventType(name: s.name, category: s.category, kind: .quantity, sampleType: qt, unit: unit, unitLabel: unitName, dense: dense)
        case "category":
            guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: s.id)) else { return nil }
            return EventType(name: s.name, category: s.category, kind: .category, sampleType: ct, unit: nil, unitLabel: nil, dense: dense)
        case "medication":
            return EventType(name: s.name, category: s.category, kind: .medication, sampleType: nil, unit: nil, unitLabel: nil, dense: false)
        case "characteristic":
            return EventType(name: s.name, category: s.category, kind: .characteristic, sampleType: nil, unit: nil, unitLabel: nil, dense: false)
        default:
            return nil
        }
    }

    static func dailyMetric(_ s: DailyMetricSpec) -> DailyMetric? {
        switch s.kind {
        case "quantity":
            guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: s.id)),
                  let unitName = s.unit, let unit = unit(named: unitName), qt.is(compatibleWith: unit) else { return nil }
            // "auto" picks the sum for cumulative types and the average otherwise.
            let aggName = s.agg == "auto" ? (qt.aggregationStyle == .cumulative ? "sum" : "avg") : (s.agg ?? "")
            guard let agg = DailyAgg(rawValue: aggName) else { return nil }
            // A statistics option that does not fit the type's aggregation style raises an exception in HealthKit:
            // skip such a metric instead of crashing.
            guard (agg == .sum) == (qt.aggregationStyle == .cumulative) else { return nil }
            // HealthKit percentages are fractions (0.97); the server stores 97.
            return DailyMetric(key: s.key, kind: .quantity(qt, unit: unit, agg: agg, scale: unitName == "%" ? 100 : 1), category: s.category ?? "core", appleOnly: s.source == "apple")
        case "category":
            guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: s.id)),
                  let mode = CategoryMode(rawValue: s.mode ?? "") else { return nil }
            return DailyMetric(key: s.key, kind: .category(ct, mode), category: s.category ?? "core")
        case "sleep":
            guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: s.id)) else { return nil }
            return DailyMetric(key: s.key, kind: .sleep(ct), category: s.category ?? "core")
        case "activitySummary":
            return DailyMetric(key: s.key, kind: .rings, category: s.category ?? "core")
        case "stateOfMind":
            if #available(iOS 18.0, *) { return DailyMetric(key: s.key, kind: .stateOfMind, category: s.category ?? "core") }
            return nil
        default:
            return nil
        }
    }

    /// Everything the app asks permission to read (all read-only). The route type is what
    /// lets the app read a workout's GPS route through HealthKit.
    static func readPermissions(for scope: SyncScope, categories: Set<String> = ["core"]) -> Set<HKObjectType> {
        var set = Set<HKObjectType>()
        set.insert(HKObjectType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        for q in scope.workoutQuantities { set.insert(q.type) }
        for h in scope.hourly { set.insert(h.type) }
        for e in scope.events where categories.contains(e.category) {
            if let t = e.sampleType { set.insert(t) }
        }
        if categories.contains("profile") {
            for id in [HKCharacteristicTypeIdentifier.dateOfBirth, .biologicalSex, .wheelchairUse, .activityMoveMode] {
                if let t = HKObjectType.characteristicType(forIdentifier: id) { set.insert(t) }
            }
        }
        for m in scope.dailyMetrics where categories.contains(m.category) {
            switch m.kind {
            case .quantity(let t, _, _, _): set.insert(t)
            case .category(let t, _): set.insert(t)
            case .sleep(let t): set.insert(t)
            case .rings: set.insert(HKObjectType.activitySummaryType())
            case .stateOfMind:
                if #available(iOS 18.0, *) { set.insert(HKObjectType.stateOfMindType()) }
            }
        }
        return set
    }

    /// Canonical units from the coverage file, built with HKUnit factory methods (never parsed
    /// from strings, which raises an exception on unknown input).
    static func unit(named name: String) -> HKUnit? {
        switch name {
        case "count": return .count()
        case "m": return .meter()
        case "cm": return .meterUnit(with: .centi)
        case "kcal": return .kilocalorie()
        case "min": return .minute()
        case "ms": return .secondUnit(with: .milli)
        case "count/min": return .count().unitDivided(by: .minute())
        case "m/s": return .meter().unitDivided(by: .second())
        case "W": return .watt()
        case "kcal/(hr*kg)": return .kilocalorie().unitDivided(by: HKUnit.hour().unitMultiplied(by: .gramUnit(with: .kilo)))
        case "appleEffortScore":
            if #available(iOS 18.0, *) { return .appleEffortScore() }
            return nil
        case "degC": return .degreeCelsius()
        case "%": return .percent()
        case "dBASPL": return .decibelAWeightedSoundPressureLevel()
        case "ml/(kg*min)": return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case "L": return .liter()
        case "kg": return .gramUnit(with: .kilo)
        case "g": return .gram()
        case "mg": return .gramUnit(with: .milli)
        case "mcg": return .gramUnit(with: .micro)
        case "mg/dL": return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case "mmHg": return .millimeterOfMercury()
        case "L/min": return .liter().unitDivided(by: .minute())
        case "IU": return .internationalUnit()
        default: return nil
        }
    }
}
