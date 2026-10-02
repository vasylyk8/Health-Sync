import Foundation

/// Running totals of what has been read from Apple Health and sent, shown as the rotating big
/// numbers on Home. Everything is derived from the batch records the engine already builds, and
/// stored per workout / per day so a record that is read again (a weekly full pass, a retry)
/// replaces its earlier values instead of being added twice.
struct SyncStatsSnapshot: Equatable, Sendable {
    /// Changes whenever any total changes (lets the UI notice updates cheaply).
    var version = 0
    /// True when these totals started after part of the history was already uploaded (an update of an
    /// app that had synced before). Totals built from workout details are then too low and are not shown.
    var partial = false
    /// Workouts whose summary is known.
    var workouts = 0
    /// Heart rate readings in the raw data of workouts that are uploaded.
    var hrReadings = 0
    /// GPS points in the routes of workouts that are uploaded.
    var gpsPoints = 0
    var steps = 0.0
    var walkRunMeters = 0.0
    var cyclingMeters = 0.0
    var swimMeters = 0.0
    var sleepMinutes = 0.0
    var activeKcal = 0.0
    /// Days with a heart rate variability value.
    var hrvDays = 0
    var trainingSeconds = 0.0
    /// Ascent recorded by Apple Watch workouts that carry it.
    var climbedMeters = 0.0
    /// Estimated beats during workouts: average heart rate times duration.
    var workoutBeats = 0.0
    var workoutDays = 0
    var workoutTypes = 0
}

extension RecordValue {
    var statNumber: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    var statText: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var statObject: [String: RecordValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

final class SyncStatsStore: @unchecked Sendable {
    struct Day: Codable, Equatable {
        var steps = 0.0
        var walkRun = 0.0
        var cycling = 0.0
        var swim = 0.0
        var sleep = 0.0
        var kcal = 0.0
        var hrv = false
    }

    struct Workout: Codable, Equatable {
        var day = ""
        var type = ""
        var seconds = 0.0
        var climb = 0.0
        var beats = 0.0
    }

    private struct Saved: Codable {
        var days: [String: Day] = [:]
        var workouts: [String: Workout] = [:]
        var heartRate: [String: Int] = [:]
        var gps: [String: Int] = [:]
        /// True when counting began together with the very first sync. Missing in files written by earlier builds.
        var complete: Bool? = true
        /// Set once a full read of the daily rows has filled `days` for an install that synced before.
        var dailyBackfilled: Bool?
    }

    private let lock = NSLock()
    private let url: URL?
    private let calendar: Calendar
    private var saved = Saved()
    private var versionValue = 0
    private var dirty = false
    private var writeScheduled = false
    private let writeQueue = DispatchQueue(label: "app.healthsync.stats", qos: .utility)

    /// `url` is where the totals are kept between launches (nil: memory only). `historyExists` says that
    /// uploads happened before there was a stats file, so a store that starts empty is only partial.
    init(url: URL?, calendar: Calendar = .current, historyExists: Bool = false) {
        self.url = url
        self.calendar = calendar
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
            versionValue = 1
        } else if historyExists {
            saved.complete = false
        }
    }

    private var isPartial: Bool { saved.complete != true }

    /// An install that synced before needs one full read of the daily rows to fill the daily totals.
    var needsDailyBackfill: Bool { lock.withLock { isPartial && saved.dailyBackfilled != true } }

    func markDailyBackfilled() {
        mutate { s in
            guard s.dailyBackfilled != true else { return false }
            s.dailyBackfilled = true
            return true
        }
    }

    var version: Int { lock.withLock { versionValue } }

    // MARK: Adding what was read

    /// Workout summaries (`w` records) and deletions (`d` records).
    func addWorkoutSummaries(_ records: [Record]) {
        guard !records.isEmpty else { return }
        mutate { s in
            var changed = false
            for r in records {
                switch r["k"]?.statText {
                case "w":
                    guard let id = r["id"]?.statText else { continue }
                    var w = Workout()
                    if let ms = r["s"]?.statNumber { w.day = self.dayKey(Date(timeIntervalSince1970: ms / 1000)) }
                    w.type = r["actName"]?.statText ?? ""
                    w.seconds = max(0, r["dur"]?.statNumber ?? 0)
                    if let text = r["md"]?.statObject?["HKElevationAscended"]?.statText, let meters = Self.meters(from: text) {
                        w.climb = max(0, meters)
                    }
                    if let avg = r["hrAvg"]?.statNumber, avg > 0 { w.beats = avg * w.seconds / 60 }
                    if s.workouts[id] != w {
                        s.workouts[id] = w
                        changed = true
                    }
                case "d":
                    guard let id = r["id"]?.statText else { continue }
                    if s.workouts.removeValue(forKey: id) != nil { changed = true }
                    if s.heartRate.removeValue(forKey: id) != nil { changed = true }
                    if s.gps.removeValue(forKey: id) != nil { changed = true }
                default:
                    continue
                }
            }
            return changed
        }
    }

    /// Daily context rows (`day` records).
    func addDays(_ records: [Record]) {
        guard !records.isEmpty else { return }
        mutate { s in
            var changed = false
            for r in records where r["k"]?.statText == "day" {
                guard let day = r["day"]?.statText, let m = r["m"]?.statObject else { continue }
                var d = Day()
                d.steps = m["steps"]?.statNumber ?? 0
                d.walkRun = m["walkRunDistanceM"]?.statNumber ?? 0
                d.cycling = m["cyclingDistanceM"]?.statNumber ?? 0
                d.swim = m["swimDistanceM"]?.statNumber ?? 0
                d.sleep = m["sleepAsleepMin"]?.statNumber ?? 0
                d.kcal = m["activeKcal"]?.statNumber ?? 0
                d.hrv = m["hrv"]?.statNumber != nil
                if s.days[day] != d {
                    s.days[day] = d
                    changed = true
                }
            }
            return changed
        }
    }

    /// Point counts of one workout's raw data (from the `wd` marker).
    func setDetail(workoutId: String, heartRate: Int, gpsPoints: Int) {
        mutate { s in
            var changed = false
            if heartRate > 0, s.heartRate[workoutId] != heartRate {
                s.heartRate[workoutId] = heartRate
                changed = true
            }
            if gpsPoints > 0, s.gps[workoutId] != gpsPoints {
                s.gps[workoutId] = gpsPoints
                changed = true
            }
            return changed
        }
    }

    // MARK: Reading

    func snapshot() -> SyncStatsSnapshot {
        lock.withLock {
            var out = SyncStatsSnapshot()
            out.version = versionValue
            out.partial = isPartial
            out.workouts = saved.workouts.count
            out.hrReadings = saved.heartRate.values.reduce(0, +)
            out.gpsPoints = saved.gps.values.reduce(0, +)
            for d in saved.days.values {
                out.steps += d.steps
                out.walkRunMeters += d.walkRun
                out.cyclingMeters += d.cycling
                out.swimMeters += d.swim
                out.sleepMinutes += d.sleep
                out.activeKcal += d.kcal
                if d.hrv { out.hrvDays += 1 }
            }
            var days = Set<String>()
            var types = Set<String>()
            for w in saved.workouts.values {
                out.trainingSeconds += w.seconds
                out.climbedMeters += w.climb
                out.workoutBeats += w.beats
                if !w.day.isEmpty { days.insert(w.day) }
                if !w.type.isEmpty { types.insert(w.type) }
            }
            out.workoutDays = days.count
            out.workoutTypes = types.count
            return out
        }
    }

    /// Forgets everything (Delete All My Data).
    func reset() {
        lock.withLock {
            saved = Saved()
            versionValue += 1
            dirty = false
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Writes pending changes now (tests, and when the app goes to the background).
    func flush() {
        writeQueue.sync { writeNow() }
    }

    // MARK: Internals

    private func mutate(_ change: (inout Saved) -> Bool) {
        let changed = lock.withLock { () -> Bool in
            let did = change(&saved)
            if did { versionValue += 1 }
            return did
        }
        if changed { scheduleWrite() }
    }

    private func scheduleWrite() {
        let schedule = lock.withLock { () -> Bool in
            dirty = true
            if writeScheduled { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        writeQueue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.writeNow() }
    }

    private func writeNow() {
        let data: Data? = lock.withLock {
            writeScheduled = false
            guard dirty else { return nil }
            dirty = false
            return try? JSONEncoder().encode(saved)
        }
        guard let data, let url else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "1500 cm", "12.5 m", "40 ft" (how HealthKit describes a metadata quantity) as metres.
    static func meters(from text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let number = Double(parts[0]) else { return nil }
        switch parts[1].lowercased() {
        case "m": return number
        case "cm": return number / 100
        case "km": return number * 1000
        case "ft": return number * 0.3048
        case "in": return number * 0.0254
        case "mi": return number * 1609.344
        default: return nil
        }
    }
}
