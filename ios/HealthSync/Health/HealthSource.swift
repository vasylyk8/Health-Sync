import Foundation

/// One page from an anchored query: records to upload (including deletion tombstones) and the
/// opaque anchor to resume from once they are safely on the server.
struct AnchoredPage: Sendable {
    var records: [Record]
    var newAnchor: Data?
    /// Number of HealthKit objects returned (samples + deletions), compared against the limit.
    var objectCount: Int
}

/// Everything the sync engine needs from Apple Health. The real implementation wraps HealthKit;
/// tests use an in-memory fake.
protocol HealthSource: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization(types: [SyncType]) async throws
    /// Samples started in [from, to), newest first (the fast "recent" pass).
    func samples(_ type: SyncType, from: Date, to: Date) async throws -> [Record]
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage
    /// Merged hourly statistics (`h` records) in [from, to).
    func hourlyStats(_ type: SyncType, from: Date, to: Date) async throws -> [Record]
    func earliestSampleDate(_ type: SyncType) async throws -> Date?
    func activitySummaries(from: Date, to: Date) async throws -> [Record]
    func correlations(_ type: SyncType, from: Date, to: Date) async throws -> [Record]
    func profile() -> Record?
    /// Registers background observers; `onChange` must call its completion when finished.
    func observeChanges(types: [SyncType], onChange: @escaping @Sendable (SyncType, @escaping @Sendable () -> Void) -> Void)
}
