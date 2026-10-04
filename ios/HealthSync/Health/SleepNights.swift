import Foundation

struct SleepSegment: Equatable, Sendable {
    var start: Date
    var end: Date
    /// HKCategoryValueSleepAnalysis raw value.
    var value: Int
    var source: String
}

/// Turns raw sleep segments into one summary per night, dated by the morning the night ends.
/// Mirrors what the app used to leave to the server: overlapping sources are never double counted.
enum SleepNights {
    static let inBed = 0, unspecified = 1, awake = 2, core = 3, deep = 4, rem = 5
    static let asleepValues: Set<Int> = [unspecified, core, deep, rem]

    /// Local date (yyyy-MM-dd) a segment belongs to: the day it ends, except that segments ending
    /// at or after 18:00 count for the next day (an evening nap starts tomorrow's night).
    static func nightKey(_ end: Date, calendar: Calendar) -> String {
        let shifted = end.addingTimeInterval(6 * 3600)
        return dayKey(shifted, calendar: calendar)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Total minutes covered by the union of the intervals.
    static func unionMinutes(_ intervals: [(Date, Date)]) -> Double {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for iv in sorted {
            if let c = current, iv.0 <= c.1 {
                current = (c.0, max(c.1, iv.1))
            } else {
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                current = iv
            }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total / 60
    }

    private static func minutes(_ segs: [SleepSegment], _ values: Set<Int>) -> Double {
        unionMinutes(segs.filter { values.contains($0.value) }.map { ($0.start, $0.end) })
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// The main overnight episode, rather than the outer span of an evening nap, overnight sleep and afternoon nap.
    /// Keep interruptions shorter than three hours in the same episode (including the observed 2.5-hour awakening).
    /// Explicit awake segments bridge even longer interruptions. Prefer episodes beginning before 06:00 of this night;
    /// if there is only daytime sleep, use its longest episode. Duration totals continue to include every episode.
    private static func mainSleep(_ segments: [SleepSegment], calendar: Calendar) -> [SleepSegment] {
        let ordered = segments.sorted { $0.start < $1.start }
        var episodes: [[SleepSegment]] = []
        var end = Date.distantPast
        for segment in ordered {
            if segment.start.timeIntervalSince(end) >= 3 * 3600 {
                episodes.append([segment])
                end = segment.end
            } else {
                episodes[episodes.count - 1].append(segment)
                end = max(end, segment.end)
            }
        }
        let sleeps = episodes.filter { minutes($0, asleepValues) > 0 }
        guard let first = sleeps.first?.first else { return [] }
        let night = first.end.addingTimeInterval(6 * 3600)
        let morning = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: night)!
        let overnight = sleeps.filter { $0.first!.start < morning }
        return (overnight.isEmpty ? sleeps : overnight).max {
            let a = minutes($0, asleepValues), b = minutes($1, asleepValues)
            return a == b ? $0.first!.start > $1.first!.start : a < b
        } ?? []
    }

    /// night date -> metrics (sleepAsleepMin, sleepInBedMin, sleepCoreMin, sleepDeepMin, sleepRemMin,
    /// sleepAwakeMin, sleepBedtime, sleepWakeTime).
    static func nights(_ segments: [SleepSegment], calendar: Calendar) -> [String: [String: RecordValue]] {
        var byNight: [String: [SleepSegment]] = [:]
        for s in segments where s.end > s.start { byNight[nightKey(s.end, calendar: calendar), default: []].append(s) }

        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"

        var out: [String: [String: RecordValue]] = [:]
        for (night, segs) in byNight {
            // One source per night for stages and time asleep: the one with the most staged sleep
            // (Watch over phone), then the most unstaged sleep.
            let bySource = Dictionary(grouping: segs, by: \.source)
            let chosen = bySource.max { a, b in
                let sa = (minutes(a.value, [core, deep, rem]), minutes(a.value, [unspecified]), a.key)
                let sb = (minutes(b.value, [core, deep, rem]), minutes(b.value, [unspecified]), b.key)
                return sa < sb
            }?.value ?? []
            var m: [String: RecordValue] = [:]
            let asleep = minutes(chosen, asleepValues)
            let staged = minutes(chosen, [core, deep, rem])
            if asleep > 0 { m["sleepAsleepMin"] = .double(round1(asleep)) }
            if staged > 0 {
                m["sleepCoreMin"] = .double(round1(minutes(chosen, [core])))
                m["sleepDeepMin"] = .double(round1(minutes(chosen, [deep])))
                m["sleepRemMin"] = .double(round1(minutes(chosen, [rem])))
            }
            let awakeMin = minutes(chosen, [awake])
            if awakeMin > 0 { m["sleepAwakeMin"] = .double(round1(awakeMin)) }

            // In-bed time may come from another source (the phone or a sleep app). Without one, the time asleep or awake:
            // first to last segment would count the day between an evening nap and an afternoon nap (24 h on a real night).
            let inBedMin = minutes(segs, [inBed])
            let asleepOrAwake = chosen.filter { asleepValues.contains($0.value) || $0.value == awake }
            let inBedTotal = inBedMin > 0 ? inBedMin : minutes(asleepOrAwake, asleepValues.union([awake]))
            if inBedTotal > 0 { m["sleepInBedMin"] = .double(round1(inBedTotal)) }

            let main = mainSleep(asleepOrAwake, calendar: calendar)
            if let firstSleep = main.filter({ asleepValues.contains($0.value) }).map(\.start).min(), let start = main.map(\.start).min() {
                // An in-bed interval containing the beginning of the main sleep can supply bedtime; unrelated naps and
                // the old phone's near-instant in-bed records hours before sleep cannot move it.
                let beds = segs.filter { $0.value == inBed && $0.start <= firstSleep && $0.end > firstSleep }.map(\.start)
                let bed = min(start, beds.min() ?? start)
                m["sleepBedtime"] = .string(clock.string(from: bed))
            }
            if let wake = main.filter({ asleepValues.contains($0.value) }).map(\.end).max() {
                m["sleepWakeTime"] = .string(clock.string(from: wake))
            }
            if !m.isEmpty { out[night] = m }
        }
        return out
    }
}
