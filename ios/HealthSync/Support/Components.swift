import SwiftUI
import UIKit

/// Full-width pill button. `primary` is the filled ink pill, `secondary` the quiet grey one.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind = .primary
    var height: CGFloat = Theme.pillHeight
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bodyText(.semibold)
            .foregroundStyle(kind == .primary ? Theme.onInk : Theme.ink)
            .padding(.horizontal, Theme.margin)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(kind == .primary ? Theme.ink : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// A small pill (44 pt) used for the actions inside a setup step.
struct StepActionStyle: ButtonStyle {
    var filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .smallText(.semibold)
            .foregroundStyle(filled ? Theme.onInk : Theme.ink)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(filled ? Theme.ink : Theme.surface, in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// The small "KROK" wordmark at the top of every screen.
struct Wordmark: View {
    var body: some View {
        Text("KROK")
            .tracking(4.5)
            .smallText(.semibold)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Four segments, each a quarter of the upload. Segments below the current share are solid; the one the
/// upload is in shimmers (the first one before anything is uploaded).
struct StepBar: View {
    /// How much of the upload is done, 0...1.
    let fraction: Double
    static let segments = 4

    /// Segment `index` is full once the upload has reached its end (25%, 50%, 75%, 100%).
    static func isFilled(_ index: Int, fraction: Double) -> Bool {
        fraction >= Double(index + 1) / Double(segments) - 1e-9
    }

    private var done: [Bool] { (0..<Self.segments).map { Self.isFilled($0, fraction: fraction) } }
    private var currentIndex: Int? { done.firstIndex(of: false) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(done.enumerated()), id: \.offset) { index, isDone in
                Capsule()
                    .fill(isDone ? Theme.ink : Theme.track)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        if index == currentIndex { StepShimmer() }
                    }
                    .clipShape(Capsule())
            }
        }
        .animation(.easeInOut(duration: 0.4), value: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Upload progress")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent uploaded")
    }
}

private struct StepShimmer: View {
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.ink)
                .frame(width: geo.size.width * 0.4)
                .offset(x: reduceMotion ? 0 : (phase * 1.4 - 0.4) * geo.size.width)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Round check mark used for "connected" states.
struct CheckBadge: View {
    var inverted = false
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .font(.system(size: size))
            .foregroundStyle(inverted ? Theme.ink : Theme.onInk, inverted ? Theme.onInk : Theme.ink)
    }
}

/// Fades and lifts a view into place once, when it first appears (off with Reduce Motion).
private struct RiseIn: ViewModifier {
    var delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.6).delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0) -> some View { modifier(RiseIn(delay: delay)) }
}

/// Lays children out left to right and wraps to the next line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Title and close button at the top of a sheet.
struct SheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .headlineText()
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Copy.Sheet.close)
            .padding(.trailing, -10)
        }
        .padding(.top, 16)
    }
}

/// Light haptics, used sparingly.
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
