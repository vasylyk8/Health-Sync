import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import FirebaseStorage
import Foundation

/// Production backend: Firebase Auth (anonymous), callable functions and Storage uploads.
final class FirebaseBackend: Backend, @unchecked Sendable {
    static let region = "europe-west1"

    /// Configures Firebase if GoogleService-Info.plist is bundled. Returns false otherwise.
    static func configure() -> Bool {
        guard FirebaseApp.app() == nil else { return true }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return false }
        AppCheck.setAppCheckProviderFactory(AppCheckFactory())
        FirebaseApp.configure()
        return true
    }

    private var functions: Functions { Functions.functions(region: Self.region) }

    func signIn() async throws -> String {
        if let user = Auth.auth().currentUser { return user.uid }
        return try await Auth.auth().signInAnonymously().user.uid
    }

    func registerDevice(timeZone: String) async throws {
        _ = try await call("registerDevice", ["tz": timeZone])
    }

    func createLink(provider: String) async throws -> String {
        let data = try await call("createConnectorLink", ["provider": provider])
        guard let url = (data as? [String: Any])?["url"] as? String else { throw BackendError.badResponse }
        return url
    }

    func disconnect(provider: String) async throws {
        _ = try await call("disconnectProvider", ["provider": provider])
    }

    func deleteAllData() async throws {
        _ = try await call("deleteAllData", [:])
    }

    func status() async throws -> ServerStatus {
        let data = try await call("getStatus", [:])
        let json = try JSONSerialization.data(withJSONObject: data ?? [:])
        return try JSONDecoder().decode(ServerStatus.self, from: json)
    }

    func signOut() async {
        try? Auth.auth().signOut()
    }

    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { throw BackendError.notSignedIn }
        guard let projectId = FirebaseApp.app()?.options.projectID else { throw BackendError.notConfigured }
        let ref = Storage.storage(url: "gs://\(projectId)-incoming").reference(withPath: "incoming/\(uid)/\(batchId).ndjson.gz")
        let meta = StorageMetadata()
        meta.contentType = "application/gzip"
        meta.customMetadata = ["schema": "1", "sha256": sha256]
        do {
            _ = try await ref.putDataAsync(gz, metadata: meta)
        } catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.unauthorized.rawValue {
            // Rules allow create-only: an "unauthorized" retry after a successful upload means
            // the object already exists, i.e. the server already has this batch.
            return
        }
    }

    private func call(_ name: String, _ payload: [String: Any]) async throws -> Any? {
        _ = try await signIn()
        return try await functions.httpsCallable(name).call(payload).data
    }
}

private final class AppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator) || DEBUG
        return AppCheckDebugProvider(app: app)
        #else
        return AppAttestProvider(app: app)
        #endif
    }
}
