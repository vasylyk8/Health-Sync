import Foundation

/// One page from an anchored query: records to upload (including deletion tombstones) and the
/// opaque anchor to resume from once they are safely on the server.
struct AnchoredPage: Sendable {
    var records: [Record]
    var newAnchor: Data?
    /// Number of HealthKit objects returned (workouts + deletions), compared against the limit.
    var objectCount: Int
}

/// A workout on this iPhone (id only), used to find those whose raw data is not uploaded yet.
struct WorkoutRef: Sendable, Equatable {
    let id: String
    let start: Date
}

/// Everything the sync engine needs from Apple Health. The real implementation wraps HealthKit;
/// tests use an in-memory fake.
protocol HealthSource: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization(scope: SyncScope) async throws
    /// Workout summaries started in [from, to), newest first (the fast "recent" pass).
    func workouts(from: Date, to: Date) async throws -> [Record]
    /// Workout summaries and deletions from the anchored query (full history and change capture).
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage
    /// Every workout on the device, newest first.
    func workoutIndex() async throws -> [WorkoutRef]
    /// Raw data of one workout as `ws` stream chunks followed by one `wd` marker; nil if the
    /// workout no longer exists. `gen` identifies this read (newer replaces older on the server).
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]?
    /// One `day` record per local calendar day in [from, to) that has any metric.
    func dailyContext(from: Date, to: Date) async throws -> [Record]
    /// Earliest sample across the daily-context metrics, to know how far back to start.
    func earliestDailyDate() async throws -> Date?
    /// How many HealthKit queries may run at the same time (raw workout data), adjusted while syncing.
    var queryConcurrency: Int { get }
    func setQueryConcurrency(_ n: Int)
    /// Registers a background observer for new workouts; `onChange` must call its completion when done.
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void)
}

extension HealthSource {
    var queryConcurrency: Int { 1 }
    func setQueryConcurrency(_ n: Int) {}
}
