import Foundation

/// Which data categories the user has switched on ("core" is always on). Read from background tasks as well as the
/// UI, so it is thread-safe and persisted.
final class ConsentStore: @unchecked Sendable {
    static let key = "enabledCategories"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var ids: Set<String>

    /// `fallback`: the categories that are on until the user makes a choice (the "default" ones in coverage.json).
    init(defaults: UserDefaults, fallback: Set<String> = []) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? Array(fallback)).union(["core"])
    }

    var enabled: Set<String> { lock.withLock { ids } }

    /// True once a choice (the defaults, or the user's own) has been stored on this phone.
    var hasChoice: Bool { defaults.object(forKey: Self.key) != nil }

    func set(_ new: Set<String>) {
        let all = new.union(["core"])
        lock.withLock { ids = all }
        defaults.set(all.sorted(), forKey: Self.key)
    }

    /// Stores the current set as the choice (so the defaults become the user's choice and can be changed).
    func persist() { set(enabled) }

    func isOn(_ id: String) -> Bool { enabled.contains(id) }
}
