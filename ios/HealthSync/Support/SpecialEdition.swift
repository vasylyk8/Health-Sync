import SwiftUI

/// A special edition of Home: a medal for one race, shown on Home from the moment the first upload finishes
/// until a few days after race day, with the runner's expected finish time stored and shared with their AI.
///
/// To make the next one: add a value like `chicago2026` below, put it first in `all`, and ship. Nothing else
/// needs to change: the medal, the time picker, the saved goal, the server field and the "back to normal" date
/// all follow from this one description.
struct SpecialEdition {
    /// Stable key for the saved goal and for the server (lower case letters, digits and dashes). Never reuse one.
    let id: String
    /// Sent to the AI with the goal ("Chicago Marathon").
    let raceName: String
    /// Race day, local calendar date.
    let raceDay: DateComponents
    /// Last day the medal shows; from the next day on, Home goes back to the plain big-number look.
    let lastDay: DateComponents
    /// The two lines on the rim of the medal (upper, lower), upper case.
    let medalTop: String
    let medalBottom: String
    /// Under the medal until a goal is saved.
    let caption: String
    /// Hours the picker offers, and where it starts.
    let hours: ClosedRange<Int>
    let defaultGoal: (hours: Int, minutes: Int)
    /// The picture in the middle of the medal, drawn to fill a 342 x 240 box (Chicago: stars over the skyline).
    let art: @MainActor () -> AnyView

    /// "2026-10-11", as the server stores it.
    var raceDate: String {
        String(format: "%04d-%02d-%02d", raceDay.year ?? 0, raceDay.month ?? 0, raceDay.day ?? 0)
    }

    /// What the server accepts as a finish time: ten minutes to a day.
    static let secondsRange = 600...86_400

    func goalSeconds(hours h: Int, minutes m: Int) -> Int { h * 3600 + m * 60 }
    var defaultGoalSeconds: Int { goalSeconds(hours: defaultGoal.hours, minutes: defaultGoal.minutes) }

    /// "4:30:00"
    static func timeText(seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    // MARK: The editions

    static let chicago2026 = SpecialEdition(
        id: "chicago-marathon-2026",
        raceName: "Chicago Marathon",
        raceDay: DateComponents(year: 2026, month: 10, day: 11),
        lastDay: DateComponents(year: 2026, month: 10, day: 17),
        medalTop: "CHICAGO MARATHON",
        medalBottom: "OCT 11, 2026",
        caption: "GOOD LUCK, CHICAGO",
        hours: 2...8,
        defaultGoal: (4, 30),
        art: { AnyView(ChicagoMarathonArt(course: false)) })

    /// Newest first. Only the first one that is inside its window shows.
    static let all: [SpecialEdition] = [chicago2026]

    /// The edition to show now, if any. Launch arguments force it on (`-specialEdition`) or off (`-noSpecialEdition`) for UI tests.
    static func active(now: Date = Date(), calendar: Calendar = .current, arguments: [String] = ProcessInfo.processInfo.arguments,
                       editions: [SpecialEdition] = SpecialEdition.all) -> SpecialEdition? {
        if arguments.contains("-noSpecialEdition") { return nil }
        if arguments.contains("-specialEdition") { return editions.first }
        return editions.first { $0.isShowing(now: now, calendar: calendar) }
    }

    func isShowing(now: Date, calendar: Calendar = .current) -> Bool {
        guard let last = calendar.date(from: lastDay), let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return false }
        return now < end
    }
}

/// The goal a runner entered, kept on the phone (and sent to the server, retried until it arrives).
struct RaceGoalStore {
    let defaults: UserDefaults

    private func goalKey(_ id: String) -> String { "edition.goalSeconds.\(id)" }
    private func pendingKey(_ id: String) -> String { "edition.goalPending.\(id)" }

    func goal(for id: String) -> Int? {
        defaults.object(forKey: goalKey(id)) == nil ? nil : defaults.integer(forKey: goalKey(id))
    }

    /// Saves the goal and marks it as not yet on the server.
    func save(_ seconds: Int, for id: String) {
        defaults.set(seconds, forKey: goalKey(id))
        defaults.set(true, forKey: pendingKey(id))
    }

    func isPending(_ id: String) -> Bool { defaults.bool(forKey: pendingKey(id)) }
    func markSent(_ id: String) { defaults.set(false, forKey: pendingKey(id)) }

    func clear(editions: [SpecialEdition]) {
        for e in editions {
            defaults.removeObject(forKey: goalKey(e.id))
            defaults.removeObject(forKey: pendingKey(e.id))
        }
    }
}
