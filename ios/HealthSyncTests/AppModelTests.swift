import XCTest
@testable import HealthSync

/// Backend whose sign-in can be made to fail (offline, server error).
final class StubBackend: Backend, @unchecked Sendable {
    struct ProductEvent: Equatable { let name: String; let outcome: String?; let durationMs: Int? }
    private let productEventsQueue = DispatchQueue(label: "StubBackend.productEvents")
    private var productEventStorage: [ProductEvent] = []
    var productEvents: [ProductEvent] { productEventsQueue.sync { productEventStorage } }
    func recordProductEvent(name: String, appVersion: String, outcome: String?, durationMs: Int?) async throws {
        productEventsQueue.sync {
            productEventStorage.append(ProductEvent(name: name, outcome: outcome, durationMs: durationMs))
        }
    }
    var signInError: Error?
    var registerError: Error?
    var appleLinked = false
    var appleLinkError: Error?
    var appleRestoreChoices: [Bool] = []
    var freshAccountChoices: [String?] = []
    /// The account the person ends up in after Sign in with Apple (a restore changes it).
    var uid = "stub-user"
    var restoredUid: String?
    func hasAppleAccount() async -> Bool { appleLinked }
    func linkAppleAccount(_ result: AppleSignInResult, allowExistingAccount: Bool, replacingFreshAccount freshUid: String?) async throws {
        appleRestoreChoices.append(allowExistingAccount)
        freshAccountChoices.append(freshUid)
        if let restoredUid, freshUid != nil { uid = restoredUid }
        if let appleLinkError { throw appleLinkError }
        appleLinked = true
    }
    func signIn() async throws -> String {
        if let signInError { throw signInError }
        return uid
    }
    var registerCalls = 0
    func registerDevice(timeZone: String) async throws { registerCalls += 1; if let registerError { throw registerError } }
    func createLink(provider: String) async throws -> String { "https://example.test/mcp/\(provider)" }
    func disconnect(provider: String) async throws {}
    func deleteAllData() async throws {}
    var goalCalls: [(raceId: String, goalSeconds: Int?)] = []
    var goalError: Error?
    func setRaceGoal(raceId: String, raceName: String, raceDate: String, goalSeconds: Int?) async throws {
        if let goalError { throw goalError }
        goalCalls.append((raceId, goalSeconds))
    }
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

    func testTheFinishTimeIsStoredAndSentUntilTheServerHasIt() async throws {
        let backend = StubBackend()
        let model = makeModel(backend)
        model.edition = SpecialEdition.chicago2026
        XCTAssertNil(model.goalSeconds)
        backend.goalError = URLError(.notConnectedToInternet)
        model.saveGoal(seconds: 16_200)
        XCTAssertEqual(model.goalSeconds, 16_200)
        await model.goalSend?.value
        XCTAssertTrue(backend.goalCalls.isEmpty, "offline: nothing sent, still pending")
        backend.goalError = nil
        await model.sendGoalIfPending()
        XCTAssertEqual(backend.goalCalls.map(\.raceId), ["chicago-marathon-2026"])
        XCTAssertEqual(backend.goalCalls.first?.goalSeconds, 16_200)
        await model.sendGoalIfPending()
        XCTAssertEqual(backend.goalCalls.count, 1, "sent once")
        model.saveGoal(seconds: 5)  // outside the accepted range
        XCTAssertEqual(model.goalSeconds, 16_200)
    }

    func testAnAccountSwitchStartsTheFirstSyncOverOnTheNewAccount() async throws {
        let backend = StubBackend()
        let box = Outbox(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = AppModel(backend: backend, source: ScriptedSource(), outbox: box, scope: .empty, telemetry: NoTelemetry(), defaults: UserDefaults(suiteName: "switch-\(UUID().uuidString)")!)
        await model.syncNow()
        try box.update { $0.detailsDone = ["W1"] }
        let registered = backend.registerCalls
        // The old account was removed on the server; the app fell back to a new one. What the outbox says is uploaded went to the old account.
        backend.uid = "stub-user-2"
        await model.syncNow()
        XCTAssertGreaterThan(backend.registerCalls, registered, "the new account is registered")
        XCTAssertTrue(box.state.detailsDone.isEmpty, "everything is uploaded again to the new account")
        // The same account again leaves the outbox alone.
        try box.update { $0.detailsDone = ["W2"] }
        await model.syncNow()
        XCTAssertEqual(box.state.detailsDone, ["W2"])
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

    func testAppleLinkOnWelcomeCanRestoreAnExistingAccount() async {
        let backend = StubBackend()
        let model = makeModel(backend)
        await model.linkAppleAccount(AppleSignInResult(idToken: "test", nonce: "nonce", authorizationCode: "code"))
        XCTAssertEqual(backend.appleRestoreChoices, [true])
        XCTAssertTrue(model.appleAccountLinked)
        XCTAssertEqual(model.phase, .welcome, "linking does not bypass Health permission onboarding")
        XCTAssertFalse(model.busy)
    }

    func testAppleLinkNeverRestoresOverAnOnboardedDataset() async {
        let backend = StubBackend()
        let model = makeModel(backend)
        model.phase = .home
        await model.linkAppleAccount(AppleSignInResult(idToken: "test", nonce: "nonce", authorizationCode: "code"))
        XCTAssertEqual(backend.appleRestoreChoices, [false])
        XCTAssertTrue(model.appleAccountLinked)
        XCTAssertEqual(model.phase, .home)
    }

    func testAppleAccountConflictKeepsTheCurrentIdentityAndShowsRecovery() async {
        let backend = StubBackend()
        backend.appleLinkError = AppleSignInError.accountConflict
        let model = makeModel(backend)
        await model.linkAppleAccount(AppleSignInResult(idToken: "test", nonce: "nonce", authorizationCode: "code"))
        XCTAssertFalse(model.appleAccountLinked)
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertTrue(model.errorMessage?.contains("workouts have not changed") == true)
        XCTAssertFalse(model.busy)
    }

    func testAppleLinkCannotStartWhileAnotherActionIsBusy() async {
        let backend = StubBackend()
        let model = makeModel(backend)
        model.busy = true
        await model.linkAppleAccount(AppleSignInResult(idToken: "test", nonce: "nonce", authorizationCode: "code"))
        XCTAssertTrue(backend.appleRestoreChoices.isEmpty)
        XCTAssertTrue(model.busy)
    }

    func testSyncRecoversThePersistedAppleAccountState() async {
        let backend = StubBackend()
        backend.appleLinked = true
        let model = makeModel(backend)
        await model.syncNow()
        XCTAssertTrue(model.appleAccountLinked)
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
        XCTAssertEqual(model.phase, .account)
        await model.deleteAllData()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertFalse(model.busy, "the welcome button must not stay disabled after deletion")
        await model.connectHealth()
        XCTAssertEqual(model.phase, .account)
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
        XCTAssertEqual(model.phase, .account)
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

    func testDefaultCategoriesAreAppliedOnTheFirstSyncAndTheServerIsTold() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var scope = SyncScope.empty
        scope.categories = [CoverageCategory(id: "core", label: "Core", default: true), CoverageCategory(id: "devices", label: "Devices", default: true), CoverageCategory(id: "cycle", label: "Cycle", default: nil)]
        let backend = StubBackend()
        let model = AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), scope: scope, telemetry: NoTelemetry(), defaults: UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!)
        XCTAssertTrue(model.isEnabled("devices"), "default groups are on from the start")
        XCTAssertFalse(model.isEnabled("cycle"), "groups without a default stay off")
        await model.syncNow()
        XCTAssertEqual(backend.categoryCalls.first, ["core", "devices"])
        let calls = backend.categoryCalls.count
        await model.syncNow()
        XCTAssertEqual(backend.categoryCalls.count, calls, "the defaults are applied once")
    }

    func testConnectGoesToTheAccountPageAndSyncStartsRightAway() async throws {
        let backend = StubBackend()
        let defaults = UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: defaults)
        await model.connectHealth()
        XCTAssertEqual(model.phase, .account)
        XCTAssertEqual(model.connectStage, "")
        XCTAssertTrue(defaults.bool(forKey: AppModel.pendingAccountKey))
        XCTAssertEqual(defaults.string(forKey: AppModel.onboardingUidKey), "stub-user")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(backend.categoryCalls.count, 0)
        // Reopening before signing in lands on the account page again.
        let reopened = AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: defaults)
        XCTAssertEqual(reopened.phase, .account)
    }

    func testProductMilestonesAndSyncOutcomeAreReportedWithoutHealthValues() async throws {
        let backend = StubBackend()
        let model = makeModel(backend)
        await model.connectHealth()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(backend.productEvents.contains { $0.name == "health_connect_started" })
        XCTAssertTrue(backend.productEvents.contains { $0.name == "health_connected" })
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(backend.productEvents.contains { $0.name == "apple_linked" })
        await model.syncNow()
        try await Task.sleep(for: .milliseconds(50))
        let sync = backend.productEvents.last { $0.name == "sync_finished" }
        XCTAssertEqual(sync?.outcome, "success")
        XCTAssertNotNil(sync?.durationMs)
    }

    func testSigningInOnTheAccountPageFinishesOnboarding() async {
        let backend = StubBackend()
        let defaults = UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: defaults)
        await model.connectHealth()
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        XCTAssertEqual(model.phase, .home)
        XCTAssertTrue(model.appleAccountLinked)
        XCTAssertEqual(backend.freshAccountChoices, ["stub-user"], "only the account created by this onboarding may be replaced")
        XCTAssertFalse(defaults.bool(forKey: AppModel.pendingAccountKey))
        XCTAssertNil(defaults.string(forKey: AppModel.onboardingUidKey))
        let reopened = AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: defaults)
        XCTAssertEqual(reopened.phase, .home)
    }

    func testAccountPageFailureStaysOnTheAccountPage() async {
        let backend = StubBackend()
        let model = makeModel(backend)
        await model.connectHealth()
        backend.appleLinkError = AppleSignInError.accountConflict
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        XCTAssertEqual(model.phase, .account, "sign-in is required")
        XCTAssertNotNil(model.errorMessage)
    }

    func testSignInFailureShowsTheErrorCodeButAConflictDoesNot() async {
        let backend = StubBackend()
        let model = makeModel(backend)
        await model.connectHealth()
        backend.appleLinkError = NSError(domain: "FIRAuthErrorDomain", code: 17015)
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        XCTAssertTrue(model.errorMessage?.contains("(sign-in: FIRAuthErrorDomain 17015)") == true)
        model.errorMessage = nil
        backend.appleLinkError = AppleSignInError.accountConflict
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        XCTAssertFalse(model.errorMessage?.contains("(sign-in:") == true)
    }

    func testRestoringAnExistingAccountStartsTheSyncOverAndFinishesOnboarding() async {
        let backend = StubBackend()
        backend.restoredUid = "restored-user"
        let model = makeModel(backend)
        await model.connectHealth()
        let callsBefore = backend.categoryCalls.count
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        XCTAssertEqual(model.phase, .home)
        XCTAssertGreaterThan(backend.categoryCalls.count, callsBefore, "the restored account is told which data groups are on")
        XCTAssertFalse(model.busy)
    }

    func testSigningInDoesNotWaitForARunningSyncToStop() async throws {
        let source = StubbornSource()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(backend: StubBackend(), source: source, outbox: Outbox(root: root), scope: .empty, telemetry: NoTelemetry(), defaults: UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!)
        await model.connectHealth()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(source.reading, "the sync is busy reading Health, and ignores cancellation for a few seconds")
        let started = Date()
        await model.linkAppleAccount(AppleSignInResult(idToken: "t", nonce: "n", authorizationCode: "c"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "sign-in must not wait for the sync")
        XCTAssertEqual(model.phase, .home)
        XCTAssertFalse(model.busy)
    }

    func testMedicationsStartOffSoFirstRunHasOnePermissionSheet() {
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        XCTAssertNotEqual(scope.categories.first { $0.id == "medications" }?.default, true)
        XCTAssertEqual(scope.categories.first { $0.id == "cycle" }?.default, true, "other groups keep their defaults")
    }

    func testMedicationSheetIsNotPartOfTheMainPermissionRequest() async throws {
        let source = MedicationSource()
        var scope = SyncScope.empty
        scope.categories = [CoverageCategory(id: "core", label: "Core", default: true), CoverageCategory(id: "medications", label: "Medications", default: true)]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(backend: StubBackend(), source: source, outbox: Outbox(root: root), scope: scope, telemetry: NoTelemetry(), defaults: UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!)
        await model.connectHealth()
        XCTAssertEqual(model.phase, .account, "onboarding moves on once the main permission sheet is answered")
        XCTAssertTrue(source.mainRequested)
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
        XCTAssertEqual(model.connectStage, "", "progress is silent; only a stall is shown")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.connectStage, AppModel.permissionStallHint)
        XCTAssertTrue(model.busy)
        connecting.cancel()
    }
}

/// Source that records the medication sheet separately from the main request, and never answers the former.
final class MedicationSource: HealthSource, @unchecked Sendable {
    private(set) var mainRequested = false
    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws { mainRequested = true }
    func requestMedicationAuthorization() async { try? await Task.sleep(for: .seconds(3600)) }
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

/// Source whose reads ignore cancellation for a few seconds (a sync that is slow to stop).
final class StubbornSource: HealthSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reading = false
    var reading: Bool { lock.withLock { _reading } }
    var isAvailable: Bool { true }
    func requestAuthorization(scope: SyncScope) async throws {}
    private func block() {
        lock.withLock { _reading = true }
        let end = Date().addingTimeInterval(4)
        while Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    }
    func workouts(from: Date, to: Date) async throws -> [Record] { block(); return [] }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        block()
        return AnchoredPage(records: [], newAnchor: nil, objectCount: 0)
    }
    func workoutIndex() async throws -> [WorkoutRef] { block(); return [] }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? { nil }
    func dailyContext(from: Date, to: Date) async throws -> [Record] { block(); return [] }
    func earliestDailyDate() async throws -> Date? { nil }
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
}
