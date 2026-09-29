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
        if let user = Auth.auth().currentUser {
            do {
                _ = try await user.getIDToken()
                return user.uid
            } catch let error as NSError where error.domain == AuthErrorDomain && Self.deadAccountCodes.contains(error.code) {
                // The account was removed on the server (for example a deletion finished after the app
                // was reinstalled). Start over with a new anonymous account instead of failing forever.
                try? Auth.auth().signOut()
            }
        }
        return try await Auth.auth().signInAnonymously().user.uid
    }

    /// FirebaseAuth error codes meaning the cached user no longer exists or can no longer be used:
    /// userDisabled 17005, userNotFound 17011, invalidUserToken 17017, userTokenExpired 17021.
    private static let deadAccountCodes: Set<Int> = [17005, 17011, 17017, 17021]

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

    func batchExists(batchId: String) async throws -> Bool {
        let data = try await call("batchExists", ["batchId": batchId])
        return (data as? [String: Any])?["exists"] as? Bool ?? false
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
        let attempts = UploadAttempts()
        let retried = attempts.begin(batchId)
        do {
            _ = try await ref.putDataAsync(gz, metadata: meta)
            attempts.finish(batchId)
        } catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.unauthorized.rawValue {
            // Storage rules only allow creating an object once, so "unauthorized" is either a retry of an
            // upload that already arrived (fine) or a real rejection (rules, App Check), which must not be
            // mistaken for success or the sync anchor would move past data the server never received.
            attempts.finish(batchId)
            switch try? await batchExists(batchId: batchId) {
            case .some(true): return
            case .some(false): throw error
            case .none:
                // The server could not be asked (offline, or an older server): only trust an interrupted retry.
                if retried { return }
                throw error
            }
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
