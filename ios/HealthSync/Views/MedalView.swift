import SwiftUI
import UIKit

/// A finisher's medal on a ribbon. It swings gently from side to side; when `showingBack` changes it turns around
/// (front: the race, back: the runner's goal time). Everything race-specific comes from the `SpecialEdition`.
/// Drawn in a 240 x 290 box and scaled to whatever frame it is given.
struct MedalView: View {
    let edition: SpecialEdition
    /// "4:30:00", shown large on the back.
    let timeText: String
    let showingBack: Bool

    private static let turnSeconds = 0.95
    private static let swingDegrees = 22.0
    private static let swingSpeed = 1.1  // radians per second

    private struct Turn { var from: Double; var to: Double; var start: Date }

    @State private var turn: Turn?
    /// When the swing last started from straight ahead (so it carries on from where a turn ended).
    @State private var swingStart = Date()
    /// True once a turn to the back has finished: the medal then stops redrawing.
    @State private var settled = false
    /// Counts turns, so a late "finished" from an earlier turn is ignored.
    @State private var turnCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || (showingBack && settled) {
                medal(angle: showingBack ? (turn?.to ?? 180) : 0)
            } else {
                TimelineView(.animation) { context in
                    medal(angle: angle(at: context.date))
                }
            }
        }
        .frame(width: 240, height: 290)
        .onChange(of: showingBack) { _, back in
            let now = Date()
            let current = angle(at: now)
            settled = false
            turnCount += 1
            let mine = turnCount
            if back {
                turn = Turn(from: current, to: current >= 0 ? 180 : -180, start: now)
            } else {
                turn = Turn(from: current, to: 0, start: now)
                swingStart = now.addingTimeInterval(Self.turnSeconds)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.turnSeconds) {
                if turnCount == mine { settled = back }
            }
        }
    }

    private func angle(at now: Date) -> Double {
        if let turn, now < turn.start.addingTimeInterval(Self.turnSeconds) {
            let p = now.timeIntervalSince(turn.start) / Self.turnSeconds
            return turn.from + (turn.to - turn.from) * ease(p)
        }
        if showingBack { return turn?.to ?? 180 }
        return Self.swingDegrees * sin(now.timeIntervalSince(swingStart) * Self.swingSpeed)
    }

    private func ease(_ u: Double) -> Double {
        u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    private func medal(angle: Double) -> some View {
        let facingFront = cos(angle * .pi / 180) >= 0
        return VStack(spacing: 0) {
            ZStack {
                MedalSide(edition: edition, timeText: timeText, back: false).opacity(facingFront ? 1 : 0)
                MedalSide(edition: edition, timeText: timeText, back: true)
                    .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                    .opacity(facingFront ? 0 : 1)
            }
            .frame(width: 240, height: 290)
            .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), perspective: 0.35)
        }
        .accessibilityHidden(true)
    }
}

/// One face of the medal: ribbon, coin and rim text.
private struct MedalSide: View {
    let edition: SpecialEdition
    let timeText: String
    let back: Bool

    /// The coin's centre in the 240 x 290 box.
    private let center = CGPoint(x: 120, y: 170)

    var body: some View {
        ZStack {
            Canvas { context, _ in
                let ink = GraphicsContext.Shading.color(Theme.ink)
                // Ribbon: a dark band with two light stripes, ending in a small ring.
                context.fill(Path(CGRect(x: 98, y: 0, width: 44, height: 64)), with: ink)
                if !back {
                    for x in [108.0, 126.0] {
                        context.fill(Path(CGRect(x: x, y: 0, width: 6, height: 64)), with: .color(Theme.background.opacity(0.35)))
                    }
                }
                let ring = Path(ellipseIn: CGRect(x: 112, y: 54, width: 16, height: 16))
                context.fill(ring, with: .color(Theme.background))
                context.stroke(ring, with: ink, lineWidth: 3)
                // Coin: filled disc, heavy outer line, fine inner line.
                let outer = Path(ellipseIn: CGRect(x: center.x - 108, y: center.y - 108, width: 216, height: 216))
                context.fill(outer, with: .color(Theme.surface))
                context.stroke(outer, with: ink, lineWidth: 4)
                let inner = Path(ellipseIn: CGRect(x: center.x - 98, y: center.y - 98, width: 196, height: 196))
                context.stroke(inner, with: ink, lineWidth: 1.5)
            }
            if back {
                ArcText(text: "YOUR GOAL TIME", radius: 83.5, top: true, color: Theme.ink).position(center)
                ArcText(text: "GOOD LUCK", radius: 83.5, top: false, color: Theme.muted).position(center)
                Text(timeText)
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .position(x: center.x, y: center.y + 2)
            } else {
                ArcText(text: edition.medalTop, radius: 83.5, top: true, color: Theme.ink).position(center)
                ArcText(text: edition.medalBottom, radius: 83.5, top: false, color: Theme.ink).position(center)
                // The art fills 157 x 110, centred on the coin.
                edition.art()
                    .frame(width: 157.3, height: 110.4)
                    .position(x: center.x, y: center.y)
            }
        }
        .frame(width: 240, height: 290)
    }
}

/// Text along a circle (SwiftUI has no text-on-a-path): each letter is placed and turned on its own. `top` text
/// reads clockwise over the top of the coin, the other reads left to right along the bottom.
private struct ArcText: View {
    let text: String
    let radius: CGFloat
    let top: Bool
    let color: Color

    private static let tracking: CGFloat = 4
    private static let font = UIFont.systemFont(ofSize: 12, weight: .semibold)

    private var letters: [(char: String, offset: CGFloat)] {
        let widths = text.map { ("\($0)" as NSString).size(withAttributes: [.font: Self.font]).width + Self.tracking }
        let total = widths.reduce(0, +) - Self.tracking
        var run: CGFloat = 0
        return zip(text, widths).map { ch, w in
            defer { run += w }
            return ("\(ch)", run + (w - Self.tracking) / 2 - total / 2)
        }
    }

    var body: some View {
        ZStack {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                let s = letter.offset / radius
                Text(letter.char)
                    .font(Font(Self.font))
                    .foregroundStyle(color)
                    .rotationEffect(.radians(top ? s : -s))
                    .offset(x: radius * sin(s), y: top ? -radius * cos(s) : radius * cos(s))
            }
        }
        .frame(width: 0, height: 0)
    }
}
