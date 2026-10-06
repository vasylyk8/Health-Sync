import Foundation

/// Investigation only. A nil task-local leaves the shipped reader unchanged.
enum InitialSyncExperiments {
    enum Strategy: String, Sendable, CaseIterable {
        case baseline, selectiveFallback, sharedStatistics, widerStatistics, combined
        var selective: Bool { self == .selectiveFallback || self == .combined }
        var shared: Bool { self == .sharedStatistics || self == .widerStatistics || self == .combined }
        var unified: Bool { self == .sharedStatistics || self == .combined }
        var wider: Bool { self == .widerStatistics || self == .combined }
    }
    @TaskLocal static var strategy: Strategy?
    @TaskLocal static var historyStart: Date?
    @TaskLocal static var historyEnd: Date?
    @TaskLocal static var statistics: DailyStatisticsCache?

    /// Preserve annual consumers/batches; candidate native queries cover pairs of years.
    static func statisticsWindow(from: Date, to: Date, calendar: Calendar) -> (Date, Date) {
        guard strategy?.wider == true, let start = historyStart, let end = historyEnd,
              from >= start, to <= end else { return (from, to) }
        var a = start
        while a < end {
            let b = min(calendar.date(byAdding: .year, value: 2, to: a) ?? end, end)
            if from >= a && to <= b { return (a, b) }
            guard b > a else { break }
            a = b
        }
        return (from, to)
    }

    static func canSelectivelyRead(style: SampleAggregator.Style, hourlyConsumer: Bool, calibrating: Bool) -> Bool {
        // Cumulative suppression needs Watch neighbors across the whole span of any overlapping phone sample,
        // potentially well outside the gap. Keep the established full fallback rather than changing that rule.
        strategy?.selective == true && style != .cumulative && !hourlyConsumer && !calibrating
    }

    /// Only use selective reads for a small gap in otherwise dense statistics.
    /// Sparse types and broad failures keep the full existing raw recovery path.
    static func missingWindows(present: Set<String>, from: Date, to: Date, calendar: Calendar) -> [DateInterval]? {
        var days: [DateInterval] = [], missing: [DateInterval] = []
        var cursor = calendar.startOfDay(for: from)
        while cursor < to {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { return nil }
            let day = DateInterval(start: cursor, end: min(next, to))
            days.append(day)
            if !present.contains(SleepNights.dayKey(cursor, calendar: calendar)) { missing.append(day) }
            cursor = next
        }
        guard !missing.isEmpty, missing.count <= 31, missing.count * 4 <= days.count else { return nil }
        var windows: [DateInterval] = []
        for day in missing {
            if let last = windows.last, last.end == day.start {
                windows[windows.count - 1] = DateInterval(start: last.start, end: day.end)
            } else { windows.append(day) }
        }
        return windows
    }
}

struct DailyStatisticsKey: Hashable, Sendable {
    let type: String, unit: String
    let from: Date, to: Date
    let zone: String
    let explicitSources: Bool
}
struct DailyStatisticsSnapshot: Sendable {
    /// Unscaled values for avg/min/max. Consumers retain their original scales.
    let values: [String: [(String, Double)]]
}
actor DailyStatisticsCache {
    private var running: [DailyStatisticsKey: Task<DailyStatisticsSnapshot, Error>] = [:]
    private var completed: [DailyStatisticsKey: DailyStatisticsSnapshot] = [:]
    private var order: [DailyStatisticsKey] = []
    private(set) var hits = 0
    private(set) var builds = 0
    func value(_ key: DailyStatisticsKey, build: @escaping @Sendable () async throws -> DailyStatisticsSnapshot) async throws -> DailyStatisticsSnapshot {
        try Task.checkCancellation()
        if let value = completed[key] { hits += 1; return value }
        if let task = running[key] {
            hits += 1
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }
        builds += 1
        let task = Task { try await build() }
        running[key] = task
        do {
            let result = try await task.value
            try Task.checkCancellation()
            running[key] = nil
            if completed.count >= 128, !order.isEmpty { completed[order.removeFirst()] = nil }
            completed[key] = result; order.append(key)
            return result
        } catch { running[key] = nil; throw error }
    }
    func cancelAll() { running.values.forEach { $0.cancel() } }
}
