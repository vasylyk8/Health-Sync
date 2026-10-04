import Foundation

/// One page from an anchored query: records to upload (including deletion tombstones) and the
/// opaque anchor to resume from once they are safely on the server.
struct AnchoredPage: Sendable {
    var records: [Record]
    var newAnchor: Data?
    /// Number of HealthKit objects returned (workouts + deletions), compared against the limit.
    var objectCount: Int
}

/// Daily-context rows of one consent category, uploaded as their own batch type.
struct DailyBatch: Sendable {
    var typeId: String
    var category: String
    var records: [Record]
    /// What the read of this category found (counts, lost/failed metrics), sent with the batch for diagnosis.
    var note: String? = nil
    /// Metrics that have samples in the range came back empty even after asking again: the read lost data and is repeated later.
    var incomplete = false
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
    /// Asks for the types of the given consent categories ("core" is always included).
    func requestAuthorization(scope: SyncScope, categories: Set<String>) async throws
    /// Apple's separate per-medication permission sheet (iOS 26). Kept apart from `requestAuthorization` so a slow or
    /// missing second sheet can never hold up the main permission step; never throws.
    func requestMedicationAuthorization() async
    /// Asks only for types this install was never asked about (one the app reads since an update); never throws.
    func requestNewTypes(scope: SyncScope, categories: Set<String>) async
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
    /// The same, split by consent category (each category's rows are their own batch type).
    func dailyContextBatches(from: Date, to: Date, categories: Set<String>) async throws -> [DailyBatch]
    /// Hourly buckets (heart rate, steps, HRV) in [from, to) as `hs` records.
    func hourlySeries(from: Date, to: Date) async throws -> [Record]
    /// The medications the user chose to share, as `ev` records (names only; no dose history).
    func medicationRecords() async throws -> [Record]
    /// The profile entry (date of birth, sex, wheelchair use, move mode) as one `ev` record, or none.
    func profileRecords() async throws -> [Record]
    /// Earliest sample across the daily-context metrics, to know how far back to start.
    func earliestDailyDate() async throws -> Date?
    /// What the last daily-context read found, as one short diagnostic line (nil for sources with nothing to report).
    func dailyDiagnosticNote() -> String?
    /// Which source-aware fallbacks the last hourly read needed (type names only; never health values).
    func hourlyDiagnosticNote() -> String?
    /// How many HealthKit queries may run at the same time (raw workout data), adjusted while syncing.
    var queryConcurrency: Int { get }
    func setQueryConcurrency(_ n: Int)
    /// On-device read-speed measurements (the "speed test"); reports its full text so far after each step.
    func benchmark(onUpdate: @escaping @Sendable (String) -> Void) async
    /// Registers a background observer for new workouts; `onChange` must call its completion when done.
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void)
    /// Registers background observers for heart rate, steps and the event types of these categories; `onChange` must call its completion when done.
    func observeOtherData(categories: Set<String>, onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void)
}

extension HealthSource {
    func requestMedicationAuthorization() async {}
    func requestNewTypes(scope: SyncScope, categories: Set<String>) async {}
    func requestAuthorization(scope: SyncScope, categories: Set<String>) async throws { try await requestAuthorization(scope: scope) }
    func dailyContextBatches(from: Date, to: Date, categories: Set<String>) async throws -> [DailyBatch] {
        [DailyBatch(typeId: HealthTypes.dailyId, category: "core", records: try await dailyContext(from: from, to: to), note: dailyDiagnosticNote())]
    }
    func hourlySeries(from: Date, to: Date) async throws -> [Record] { [] }
    func observeOtherData(categories: Set<String>, onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
    func profileRecords() async throws -> [Record] { [] }
    func medicationRecords() async throws -> [Record] { [] }
    var queryConcurrency: Int { 1 }
    func setQueryConcurrency(_ n: Int) {}
    func benchmark(onUpdate: @escaping @Sendable (String) -> Void) async { onUpdate("The speed test needs Apple Health on a real iPhone.") }
}


extension HealthSource {
    func dailyDiagnosticNote() -> String? { nil }
    func hourlyDiagnosticNote() -> String? { nil }
}
