import Foundation
import HealthKit

/// One entry of `types` in shared/coverage.json.
struct CoverageEntry: Decodable, Sendable {
    let id: String
    let kind: String
    let group: String
    let record: String
}

/// A quantity type read for every workout (raw series and Apple's statistics).
struct WorkoutQuantitySpec: Decodable, Sendable {
    let id: String
    let unit: String
    let agg: String
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
}

struct CoverageFile: Decodable, Sendable {
    let types: [CoverageEntry]
    let workoutQuantityTypes: [WorkoutQuantitySpec]
    let dailyMetrics: [DailyMetricSpec]
}

/// A batch type this app syncs: workouts (anchored) or the daily context pseudo-type.
struct SyncType: @unchecked Sendable, Hashable {
    enum Kind: Hashable { case workout, daily }

    let id: String
    let kind: Kind
    /// Sample type for workouts (nil for the daily-context pseudo-type).
    let sampleType: HKSampleType?

    static func == (a: SyncType, b: SyncType) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isAnchored: Bool { kind == .workout }
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
}

enum DailyAgg: String, Sendable { case sum, avg, min, max, last }
enum CategoryMode: String, Sendable { case minutes, values }

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
}

/// Everything this device can sync, resolved from the coverage file for the running iOS version.
struct SyncScope: @unchecked Sendable {
    var types: [SyncType]
    var workoutQuantities: [WorkoutQuantity]
    var dailyMetrics: [DailyMetric]

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
    static let quantityPrefix = "HKQuantityTypeIdentifier"

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
            return WorkoutQuantity(id: s.id, name: shortName(s.id), type: qt, unit: unit, unitLabel: s.unit, cumulative: s.agg == "cumulative")
        }
        let metrics: [DailyMetric] = file.dailyMetrics.compactMap(dailyMetric)
        return SyncScope(types: types, workoutQuantities: quantities, dailyMetrics: metrics)
    }

    static func dailyMetric(_ s: DailyMetricSpec) -> DailyMetric? {
        switch s.kind {
        case "quantity":
            guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: s.id)),
                  let unitName = s.unit, let unit = unit(named: unitName), qt.is(compatibleWith: unit),
                  let agg = DailyAgg(rawValue: s.agg ?? "") else { return nil }
            // HealthKit percentages are fractions (0.97); the server stores 97.
            return DailyMetric(key: s.key, kind: .quantity(qt, unit: unit, agg: agg, scale: unitName == "%" ? 100 : 1))
        case "category":
            guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: s.id)),
                  let mode = CategoryMode(rawValue: s.mode ?? "") else { return nil }
            return DailyMetric(key: s.key, kind: .category(ct, mode))
        case "sleep":
            guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: s.id)) else { return nil }
            return DailyMetric(key: s.key, kind: .sleep(ct))
        case "activitySummary":
            return DailyMetric(key: s.key, kind: .rings)
        case "stateOfMind":
            if #available(iOS 18.0, *) { return DailyMetric(key: s.key, kind: .stateOfMind) }
            return nil
        default:
            return nil
        }
    }

    /// Everything the app asks permission to read (all read-only). The route type is what
    /// lets the app read a workout's GPS route through HealthKit.
    static func readPermissions(for scope: SyncScope) -> Set<HKObjectType> {
        var set = Set<HKObjectType>()
        set.insert(HKObjectType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        for q in scope.workoutQuantities { set.insert(q.type) }
        for m in scope.dailyMetrics {
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
        default: return nil
        }
    }
}
