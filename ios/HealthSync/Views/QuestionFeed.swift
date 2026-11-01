import SwiftUI

/// Example questions as chat bubbles that scroll slowly upward in a loop, fading out at the top and in at the bottom.
/// Still (and readable top to bottom) with Reduce Motion on.
struct QuestionFeed: View {
    let questions: [String]

    /// Slow enough to read, one full loop of the list.
    static let loopSeconds = 32.0
    private static let height: CGFloat = 340
    /// Each bubble has its own maximum width, so the right edge stays uneven like a real conversation.
    private static let maxWidths: [CGFloat] = [290, 300, 270, 310, 300, 280, 290, 310]

    @State private var loopHeight: CGFloat = 0
    /// When the scrolling started; the position is worked out from the clock, so no animation can interrupt it.
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moves: Bool { !reduceMotion && !Motion.isUITesting }

    /// How far up the list has scrolled after `elapsed` seconds: one list height per loop, starting over smoothly.
    static func offset(elapsed: TimeInterval, loopHeight: CGFloat) -> CGFloat {
        guard loopHeight > 0, loopSeconds > 0 else { return 0 }
        let progress = max(elapsed, 0).truncatingRemainder(dividingBy: loopSeconds) / loopSeconds
        return -CGFloat(progress) * loopHeight
    }

    var body: some View {
        // The list twice, so that moving up by one list height looks the same as the start.
        TimelineView(.animation(minimumInterval: nil, paused: !moves)) { context in
            VStack(alignment: .trailing, spacing: 0) {
                bubbles
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: LoopHeightKey.self, value: geo.size.height)
                        }
                    )
                bubbles
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(y: moves ? Self.offset(elapsed: context.date.timeIntervalSince(started), loopHeight: loopHeight) : 0)
            .onPreferenceChange(LoopHeightKey.self) { height in
                guard height > 0, abs(height - loopHeight) > 0.5 else { return }
                loopHeight = height
            }
        }
        .frame(height: Self.height, alignment: .top)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.38),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        )
        // Decorative and moving, and partly faded out: hidden from VoiceOver and the contrast audit.
        .accessibilityHidden(true)
    }

    private var bubbles: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Text(question)
                    .bodyText()
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Theme.surface,
                        in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                    .frame(maxWidth: Self.maxWidths[index % Self.maxWidths.count], alignment: .trailing)
                    .padding(.bottom, 10)
            }
        }
    }
}

private struct LoopHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
