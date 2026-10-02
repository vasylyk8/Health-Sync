import Foundation

/// Whether the background refresh task has a handler registered in this process. iOS crashes the app if a request is
/// submitted for a task without a handler, so scheduling checks this first (UI tests and previews register nothing).
final class BackgroundTaskRegistry: @unchecked Sendable {
    static let shared = BackgroundTaskRegistry()

    private let lock = NSLock()
    private var registered = false

    var refreshRegistered: Bool {
        get { lock.withLock { registered } }
        set { lock.withLock { registered = newValue } }
    }
}
