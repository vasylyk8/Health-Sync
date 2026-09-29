import XCTest
@testable import HealthSync

/// Backend whose sign-in can be made to fail (offline, server error).
final class StubBackend: Backend, @unchecked Sendable {
    var signInError: Error?
    func signIn() async throws -> String {
        if let signInError { throw signInError }
        return "stub-user"
    }
    func registerDevice(timeZone: String) async throws {}
    func createLink(provider: String) async throws -> String { "https://example.test/mcp/\(provider)" }
    func disconnect(provider: String) async throws {}
    func deleteAllData() async throws {}
    func status() async throws -> ServerStatus { .empty }
    func signOut() async {}
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {}
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(_ backend: StubBackend) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!
        return AppModel(backend: backend, source: ScriptedSource(), outbox: Outbox(root: root), types: [], telemetry: NoTelemetry(), defaults: defaults)
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
}
