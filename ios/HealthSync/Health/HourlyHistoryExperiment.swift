#if DEBUG
import Foundation

/// Initial-sync benchmark only. Daily metrics, workout quantities and source rules are unchanged.
enum HourlyHistoryExperiment: String, CaseIterable {
    case all, noHeartRate, stepsOnly, none

    func scope(from original: SyncScope) -> SyncScope {
        var result = original
        switch self {
        case .all: break
        case .noHeartRate: result.hourly.removeAll { $0.name == "HeartRate" }
        case .stepsOnly: result.hourly.removeAll { $0.name != "StepCount" }
        case .none: result.hourly = []
        }
        return result
    }
}
#endif
