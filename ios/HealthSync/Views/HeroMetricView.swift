import SwiftUI

/// A number that counts from one value to another (the text is redrawn for every step of the animation).
struct CountingNumber: View, Animatable {
    var value: Double
    let spec: NumberSpec
    let size: CGFloat

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    /// Tighter than the font's own spacing, as a share of the font size.
    static let trackingShare: CGFloat = 0.055
    /// Room to the right of the number's text, as a share of the font size.
    static let trailingShare: CGFloat = 0.02
    /// A thin space: wide enough to leave room after a round last digit, narrow enough to look like nothing.
    static let guardSpace = "\u{2009}"

    /// How wide the guard space is in the number's font, measured (not guessed).
    static func guardSpaceWidth(size: CGFloat) -> CGFloat {
        (guardSpace as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width
    }

    /// Padding that takes back exactly the room the guard space adds, so the unit next to the number sits where it
    /// would without it.
    static func trailingPadding(size: CGFloat) -> CGFloat {
        size * trailingShare - guardSpaceWidth(size: size)
    }

    var body: some View {
        // With negative tracking the last digit ends inside the text's own bounds, and a round 3, 5 or 6 gets its right
        // edge cut off (padding outside the Text does not help, the clip is the Text's). So the number is followed by a
        // space that is not tightened, which gives the digit room inside the bounds. The padding then takes that room
        // back by exactly the space's measured width, so the layout (and the unit beside the number) does not move.
        (Text(spec.text(value)).tracking(-size * Self.trackingShare) + Text(Self.guardSpace))
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(Theme.ink)
            .padding(.trailing, Self.trailingPadding(size: size))
    }
}

/// Where each metric's count starts. The first time a metric is shown it counts up from 0; after that it
/// only counts from the value it showed last to its new value (200 → 255 moves just the last digits).
struct HeroCounter: Equatable {
    private var shown: [HeroMetric.Kind: Double] = [:]

    /// The value to start counting from, and remembers `value` as the new last-shown value.
    mutating func start(_ kind: HeroMetric.Kind, to value: Double) -> Double {
        let from = shown[kind] ?? 0
        shown[kind] = value
        return from
    }
}

/// The big rotating number on Home: one metric at a time, every few seconds fading to the next.
/// Numbers count up when they first appear and whenever the sync adds to them.
struct HeroMetricView: View {
    /// Metrics that have data, in rotation order (never empty).
    let metrics: [HeroMetric]
    /// The small look (44 pt number, body-size label) used under the race medal; otherwise the big one.
    var compact = false

    private static let seconds = 5.0
    private static let fade = 0.45

    @State private var currentKind: HeroMetric.Kind?
    /// The number on screen (animated).
    @State private var number = 0.0
    /// What `number` is heading to.
    @State private var target: (kind: HeroMetric.Kind, value: Double)?
    @State private var counter = HeroCounter()
    @State private var visible = true
    @State private var ticker = Timer.publish(every: HeroMetricView.seconds, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: HeroMetric {
        metrics.first { $0.kind == currentKind } ?? metrics[0]
    }

    var body: some View {
        let metric = current
        let spec = NumberSpec.make(for: metric.value, wholeNumber: metric.wholeNumber)
        let finalText = spec.text(metric.value)
        // Sized from the final number, so the size does not jump while it counts.
        let size = compact ? 44 : NumberSpec.fontSize(forTextLength: finalText.count)
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountingNumber(value: number, spec: spec, size: size)
                if !spec.unit.isEmpty {
                    Text(spec.unit)
                        .font(.system(size: (size * 0.3).rounded(), weight: .regular))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 52 : 176, maxHeight: compact ? 52 : 176, alignment: .bottomLeading)
            Text(metric.label)
                .modifier(LabelStyle(compact: compact))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(metric.caption)
                .smallText()
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .depthTilt(enabled: !compact)
        .motion(Motion.smooth, value: compact)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 10)
        .blur(radius: visible ? 0 : 8)
        .scaleEffect(visible ? 1 : 0.98, anchor: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(finalText)\(spec.unit) \(metric.label). \(metric.caption)")
        .accessibilityIdentifier("heroMetric")
        .onAppear {
            if currentKind == nil { currentKind = metrics[0].kind }
            present(current)
        }
        // The sync adds to the metric on screen: count on from where it was.
        .onChange(of: current.value) { _, _ in present(current) }
        .onReceive(ticker) { _ in advance() }
    }

    /// Starts counting to the metric's value (from 0 the first time, otherwise from its last shown value).
    private func present(_ metric: HeroMetric) {
        if let target, target.kind == metric.kind, target.value == metric.value { return }
        target = (metric.kind, metric.value)
        let from = counter.start(metric.kind, to: metric.value)
        let countUp = from == 0
            ? Animation.timingCurve(0.16, 1, 0.3, 1, duration: 1.2)
            : Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.8)
        guard let animation = Motion.resolved(countUp, reduceMotion: reduceMotion), from != metric.value else {
            number = metric.value
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { number = from }
        let value = metric.value
        DispatchQueue.main.async {
            withAnimation(animation) { number = value }
        }
    }

    /// Fades the current metric out, swaps it while it is invisible, and fades the next one in.
    private func advance() {
        guard metrics.count > 1 else { return }
        let index = metrics.firstIndex { $0.kind == currentKind } ?? 0
        let next = metrics[(index + 1) % metrics.count]
        let fade = Animation.easeInOut(duration: Self.fade)
        guard let animation = Motion.resolved(fade, reduceMotion: reduceMotion) else {
            currentKind = next.kind
            present(next)
            return
        }
        withAnimation(animation) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade) {
            currentKind = next.kind
            present(next)
            withAnimation(Motion.smooth) { visible = true }
        }
    }
}

/// The metric label: 24 pt in the big look, 17 pt in the compact one.
private struct LabelStyle: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact { content.bodyText(.semibold) } else { content.headlineText() }
    }
}
