import Foundation

/// A fresh task-local cache belongs to one full or incremental sync, including all its child tasks.
/// Separate syncs/accounts cannot see one another's cached summaries, even when cancellation overlaps.
enum SharedRawHistory {
    @TaskLocal static var cache: RawHistoryCache?
    @TaskLocal static var statistics: DailyStatisticsCache?
    @TaskLocal static var endingAt: Date?

    static func withFreshCache<T>(endingAt cutoff: Date? = nil, _ body: () async throws -> T) async rethrows -> T {
        let shared = InitialSyncExperiments.strategy?.unified == true
        let session = RawHistoryCache(rowLimit: shared ? 400_000 : 100_000, entryLimit: shared ? 128 : 32)
        let stats = InitialSyncExperiments.statistics ?? DailyStatisticsCache()
        return try await withTaskCancellationHandler {
            do {
                let result = try await $endingAt.withValue(cutoff) {
                    try await $cache.withValue(session) { try await $statistics.withValue(stats) { try await body() } }
                }
                if InitialSyncExperiments.strategy != nil {
                    SyncTiming.shared.count("experiment.cacheBuilds", await session.builds)
                    SyncTiming.shared.count("experiment.cacheHits", await session.hits)
                    SyncTiming.shared.set("experiment.cachedRowsPeak", await session.peakRows)
                }
                return result
            } catch {
                await session.cancelAll()
                await stats.cancelAll()
                throw error
            }
        } onCancel: {
            Task { await session.cancelAll(); await stats.cancelAll() }
        }
    }
}

struct RawHistoryKey: Hashable, Sendable {
    let type: String
    let unit: String
    let scale: Double
    let from: Date
    let to: Date
    let calendar: String
    let timeZone: String
}

struct RawHistorySummary: Sendable {
    let daily: [String: [(String, Double)]]
    let hourly: [HourBucket]
    var cost: Int { daily.values.reduce(hourly.count) { $0 + $1.count } }
}

/// Single-flight computation; retains bounded aggregate output, never whole raw histories.
/// Failed reads are removed so the existing retry can execute a fresh query.
actor RawHistoryCache {
    private var running: [RawHistoryKey: Task<RawHistorySummary, Error>] = [:]
    private var completed: [RawHistoryKey: RawHistorySummary] = [:]
    private var order: [RawHistoryKey] = []
    private let rowLimit: Int
    private let entryLimit: Int
    private var prioritized = Set<RawHistoryKey>()
    private var rows = 0
    private(set) var hits = 0
    private(set) var builds = 0
    private(set) var peakRows = 0
    init(rowLimit: Int = 100_000, entryLimit: Int = 32) { self.rowLimit = rowLimit; self.entryLimit = max(1, entryLimit) }

    func value(_ key: RawHistoryKey, retentionPriority: Bool = false, build: @escaping @Sendable () async throws -> RawHistorySummary) async throws -> RawHistorySummary {
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
            let value = try await task.value
            try Task.checkCancellation()
            running[key] = nil
            if value.cost <= rowLimit {
                while rows + value.cost > rowLimit || completed.count >= entryLimit {
                    guard !order.isEmpty else { break }
                    let index = order.firstIndex { !prioritized.contains($0) } ?? 0
                    let key = order.remove(at: index)
                    prioritized.remove(key)
                    if let removed = completed.removeValue(forKey: key) { rows -= removed.cost }
                }
                completed[key] = value
                order.append(key)
                if retentionPriority { prioritized.insert(key) }
                rows += value.cost
                peakRows = max(peakRows, rows)
            }
            return value
        } catch {
            running[key] = nil
            throw error
        }
    }

    func cancelAll() { running.values.forEach { $0.cancel() } }

    var summary: String { "cacheBuilds=\(builds) cacheHits=\(hits) cachedRowsPeak=\(peakRows)" }
}

