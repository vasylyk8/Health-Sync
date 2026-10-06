import Foundation

/// In-memory backend used by UI tests and previews (launch argument `-uiTesting`).
/// A provider becomes "set up" a moment after its link is copied, simulating the AI connecting.
final class FakeBackend: Backend, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [String: String] = [:]
    private var setUp: [String: Bool] = [:]
    private var categories: [String] = ["core"]
    private(set) var uploads: [String] = []
    var lastVisibleAt: Double?
    private var appleLinked: Bool
    /// `-noAutoSetUp` keeps a provider "not set up" so a test can stay on the setup sheet as long as it needs.
    private let autoSetUp: Bool
    init(appleLinked: Bool = false, autoSetUp: Bool = true) {
        self.appleLinked = appleLinked
        self.autoSetUp = autoSetUp
    }
    func hasAppleAccount() async -> Bool { lock.withLock { appleLinked } }
    /// Accepts the UI-test stand-in for Apple's sheet without linking: UI tests that follow onboarding keep the private-link
    /// setup (consent) path; the linked/OAuth path is covered by launching with `-appleLinked`.
    func linkAppleAccount(_ result: AppleSignInResult, allowExistingAccount: Bool, replacingFreshAccount freshUid: String?) async throws {}

    func signIn() async throws -> String { "fake-user" }
    func registerDevice(timeZone: String) async throws {}

    func createLink(provider: String) async throws -> String {
        let url = "https://health-sync.example/mcp/\(provider)-\(UUID().uuidString.prefix(8))"
        lock.withLock { links[provider] = url }
        if autoSetUp {
            Task {
                try? await Task.sleep(for: .seconds(6))
                self.lock.withLock { self.setUp[provider] = true }
            }
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

    func setCategories(_ ids: [String]) async throws { lock.withLock { categories = ids } }
    func setRaceGoal(raceId: String, raceName: String, raceDate: String, goalSeconds: Int?) async throws {}

    func status() async throws -> ServerStatus {
        lock.withLock {
            ServerStatus(registered: true, deleting: false, setUp: setUp, lastVisibleAt: lastVisibleAt ?? Date().timeIntervalSince1970 * 1000 - 120_000,
                         historySyncedBackTo: Date(timeIntervalSince1970: 1_552_000_000).timeIntervalSince1970 * 1000, typesWithData: 42, categories: categories)
        }
    }

    func batchExists(batchId: String) async throws -> Bool { true }

    func signOut() async {}

    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        lock.withLock { uploads.append(batchId) }
    }
}

/// Health source with no data (UI tests, simulator demos).
final class FakeHealthSource: HealthSource, @unchecked Sendable {
    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws {}
    func workouts(from: Date, to: Date) async throws -> [Record] { [] }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        AnchoredPage(records: [], newAnchor: Data("a".utf8), objectCount: 0)
    }
    func workoutIndex() async throws -> [WorkoutRef] { [] }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? { nil }
    func dailyContext(from: Date, to: Date) async throws -> [Record] { [] }
    func earliestDailyDate() async throws -> Date? { nil }
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
}
