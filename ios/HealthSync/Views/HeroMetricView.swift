import SwiftUI

/// The big rotating number on Home: one metric at a time, every few seconds fading to the next.
struct HeroMetricView: View {
    /// Metrics that have data, in rotation order (never empty).
    let metrics: [HeroMetric]

    private static let seconds = 5.0
    private static let fade = 0.45

    @State private var index = 0
    @State private var visible = true
    @State private var ticker = Timer.publish(every: HeroMetricView.seconds, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: HeroMetric { metrics[index % max(metrics.count, 1)] }

    var body: some View {
        let metric = current
        let spec = NumberSpec.make(for: metric.value, wholeNumber: metric.wholeNumber)
        let text = spec.text(metric.value)
        let size = NumberSpec.fontSize(forTextLength: text.count)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text)
                    .tracking(-size * 0.055)
                    .font(.system(size: size, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(Theme.ink)
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
        .accessibilityLabel("\(text)\(spec.unit) \(metric.label). \(metric.caption)")
        .accessibilityIdentifier("heroMetric")
        .onReceive(ticker) { _ in advance() }
    }

    /// Fades the current metric out, swaps it while it is invisible, and fades the next one in. The number
    /// appears at its full value; it does not count up.
    private func advance() {
        guard metrics.count > 1 else { return }
        guard !reduceMotion else {
            index = (index + 1) % metrics.count
            return
        }
        withAnimation(.easeInOut(duration: Self.fade)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade) {
            index = (index + 1) % max(metrics.count, 1)
            withAnimation(.easeInOut(duration: Self.fade)) { visible = true }
        }
    }
}
