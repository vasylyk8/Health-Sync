import Foundation

/// What Home says once the first sync is done.
///
/// "Up to date" is a claim: the last check finished, found nothing left to send, and nothing has failed since, so a workout that
/// reached the iPhone a minute or more ago can be found by the AI. While a check runs after a long gap the claim is not
/// known to hold, so Home says "Checking for new data…" instead and shows when the last check was.
enum SyncStatus {
    /// A check that finished this recently still counts while the next one runs (pulling down again right after a check).
    static let recently: TimeInterval = 120

    struct Lines: Equatable {
        var title: String
        var detail: String
    }

    static func lines(lastChecked: Date?, checking: Bool, failed: Bool, now: Date) -> Lines {
        if checking {
            if let lastChecked, now.timeIntervalSince(lastChecked) < recently {
                return Lines(title: Copy.Home.upToDate, detail: Copy.Home.checking)
            }
            return Lines(title: Copy.Home.checkingForNewData, detail: lastChecked.map { Copy.Home.lastChecked(ago($0, now: now)) } ?? Copy.Home.keepOpen)
        }
        if failed {
            // Offline or paused: nothing is promised, but the last time it did check is still true.
            return Lines(title: Copy.Home.waitingToSync, detail: lastChecked.map { Copy.Home.lastChecked(ago($0, now: now)) } ?? Copy.Home.notCheckedYet)
        }
        guard let lastChecked else {
            // Before the first check of this version has finished.
            return Lines(title: Copy.Home.checkingForNewData, detail: Copy.Home.keepOpen)
        }
        return Lines(title: Copy.Home.upToDate, detail: Copy.Home.checked(ago(lastChecked, now: now)))
    }

    /// "just now", "5 min ago", "2 hr ago", "3 days ago": coarse on purpose, since the app re-checks every time it opens.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return Copy.Home.justNow }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) hr ago" }
        return "\(hours / 24) days ago"
    }
}
