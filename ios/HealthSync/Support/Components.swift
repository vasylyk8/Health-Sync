import SwiftUI
import UIKit

/// Full-width pill button. `primary` is the filled ink pill, `secondary` the quiet grey one.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind = .primary
    var height: CGFloat = Theme.pillHeight
    /// Side padding inside the pill; the half-width pills on Home use less.
    var horizontalPadding: CGFloat = Theme.margin
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bodyText(.semibold)
            .foregroundStyle(kind == .primary ? Theme.buttonText : Theme.ink)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(kind == .primary ? Theme.buttonFill : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .motion(Motion.press, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.soft() }
            }
    }
}

/// A small pill (44 pt) used for the actions inside a setup step.
struct StepActionStyle: ButtonStyle {
    var filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .smallText(.semibold)
            .foregroundStyle(filled ? Theme.buttonText : Theme.ink)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(filled ? Theme.buttonFill : Theme.surface, in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .motion(Motion.press, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.soft() }
            }
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

/// Four lines, one for each kind of data being read from Apple Health, with what has been read under each. A finished line
/// is solid; a running line has a short bar that moves back and forth (it says "working", not "this much is done"); a line
/// that has not started is empty.
struct StepBar: View {
    let lines: [SyncLine]

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 6) {
                    LoadingLine(state: line.state)
                    Text(line.name)
                        .font(.caption2.weight(line.state == .waiting ? .regular : .semibold))
                        .foregroundStyle(line.state == .waiting ? Theme.muted : Theme.ink)
                    Text(line.detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.name)
                .accessibilityValue("\(line.detail), \(Self.word(line.state))")
            }
        }
        .motion(Motion.smooth, value: lines.map(\.state))
    }

    private static func word(_ state: SyncLine.State) -> String {
        switch state {
        case .waiting: return Copy.Home.Line.waitingAccessibility
        case .running: return Copy.Home.Line.runningAccessibility
        case .done: return Copy.Home.Line.doneAccessibility
        }
    }
}

private struct LoadingLine: View {
    let state: SyncLine.State

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.track)
            // A finished line fills in from the left instead of switching colour.
            Capsule()
                .fill(Theme.ink)
                .scaleEffect(x: state == .done ? 1 : 0, anchor: .leading)
            if state == .running { Shimmer() }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}

/// A soft band of light that keeps sweeping over a running line (it says "working", not "this much is done").
/// It rests in the middle for people who turned off motion, and during UI tests.
private struct Shimmer: View {
    @State private var swept = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var moves: Bool { !reduceMotion && !Motion.isUITesting }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * 0.45
            LinearGradient(colors: [Theme.ink.opacity(0), Theme.ink, Theme.ink.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
                .offset(x: moves ? (swept ? geo.size.width : -width) : (geo.size.width - width) / 2)
        }
        .onAppear {
            guard moves else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { swept = true }
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
            .opacity(shown || !allowed ? 1 : 0)
            .offset(y: shown || !allowed ? 0 : 12)
            .blur(radius: shown || !allowed ? 0 : 4)
            .onAppear {
                guard !shown else { return }
                if let animation = Motion.resolved(Motion.reveal, reduceMotion: reduceMotion) {
                    withAnimation(animation.delay(delay)) { shown = true }
                } else {
                    shown = true
                }
            }
    }

    private var allowed: Bool { Motion.resolved(Motion.reveal, reduceMotion: reduceMotion) != nil }
}

extension View {
    func riseIn(delay: Double = 0) -> some View { modifier(RiseIn(delay: delay)) }
    /// Entrance for the n-th item of a list or column: each one lands `Motion.stagger` after the one before.
    func staggeredReveal(index: Int, base: Double = 0) -> some View {
        riseIn(delay: Motion.staggerDelay(index: index, base: base))
    }
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
    static func tap() { guard !Motion.isUITesting else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// The barely-there tick under a finger landing on a button.
    static func soft() { guard !Motion.isUITesting else { return }; UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6) }
    static func success() { guard !Motion.isUITesting else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

