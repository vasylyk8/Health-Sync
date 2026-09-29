import Foundation

/// Remembers which batches an upload was already started for.
///
/// Storage rules only allow creating an object, so re-uploading a batch that already arrived is
/// rejected as `unauthorized`. That is harmless after an interrupted attempt, but an `unauthorized`
/// on the very first attempt is a real rejection (rules, App Check) and must not be mistaken for
/// "already uploaded", or the sync anchor would move past data the server never received.
struct UploadAttempts: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private static let limit = 500

    init(defaults: UserDefaults = .standard, key: String = "uploadAttempts") {
        self.defaults = defaults
        self.key = key
    }

    /// Records that an upload of `batchId` is starting. Returns true if an earlier attempt was
    /// started and never reached a definite outcome (a retry).
    func begin(_ batchId: String) -> Bool {
        var ids = defaults.stringArray(forKey: key) ?? []
        let retried = ids.contains(batchId)
        if !retried {
            ids.append(batchId)
            if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
            defaults.set(ids, forKey: key)
        }
        return retried
    }

    /// The attempt reached a definite outcome (accepted, or rejected on a first attempt).
    func finish(_ batchId: String) {
        var ids = defaults.stringArray(forKey: key) ?? []
        ids.removeAll { $0 == batchId }
        defaults.set(ids, forKey: key)
    }
}
