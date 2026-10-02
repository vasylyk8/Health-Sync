import Foundation

/// One of the big numbers that rotate on Home while the first sync runs.
struct HeroMetric: Equatable, Identifiable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case heartRate, workouts, steps, walkRun, sleep, calories, training, history
        case gps, climbed, heartbeats, hrvDays, cycled, swum, activeDays, types
    }

    let kind: Kind
    let value: Double
    let label: String
    let caption: String
    /// Show the whole number with separators (24,300) instead of a short form (24.3K).
    let wholeNumber: Bool

    var id: Int { kind.rawValue }
}

enum HeroMetrics {
    private static let metersPerMarathonStepCount = 55_500.0
    private static let earthCircumferenceKm = 40_075.0
    private static let kcalPerPizzaSlice = 285.0
    private static let everestMeters = 8_849.0
    private static let tourDeFranceKm = 3_400.0
    private static let poolLengthMeters = 50.0

    /// The metrics that have something to show yet, in rotation order. Never empty: before anything
    /// has been read it holds a single "0 workouts".
    static func make(stats s: SyncStatsSnapshot, workoutsUploaded: Int, historyStart: Date?, now: Date = Date()) -> [HeroMetric] {
        var out: [HeroMetric] = []
        // After an update of an app that had synced before, totals built from workout details start low: leave them out.
        let hiddenWhenPartial: Set<HeroMetric.Kind> = [.heartRate, .training, .gps, .climbed, .heartbeats, .activeDays, .types]
        func add(_ kind: HeroMetric.Kind, _ value: Double, _ label: String, whole: Bool = false, caption: String) {
            guard value.rounded() >= 1 else { return }
            if s.partial && hiddenWhenPartial.contains(kind) { return }
            out.append(HeroMetric(kind: kind, value: value, label: label, caption: caption, wholeNumber: whole))
        }
        func count(_ n: Double) -> String { Int(n.rounded()).formatted(.number) }

        add(.heartRate, Double(s.hrReadings), Copy.Metric.heartRateLabel, caption: Copy.Metric.heartRateCaption)
        add(.workouts, Double(max(s.workouts, workoutsUploaded)), Copy.Metric.workoutsLabel, caption: Copy.Metric.workoutsCaption)

        let marathons = s.steps / metersPerMarathonStepCount
        add(.steps, s.steps, Copy.Metric.stepsLabel,
            caption: marathons.rounded() >= 1 ? Copy.Metric.stepsCaption(count(marathons)) : Copy.Metric.stepsFallback)

        let walkRunKm = s.walkRunMeters / 1000
        let aroundEarth = walkRunKm / earthCircumferenceKm * 100
        add(.walkRun, walkRunKm, Copy.Metric.walkRunLabel, whole: true,
            caption: aroundEarth.rounded() >= 1 ? Copy.Metric.walkRunCaption(count(aroundEarth)) : Copy.Metric.walkRunFallback)

        let sleepHours = s.sleepMinutes / 60
        let sleepYears = sleepHours / 24 / 365
        add(.sleep, sleepHours, Copy.Metric.sleepLabel, whole: true,
            caption: sleepYears >= 0.1 ? Copy.Metric.sleepCaption(String(format: "%.1f", sleepYears)) : Copy.Metric.sleepFallback)

        let pizzas = s.activeKcal / kcalPerPizzaSlice
        add(.calories, s.activeKcal, Copy.Metric.caloriesLabel,
            caption: pizzas.rounded() >= 1 ? Copy.Metric.caloriesCaption(count(pizzas)) : Copy.Metric.caloriesFallback)

        let trainingHours = s.trainingSeconds / 3600
        let trainingDays = trainingHours / 24
        add(.training, trainingHours, Copy.Metric.trainingLabel, whole: true,
            caption: trainingDays.rounded() >= 1 ? Copy.Metric.trainingCaption(count(trainingDays)) : Copy.Metric.trainingFallback)

        if let start = historyStart {
            let days = max(0, now.timeIntervalSince(start) / 86_400)
            add(.history, days, Copy.Metric.historyLabel, whole: true,
                caption: Copy.Metric.historyCaption(start.formatted(.dateTime.month(.wide).year())))
        }

        add(.gps, Double(s.gpsPoints), Copy.Metric.gpsLabel, caption: Copy.Metric.gpsCaption)

        add(.climbed, s.climbedMeters, Copy.Metric.climbedLabel, whole: true,
            caption: (s.climbedMeters / everestMeters).rounded() >= 1
                ? Copy.Metric.climbedCaption(count(s.climbedMeters / everestMeters)) : Copy.Metric.climbedFallback)

        add(.heartbeats, s.workoutBeats, Copy.Metric.heartbeatsLabel, caption: Copy.Metric.heartbeatsCaption)
        add(.hrvDays, Double(s.hrvDays), Copy.Metric.hrvLabel, whole: true, caption: Copy.Metric.hrvCaption)

        let cycledKm = s.cyclingMeters / 1000
        add(.cycled, cycledKm, Copy.Metric.cycledLabel, whole: true,
            caption: cycledKm / tourDeFranceKm >= 0.1
                ? Copy.Metric.cycledCaption(String(format: "%.1f", cycledKm / tourDeFranceKm)) : Copy.Metric.cycledFallback)

        let swumKm = s.swimMeters / 1000
        let lengths = s.swimMeters / poolLengthMeters
        add(.swum, swumKm, Copy.Metric.swumLabel, whole: true,
            caption: lengths.rounded() >= 1 ? Copy.Metric.swumCaption(count(lengths)) : Copy.Metric.swumFallback)

        add(.activeDays, Double(s.workoutDays), Copy.Metric.activeDaysLabel, whole: true, caption: Copy.Metric.activeDaysCaption)
        add(.types, Double(s.workoutTypes), Copy.Metric.typesLabel, whole: true, caption: Copy.Metric.typesCaption)

        if out.isEmpty {
            out = [HeroMetric(kind: .workouts, value: 0, label: Copy.Metric.workoutsLabel, caption: Copy.Metric.workoutsCaption, wholeNumber: true)]
        }
        return out
    }
}

/// How a number is written: short (8.2M, 24.3K) or whole with separators.
struct NumberSpec: Equatable, Sendable {
    var divisor: Double
    var decimals: Int
    var unit: String
    var grouped: Bool

    /// Chosen from the number the display is heading to, so the unit stays the same while it counts up.
    static func make(for target: Double, wholeNumber: Bool) -> NumberSpec {
        if wholeNumber || target < 10_000 { return NumberSpec(divisor: 1, decimals: 0, unit: "", grouped: true) }
        if target >= 1e9 { return NumberSpec(divisor: 1e9, decimals: 2, unit: "B", grouped: false) }
        if target >= 1e6 { return NumberSpec(divisor: 1e6, decimals: target >= 1e8 ? 0 : 1, unit: "M", grouped: false) }
        return NumberSpec(divisor: 1e3, decimals: target >= 1e5 ? 0 : 1, unit: "K", grouped: false)
    }

    func text(_ value: Double) -> String {
        let x = value / divisor
        if grouped { return Int(x.rounded()).formatted(.number) }
        return String(format: "%.\(decimals)f", x)
    }

    /// Font size that keeps the text inside the screen width.
    static func fontSize(forTextLength length: Int) -> CGFloat {
        switch length {
        case ...3: return 176
        case 4: return 148
        case 5: return 124
        case 6: return 108
        default: return 92
        }
    }
}
