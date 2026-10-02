import Foundation

/// Server-side status shown on the home screen. Everything comes from published (queryable)
/// state, so "synced" always means the AI can already see it.
struct ServerStatus: Decodable, Equatable, Sendable {
    var registered: Bool
    var deleting: Bool
    var setUp: [String: Bool]
    var lastVisibleAt: Double?
    var historySyncedBackTo: Double?
    var typesWithData: Int
    /// Data categories the server accepts (older servers do not report this).
    var categories: [String]? = nil

    static let empty = ServerStatus(registered: false, deleting: false, setUp: [:], lastVisibleAt: nil, historySyncedBackTo: nil, typesWithData: 0)

    var lastVisibleDate: Date? { lastVisibleAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var historyStart: Date? { historySyncedBackTo.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

protocol Backend: Uploader {
    /// Signs in (anonymously) if needed and returns the user id.
    func signIn() async throws -> String
    func registerDevice(timeZone: String) async throws
    func createLink(provider: String) async throws -> String
    func disconnect(provider: String) async throws
    func deleteAllData() async throws
    /// Tells the server which data categories are switched on; data of a category switched off is deleted there.
    func setCategories(_ ids: [String]) async throws
    func status() async throws -> ServerStatus
    /// Whether the server already has this upload batch (processed, or waiting to be processed).
    func batchExists(batchId: String) async throws -> Bool
    func signOut() async
}

enum BackendError: LocalizedError {
    case notConfigured, notSignedIn, badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "The app is not configured yet."
        case .notSignedIn: return "Could not sign in. Check your internet connection."
        case .badResponse: return "Unexpected response from the server."
        }
    }
}
