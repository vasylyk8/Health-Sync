import Foundation

/// One Apple Health reading reduced to what the daily and hourly aggregation needs. HealthKit-free, so the rules are unit-tested.
struct RawReading: Equatable, Sendable {
    var start: Date
    var end: Date
    /// Cumulative types: the amount. Discrete types: the average of the reading (a series reading holds `count` values).
    var value: Double
    var min: Double
    var max: Double
    /// Discrete types: the most recent value inside the reading.
    var last: Double
    var count: Int
    /// Bundle identifier of the app or device that wrote the reading.
    var source: String
    /// Written by an Apple Watch: for cumulative types the Watch's own count wins where it has one.
    var watch = false

    /// A single value (count 1).
    init(start: Date, end: Date, value: Double, source: String, watch: Bool = false) {
        self.init(start: start, end: end, value: value, min: value, max: value, last: value, count: 1, source: source, watch: watch)
    }

    init(start: Date, end: Date, value: Double, min: Double, max: Double, last: Double, count: Int, source: String, watch: Bool = false) {
        self.start = start
        self.end = end
        self.value = value
        self.min = min
        self.max = max
        self.last = last
        self.count = Swift.max(1, count)
        self.source = source
        self.watch = watch
    }

    /// Workout samples can lack a source-revision product type even though their HKDevice identifies the Watch.
    static func isWatch(productType: String?, model: String?, hardware: String?) -> Bool {
        productType?.hasPrefix("Watch") == true || hardware?.hasPrefix("Watch") == true ||
            model?.caseInsensitiveCompare("Watch") == .orderedSame || model?.caseInsensitiveCompare("Apple Watch") == .orderedSame
    }

    /// Apple's own devices (Watch, iPhone) write as com.apple.health.<id>.
    var apple: Bool { source.hasPrefix("com.apple.health") }
}

/// Daily and hourly values computed from raw readings, for the days and hours Apple Health's own statistics leave out
/// (a restored iOS 27 iPhone returned empty statistics for every year that ended in the past, while the readings were there).
/// The rules follow what HealthKit's statistics do, measured against them in the simulator by the daily check:
/// - arithmetic types (respiratory rate, SpO2...) weigh every value alike (a series reading as many values as it holds) and
///   count a reading only in the bucket it starts in, however far it reaches into the next one;
/// - time-weighted types (heart rate, resting heart rate) weigh each reading by its time span widened by 22.5 s on each
///   side, overlaps split in the middle, and count it in every bucket its span touches (the Watch's resting heart rate
///   written 23:55-23:50 counts on both days);
/// - sound levels average as energy (10^(dB/10)) weighted by duration, an equivalent continuous level;
/// - a cumulative reading is spread over its span by time into 5-minute slots, and readings from several sources are
///   never added together. The Watch counts wherever it recorded. A reading of Apple's other devices (the iPhone) counts
///   only when the Watch recorded nothing within 5 minutes of it: the iPhone logs the same walk or climb a few minutes off
///   from the Watch, and HealthKit then keeps the Watch's alone. Per slot that leaves the Watch (the largest Watch), else
///   the larger of Apple's other devices, else, only in an hour none of Apple's devices recorded, the largest other app,
///   so a scale app's whole-day resting energy written at a weigh-in is not added to the Watch's. Measured against
///   HealthKit's own totals on a real iPhone (81 days, Watch and iPhone both counting): steps -0.1% in all, 0.2% median /
///   1.7% worst day, distance 0.1% / 1.7%; per 5-minute slot instead it was +0.7% in all, 0.7% / 3.8% and 0.6% / 7.3%.
struct SampleAggregator {
    enum Granularity { case day, hour }
    enum Style { case cumulative, arithmetic, timeWeighted, equivalentLevel }

    /// Half the time HealthKit's time-weighted average gives an instantaneous reading (measured: 45 s in all). Sound levels
    /// are weighted by duration alone.
    static let halfWindow: TimeInterval = 22.5
    private var widen: TimeInterval { style == .timeWeighted ? Self.halfWindow : 0 }

    let calendar: Calendar
    let from: Date
    let to: Date
    let style: Style
    let granularity: Granularity

    private struct Span {
        var start: Double
        var end: Double
        var value: Double
        /// Most time the reading can weigh: a series reading of n values, spaced evenly, weighs each value until the next
        /// one, at most 45 s (measured), and 45 s for the last.
        var cap = Double.infinity
    }

    private struct Discrete {
        var sum = 0.0
        var weight = 0.0
        var spans: [Span] = []
        var min = Double.infinity
        var max = -Double.infinity
        var lastAt = Date.distantPast
        var last = 0.0
    }

    private var discrete: [Date: Discrete] = [:]
    /// Cumulative amount per 5-minute slot, per source, and which sources are Apple Watches.
    private var slots: [Date: [String: Double]] = [:]
    private var watches: Set<String> = []
    static let slotLength: TimeInterval = 300
    /// Readings of Apple's other devices, kept until the Watch's readings are all in, and the Watch's spans.
    private var deferred: [RawReading] = []
    private var watchSpans: [(start: Date, end: Date)] = []
    /// Hours any of Apple's devices recorded in, counted or not.
    private var appleHours = Set<Date>()
    /// How close the Watch's nearest reading may be for an iPhone reading to be left out (best fit: 3 to 8 minutes).
    static let nearWatch: TimeInterval = 300

    init(calendar: Calendar, from: Date, to: Date, style: Style, granularity: Granularity) {
        self.calendar = calendar
        self.from = from
        self.to = to
        self.style = style
        self.granularity = granularity
    }

    mutating func add(_ r: RawReading) {
        guard r.value.isFinite, r.end >= r.start else { return }
        // Only cumulative duplicate handling needs neighbouring readings outside the range. The other styles follow
        // HealthKit's overlap predicate, so the five-minute read margin cannot add values after the requested end.
        if style != .cumulative, r.start >= to || r.end < from { return }
        if style == .cumulative { addCumulative(r) } else { addDiscrete(r) }
    }

    private mutating func addDiscrete(_ r: RawReading) {
        guard r.min.isFinite, r.max.isFinite, r.last.isFinite else { return }
        for bucket in discreteBuckets(r) {
            var acc = discrete[bucket] ?? Discrete()
            switch style {
            case .arithmetic, .cumulative:
                acc.sum += r.value * Double(r.count)
                acc.weight += Double(r.count)
            case .timeWeighted, .equivalentLevel:
                acc.spans.append(span(r, value: style == .equivalentLevel ? pow(10, r.value / 10) : r.value))
            }
            acc.min = Swift.min(acc.min, r.min)
            acc.max = Swift.max(acc.max, r.max)
            if r.end >= acc.lastAt {
                acc.lastAt = r.end
                acc.last = r.last
            }
            discrete[bucket] = acc
        }
    }

    /// Adds a cumulative reading. The Watch's and other apps' readings go straight into their slots; Apple's other devices'
    /// wait for `mergedSlots`, which needs all of the Watch's readings to decide.
    private mutating func addCumulative(_ r: RawReading) {
        if Self.isApple(r.source) {
            for (slot, _) in Self.slotShares(r, from: from, to: to) { appleHours.insert(hour(slot)) }
        }
        if r.watch {
            watches.insert(r.source)
            watchSpans.append((r.start, r.end))
        } else if Self.isApple(r.source) {
            deferred.append(r)
            return
        }
        for (slot, share) in Self.slotShares(r, from: from, to: to) { slots[slot, default: [:]][r.source, default: 0] += share }
    }

    /// A reading's amount per 5-minute slot, spread over its span by time; a reading without duration goes to the slot it
    /// is in. Only the part inside [from, to) counts.
    private static func slotShares(_ r: RawReading, from: Date, to: Date) -> [(Date, Double)] {
        func slot(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / slotLength).rounded(.down) * slotLength) }
        let span = r.end.timeIntervalSince(r.start)
        if span <= 0 { return r.start >= from && r.start < to ? [(slot(r.start), r.value)] : [] }
        var out: [(Date, Double)] = []
        var cursor = slot(r.start)
        while cursor < r.end {
            let next = cursor.addingTimeInterval(slotLength)
            let lo = Swift.max(cursor, r.start, from)
            let hi = Swift.min(next, r.end, to)
            if hi > lo { out.append((cursor, r.value * hi.timeIntervalSince(lo) / span)) }
            cursor = next
        }
        return out
    }

    private static func isApple(_ source: String) -> Bool { source.hasPrefix("com.apple.health") }

    private func hour(_ slot: Date) -> Date { calendar.dateInterval(of: .hour, for: slot)?.start ?? slot }

    /// The Watch's spans merged where they overlap, in time order.
    private func watchUnion() -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        // Reserved Apple source IDs belong to a device. A reading with missing device metadata from a source already
        // identified as a Watch must not be discarded as an iPhone duplicate. Include its span before judging phones.
        let inferred = deferred.filter { watches.contains($0.source) }.map { (start: $0.start, end: $0.end) }
        for s in (watchSpans + inferred).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1].end = Swift.max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Each slot's amount after merging its sources (see the type's comment), with the slot's start.
    private func mergedSlots() -> [(Date, Double)] {
        var slots = self.slots
        let spans = watchUnion()
        for r in deferred {
            // The first Watch span that ends at or after the reading's start minus the margin; near if it starts in time.
            let lo = r.start.addingTimeInterval(-Self.nearWatch)
            var a = 0, b = spans.count
            while a < b {
                let m = (a + b) / 2
                if spans[m].end < lo { a = m + 1 } else { b = m }
            }
            if !watches.contains(r.source), a < spans.count, spans[a].start <= r.end.addingTimeInterval(Self.nearWatch) { continue }
            for (slot, share) in Self.slotShares(r, from: from, to: to) { slots[slot, default: [:]][r.source, default: 0] += share }
        }
        return slots.map { slot, sources -> (Date, Double) in
            let watch = sources.filter { watches.contains($0.key) }
            if let v = watch.values.max() { return (slot, v) }
            let apple = sources.filter { Self.isApple($0.key) }
            if let v = apple.values.max() { return (slot, v) }
            return (slot, appleHours.contains(hour(slot)) ? 0 : (sources.values.max() ?? 0))
        }
    }

    private var component: Calendar.Component { granularity == .day ? .day : .hour }

    /// The buckets a discrete reading counts in: the one it starts in, and for time-weighted types and sound levels also
    /// every later one its span reaches into. Only buckets inside [from, to).
    private func discreteBuckets(_ r: RawReading) -> [Date] {
        guard let first = calendar.dateInterval(of: component, for: r.start) else { return [] }
        var out = [first.start]
        if style != .arithmetic {
            var cursor = first.end
            while cursor < r.end, let next = calendar.dateInterval(of: component, for: cursor) {
                out.append(next.start)
                cursor = next.end
            }
        }
        let lower = calendar.dateInterval(of: component, for: from)?.start ?? from
        return out.filter { $0 >= lower && $0 < to }
    }

    private func span(_ r: RawReading, value: Double) -> Span {
        let start = r.start.timeIntervalSince1970
        let end = r.end.timeIntervalSince1970
        guard r.count > 1, style == .timeWeighted else { return Span(start: start, end: end, value: value) }
        let gap = (end - start) / Double(r.count)
        return Span(start: start, end: end - gap, value: value, cap: Double(r.count - 1) * Swift.min(gap, 2 * widen) + 2 * widen)
    }

    /// Average of one bucket's readings by the type's style.
    private func average(_ acc: Discrete, bucket: Date) -> Double? {
        switch style {
        case .arithmetic, .cumulative:
            return acc.weight > 0 ? acc.sum / acc.weight : nil
        case .timeWeighted:
            return timeWeightedMean(acc.spans, bucket: bucket)
        case .equivalentLevel:
            return timeWeightedMean(acc.spans, bucket: bucket).map { 10 * log10($0) }
        }
    }

    /// Each reading weighs its span widened by `widen` on each side, inside the bucket (widened the same way); where two
    /// neighbours' spans overlap, the overlap is split in the middle. Readings without any weight count alike.
    private func timeWeightedMean(_ spans: [Span], bucket: Date) -> Double? {
        guard !spans.isEmpty, let interval = calendar.dateInterval(of: component, for: bucket) else { return nil }
        let s = spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let lo = s.map { $0.start - widen }
        let hi = s.map { $0.end + widen }
        let bucketStart = interval.start.timeIntervalSince1970 - widen
        let bucketEnd = interval.end.timeIntervalSince1970 + widen
        var sum = 0.0
        var weight = 0.0
        for i in s.indices {
            var a = Swift.max(lo[i], bucketStart)
            var b = Swift.min(hi[i], bucketEnd)
            if i > 0, lo[i] < hi[i - 1] { a = Swift.max(a, (lo[i] + hi[i - 1]) / 2) }
            if i + 1 < s.count, lo[i + 1] < hi[i] { b = Swift.min(b, (lo[i + 1] + hi[i]) / 2) }
            let w = Swift.min(s[i].cap, Swift.max(0, b - a))
            sum += s[i].value * w
            weight += w
        }
        if weight > 0 { return sum / weight }
        return s.map(\.value).reduce(0, +) / Double(s.count)
    }

    /// One value per local day that has readings ("YYYY-MM-DD", value).
    func daily(_ agg: DailyAgg) -> [(String, Double)] {
        if style == .cumulative {
            var days: [String: Double] = [:]
            for (slot, v) in mergedSlots() { days[SleepNights.dayKey(slot, calendar: calendar), default: 0] += v }
            return days.keys.sorted().map { ($0, days[$0]!) }
        }
        // Day buckets map one to one onto days; hour buckets (not used for daily values) would be merged per day.
        return discrete.keys.sorted().compactMap { bucket in
            guard let acc = discrete[bucket] else { return nil }
            let day = SleepNights.dayKey(bucket, calendar: calendar)
            switch agg {
            case .sum: return nil
            case .avg: return average(acc, bucket: bucket).map { (day, $0) }
            case .min: return (day, acc.min)
            case .max: return (day, acc.max)
            case .last: return (day, acc.last)
            }
        }
    }

    /// One bucket per local hour that has readings: cumulative types fill `v` with the amount, discrete types the
    /// average (`v`), minimum (`lo`) and maximum (`hi`), each only when asked for.
    func hourly(avg: Bool, min: Bool, max: Bool) -> [HourBucket] {
        if style == .cumulative {
            var hours: [Date: Double] = [:]
            for (slot, v) in mergedSlots() { hours[calendar.dateInterval(of: .hour, for: slot)?.start ?? slot, default: 0] += v }
            return hours.keys.sorted().map { HourBucket(t: $0.msValue, v: hours[$0]!, lo: nil, hi: nil) }
        }
        return discrete.keys.sorted().compactMap { hour in
            guard let acc = discrete[hour] else { return nil }
            return HourBucket(t: hour.msValue, v: avg ? average(acc, bucket: hour) : nil, lo: min ? acc.min : nil, hi: max ? acc.max : nil)
        }
    }

    static func hasMissingHours(_ timestamps: [Int64], from: Date, to: Date, calendar: Calendar) -> Bool {
        guard to > from, var hour = calendar.dateInterval(of: .hour, for: from)?.start else { return false }
        let present = Set(timestamps)
        while hour < to {
            if !present.contains(hour.msValue) { return true }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else { return false }
            hour = next
        }
        return false
    }

    /// Local calendar days from the day of `from` up to `to` (a day that has started counts).
    static func localDays(from: Date, to: Date, calendar: Calendar) -> Int {
        guard to > from else { return 0 }
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to.addingTimeInterval(-0.001))
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    /// Relative difference of `other` from `reference` on the days both have, as (median, largest) absolute percentages.
    /// Used to measure the raw aggregation against Apple's own statistics where those work.
    static func difference(reference: [(String, Double)], other: [(String, Double)]) -> (median: Double, max: Double, days: Int)? {
        let ref = Dictionary(reference, uniquingKeysWith: { a, _ in a })
        let diffs = other.compactMap { day, v -> Double? in
            guard let r = ref[day], r != 0 else { return nil }
            return abs(v - r) / abs(r) * 100
        }.sorted()
        guard !diffs.isEmpty else { return nil }
        return (diffs[diffs.count / 2], diffs.last!, diffs.count)
    }
}
