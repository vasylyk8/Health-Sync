import Foundation
import HealthKit

/// One entry of shared/coverage.json.
struct CoverageEntry: Decodable, Sendable {
    let id: String
    let kind: String
    let agg: String?
    let unit: String?
    let group: String
    let record: String
}

/// A data type this device can sync, resolved from the coverage matrix.
struct SyncType: @unchecked Sendable, Hashable {
    enum Kind: Hashable {
        case quantity(cumulative: Bool)
        case category, workout, ecg, heartbeat, activitySummary, correlation, stateOfMind, audiogram, characteristics
    }

    let id: String
    let kind: Kind
    /// Sample type for sample-based kinds (nil for activity summaries and characteristics).
    let sampleType: HKSampleType?
    let unit: HKUnit?

    static func == (a: SyncType, b: SyncType) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isAnchored: Bool {
        switch kind {
        case .quantity, .category, .workout, .ecg, .heartbeat, .stateOfMind, .audiogram: return true
        default: return false
        }
    }

    var quantityType: HKQuantityType? { sampleType as? HKQuantityType }
}

enum HealthTypes {
    static let profileId = "_profile"
    /// Batch type for "checked, nothing new" reports covering many types at once.
    static let statusId = "_status"

    static func loadCoverage(bundle: Bundle = .main) -> [CoverageEntry] {
        guard let url = bundle.url(forResource: "coverage", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CoverageFile.self, from: data) else { return [] }
        return file.types
    }

    private struct CoverageFile: Decodable { let types: [CoverageEntry] }

    /// Resolves every coverage entry available on this iOS version. Unknown or unavailable
    /// identifiers are skipped, so new types simply start syncing on newer phones.
    static func resolve(_ entries: [CoverageEntry]) -> [SyncType] {
        entries.compactMap(resolve)
    }

    static func resolve(_ e: CoverageEntry) -> SyncType? {
        switch e.kind {
        case "quantity":
            guard let qt = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: e.id)),
                  let unitName = e.unit, let unit = unit(named: unitName), qt.is(compatibleWith: unit) else { return nil }
            return SyncType(id: e.id, kind: .quantity(cumulative: e.agg == "cumulative"), sampleType: qt, unit: unit)
        case "category":
            guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: e.id)) else { return nil }
            return SyncType(id: e.id, kind: .category, sampleType: ct, unit: nil)
        case "workout":
            return SyncType(id: e.id, kind: .workout, sampleType: HKObjectType.workoutType(), unit: nil)
        case "ecg":
            return SyncType(id: e.id, kind: .ecg, sampleType: HKObjectType.electrocardiogramType(), unit: nil)
        case "heartbeat":
            return SyncType(id: e.id, kind: .heartbeat, sampleType: HKSeriesType.heartbeat(), unit: nil)
        case "activitySummary":
            return SyncType(id: e.id, kind: .activitySummary, sampleType: nil, unit: nil)
        case "correlation":
            guard let ct = HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: e.id)) else { return nil }
            return SyncType(id: e.id, kind: .correlation, sampleType: ct, unit: nil)
        case "stateOfMind":
            if #available(iOS 18.0, *) {
                return SyncType(id: e.id, kind: .stateOfMind, sampleType: HKObjectType.stateOfMindType(), unit: nil)
            }
            return nil
        case "audiogram":
            return SyncType(id: e.id, kind: .audiogram, sampleType: HKObjectType.audiogramSampleType(), unit: nil)
        case "characteristics":
            return SyncType(id: e.id, kind: .characteristics, sampleType: nil, unit: nil)
        default:
            return nil
        }
    }

    /// Everything the app asks permission to read. Correlation types cannot be requested
    /// directly (HealthKit throws); they become readable through their component types.
    static func readPermissions(for types: [SyncType]) -> Set<HKObjectType> {
        var set = Set<HKObjectType>()
        for t in types {
            switch t.kind {
            case .correlation, .characteristics:
                continue
            case .activitySummary:
                set.insert(HKObjectType.activitySummaryType())
            default:
                if let st = t.sampleType { set.insert(st) }
            }
        }
        let characteristics: [HKCharacteristicTypeIdentifier] = [.dateOfBirth, .biologicalSex, .bloodType, .fitzpatrickSkinType, .wheelchairUse, .activityMoveMode]
        for id in characteristics {
            if let c = HKObjectType.characteristicType(forIdentifier: id) { set.insert(c) }
        }
        return set
    }

    /// Canonical units from the coverage matrix, built with HKUnit factory methods (never parsed
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
        case "mmHg": return .millimeterOfMercury()
        case "mcS": return .siemenUnit(with: .micro)
        case "mg/dL": return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case "L": return .liter()
        case "L/min": return .liter().unitDivided(by: .minute())
        case "IU": return .internationalUnit()
        case "kg": return .gramUnit(with: .kilo)
        case "g": return .gram()
        default: return nil
        }
    }
}
