import Foundation

/// In-memory backend used by UI tests and previews (launch argument `-uiTesting`).
/// A provider becomes "set up" a moment after its link is copied, simulating the AI connecting.
final class FakeBackend: Backend, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [String: String] = [:]
    private var setUp: [String: Bool] = [:]
    private(set) var uploads: [String] = []
    var lastVisibleAt: Double?

    func signIn() async throws -> String { "fake-user" }
    func registerDevice(timeZone: String) async throws {}

    func createLink(provider: String) async throws -> String {
        let url = "https://health-sync.example/mcp/\(provider)-\(UUID().uuidString.prefix(8))"
        lock.withLock { links[provider] = url }
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.lock.withLock { self.setUp[provider] = true }
        }
        return url
    }

    func disconnect(provider: String) async throws {
        lock.withLock {
            links[provider] = nil
            setUp[provider] = nil
        }
    }

    func deleteAllData() async throws { lock.withLock { links = [:]; setUp = [:] } }

    func status() async throws -> ServerStatus {
        lock.withLock {
            ServerStatus(registered: true, deleting: false, setUp: setUp, lastVisibleAt: lastVisibleAt ?? Date().timeIntervalSince1970 * 1000 - 120_000,
                         historySyncedBackTo: Date(timeIntervalSince1970: 1_552_000_000).timeIntervalSince1970 * 1000, typesWithData: 42)
        }
    }

    func signOut() async {}

    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        lock.withLock { uploads.append(batchId) }
    }
}

/// Health source with a little synthetic data (UI tests, simulator demos).
final class FakeHealthSource: HealthSource, @unchecked Sendable {
    var isAvailable: Bool { true }
    func requestAuthorization(types: [SyncType]) async throws {}
    func samples(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { [] }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        AnchoredPage(records: [], newAnchor: Data("a".utf8), objectCount: 0)
    }
    func hourlyStats(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { [] }
    func earliestSampleDate(_ type: SyncType) async throws -> Date? { nil }
    func activitySummaries(from: Date, to: Date) async throws -> [Record] { [] }
    func correlations(_ type: SyncType, from: Date, to: Date) async throws -> [Record] { [] }
    func profile() -> Record? { nil }
    func observeChanges(types: [SyncType], onChange: @escaping @Sendable (SyncType, @escaping @Sendable () -> Void) -> Void) {}
}
