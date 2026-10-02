import Foundation

/// Which data categories the user has switched on ("core" is always on). Read from background tasks as well as the
/// UI, so it is thread-safe and persisted.
final class ConsentStore: @unchecked Sendable {
    static let key = "enabledCategories"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var ids: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? []).union(["core"])
    }

    var enabled: Set<String> { lock.withLock { ids } }

    /// True once the user (or the server's record, after a reinstall) has set a choice.
    var hasChoice: Bool { defaults.object(forKey: Self.key) != nil }

    func set(_ new: Set<String>) {
        let all = new.union(["core"])
        lock.withLock { ids = all }
        defaults.set(all.sorted(), forKey: Self.key)
    }

    func isOn(_ id: String) -> Bool { enabled.contains(id) }
}
