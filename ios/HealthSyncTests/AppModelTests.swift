import XCTest
@testable import HealthSync

/// Backend whose sign-in can be made to fail (offline, server error).
final class StubBackend: Backend, @unchecked Sendable {
    var signInError: Error?
    var registerError: Error?
    func signIn() async throws -> String {
        if let signInError { throw signInError }
        return "stub-user"
    }
    func registerDevice(timeZone: String) async throws { if let registerError { throw registerError } }
    func createLink(provider: String) async throws -> String { "https://example.test/mcp/\(provider)" }
    func disconnect(provider: String) async throws {}
    func deleteAllData() async throws {}
    var categoryCalls: [[String]] = []
    func setCategories(_ ids: [String]) async throws { categoryCalls.append(ids) }
    func status() async throws -> ServerStatus { .empty }
    func batchExists(batchId: String) async throws -> Bool { true }
    func signOut() async {}
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {}
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(_ backend: StubBackend) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!
        return AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: defaults)
    }

    func testOfflineSyncShowsAnIssueThatClearsOnSuccess() async {
        let backend = StubBackend()
        backend.signInError = URLError(.notConnectedToInternet)
        let model = makeModel(backend)
        XCTAssertNil(model.syncIssue)

        await model.syncNow()
        XCTAssertEqual(model.syncIssue?.contains("offline"), true)

        backend.signInError = nil
        await model.syncNow()
        XCTAssertNil(model.syncIssue)
    }

    func testOtherFailuresAskTheUserToRetry() async {
        let backend = StubBackend()
        backend.signInError = BackendError.badResponse
        let model = makeModel(backend)
        await model.syncNow()
        XCTAssertEqual(model.syncIssue?.contains("Pull down"), true)
    }

    func testConnectFailureNamesTheStepAndCode() async {
        let backend = StubBackend()
        backend.registerError = NSError(domain: "com.firebase.functions", code: 13)
        let model = makeModel(backend)
        await model.connectHealth()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertEqual(model.errorMessage?.contains("register: com.firebase.functions 13"), true)
        XCTAssertEqual(model.errorMessage?.hasPrefix("Something went wrong. Please try again."), true)

        backend.registerError = nil
        backend.signInError = NSError(domain: "FIRAuthErrorDomain", code: 17999)
        await model.connectHealth()
        XCTAssertEqual(model.errorMessage?.contains("sign-in: FIRAuthErrorDomain 17999"), true)
    }

    func testCanConnectAgainAfterDeletingAllData() async {
        let model = makeModel(StubBackend())
        await model.connectHealth()
        XCTAssertEqual(model.phase, .home)
        await model.deleteAllData()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertFalse(model.busy, "the welcome button must not stay disabled after deletion")
        await model.connectHealth()
        XCTAssertEqual(model.phase, .home)
        XCTAssertFalse(model.busy)
    }

    /// The same objects the -uiTesting app uses (fake backend and HealthKit, the real coverage file).
    func testUITestingStackReconnectsAfterDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!
        defaults.set(true, forKey: "healthConnected")
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        XCTAssertNotNil(scope.workout)
        let model = AppModel(backend: FakeBackend(), source: FakeHealthSource(), outbox: Outbox(root: root), scope: scope, telemetry: NoTelemetry(), defaults: defaults)
        XCTAssertEqual(model.phase, .home)
        model.start()
        try await Task.sleep(for: .milliseconds(300))
        await model.deleteAllData()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertFalse(model.busy)

        let done = expectation(description: "connect finishes")
        Task { @MainActor in
            await model.connectHealth()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 15)
        XCTAssertEqual(model.phase, .home)
        XCTAssertFalse(model.busy)
    }

    func testSwitchingACategoryOnTellsTheServerFirstAndOffDeletesIt() async {
        let backend = StubBackend()
        let model = makeModel(backend)
        await model.setCategory("devices", on: true)
        XCTAssertTrue(model.isEnabled("devices"))
        XCTAssertEqual(backend.categoryCalls.last, ["core", "devices"])
        await model.setCategory("devices", on: false)
        XCTAssertFalse(model.isEnabled("devices"))
        XCTAssertEqual(backend.categoryCalls.last, ["core"])
        await model.setCategory("core", on: false)
        XCTAssertEqual(backend.categoryCalls.count, 2, "core is always on and never sent as a change")
    }

    func testErrorMessagesAreActionable() {
        XCTAssertTrue(AppModel.message(for: URLError(.notConnectedToInternet)).contains("offline"))
        XCTAssertTrue(AppModel.message(for: NSError(domain: "com.firebase.functions", code: 8)).contains("Too many"))
        XCTAssertEqual(AppModel.message(for: NSError(domain: "com.firebase.functions", code: 9, userInfo: [NSLocalizedDescriptionKey: "This account is being deleted."])), "This account is being deleted.")
        XCTAssertEqual(AppModel.message(for: BackendError.notSignedIn), "Could not sign in. Check your internet connection.")
        XCTAssertEqual(AppModel.message(for: NSError(domain: "x", code: 1)), "Something went wrong. Please try again.")
    }
}

/// Health source whose permission request fails or never answers (as seen on a real iPhone).
final class AuthProblemSource: HealthSource, @unchecked Sendable {
    var authError: Error?
    var hang = false
    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws {
        if hang { try await Task.sleep(for: .seconds(3600)) }
        if let authError { throw authError }
    }
    func workouts(from: Date, to: Date) async throws -> [Record] { [] }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        AnchoredPage(records: [], newAnchor: nil, objectCount: 0)
    }
    func workoutIndex() async throws -> [WorkoutRef] { [] }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? { nil }
    func dailyContext(from: Date, to: Date) async throws -> [Record] { [] }
    func earliestDailyDate() async throws -> Date? { nil }
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
}

@MainActor
final class ConnectPermissionTests: XCTestCase {
    private func makeModel(_ source: AuthProblemSource) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "connect-\(UUID().uuidString)")!
        return AppModel(backend: StubBackend(), source: source, outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: defaults)
    }

    func testHealthKitSourceLookupErrorTellsTheUserToRestart() async {
        let source = AuthProblemSource()
        source.authError = NSError(domain: "com.apple.healthkit", code: 3,
                                   userInfo: [NSLocalizedDescriptionKey: "Failed to look up source with bundle identifier \"app.test\""])
        let model = makeModel(source)
        await model.connectHealth()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertEqual(model.errorMessage?.contains("Restart your iPhone"), true)
        XCTAssertEqual(model.errorMessage?.contains("health-permission: com.apple.healthkit 3"), true)
        XCTAssertEqual(model.errorMessage?.contains("Failed to look up source"), true)
        XCTAssertFalse(model.busy)
    }

    func testSilentPermissionRequestShowsWhatToDo() async throws {
        let source = AuthProblemSource()
        source.hang = true
        let model = makeModel(source)
        model.permissionHintDelay = .milliseconds(100)
        let connecting = Task { await model.connectHealth() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.connectStage, "Waiting for Apple Health…")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.connectStage, AppModel.permissionStallHint)
        XCTAssertTrue(model.busy)
        connecting.cancel()
    }
}
