import SwiftUI

/// A number that counts up to its value (the text is redrawn for every step of the animation).
private struct CountingNumber: View, Animatable {
    var value: Double
    let spec: NumberSpec
    let size: CGFloat

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(spec.text(value))
            .tracking(-size * 0.055)
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(Theme.ink)
    }
}

/// The big rotating number on Home: one metric at a time, counting up, then fading to the next.
struct HeroMetricView: View {
    /// Metrics that have data, in rotation order (never empty).
    let metrics: [HeroMetric]

    @State private var index = 0
    /// 0...1: how much of the metric's value is shown while it counts up.
    @State private var reveal = 0.0
    @State private var visible = true
    @State private var ticker = Timer.publish(every: 8.6, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: HeroMetric { metrics[index % max(metrics.count, 1)] }

    var body: some View {
        let metric = current
        let spec = NumberSpec.make(for: metric.value, wholeNumber: metric.wholeNumber)
        let size = NumberSpec.fontSize(forTextLength: spec.text(metric.value).count)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountingNumber(value: metric.value * reveal, spec: spec, size: size)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: metric.value * reveal)
                if !spec.unit.isEmpty {
                    Text(spec.unit)
                        .font(.system(size: (size * 0.3).rounded(), weight: .regular))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .bottomLeading)
            Text(metric.label)
                .headlineText()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(metric.caption)
                .smallText()
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spec.text(metric.value))\(spec.unit) \(metric.label). \(metric.caption)")
        .accessibilityIdentifier("heroMetric")
        .onAppear { restartCount() }
        .onReceive(ticker) { _ in advance() }
    }

    private func restartCount() {
        guard !reduceMotion else {
            reveal = 1
            return
        }
        reveal = 0
        DispatchQueue.main.async { reveal = 1 }
    }

    private func advance() {
        guard metrics.count > 1 else { return }
        guard !reduceMotion else {
            index = (index + 1) % metrics.count
            return
        }
        withAnimation(.easeOut(duration: 0.3)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            reveal = 0
            index = (index + 1) % max(metrics.count, 1)
            withAnimation(.easeOut(duration: 0.3)) { visible = true }
            DispatchQueue.main.async { reveal = 1 }
        }
    }
}
