import SwiftUI

/// The Chicago Marathon picture: the four stars of the city flag over the skyline, drawn in the app's greys.
/// With `course` on, a dotted course line runs underneath. Used by `SpecialEdition.chicago2026`.
struct ChicagoMarathonArt: View {
    var course = true

    private static let star: [(CGFloat, CGFloat)] = [
        (0, -10), (2.89, -5), (8.66, -5), (5.77, 0), (8.66, 5), (2.89, 5),
        (0, 10), (-2.89, 5), (-8.66, 5), (-5.77, 0), (-8.66, -5), (-2.89, -5),
    ]

    var body: some View {
        Canvas { context, size in
            let s = size.width / 342
            let base = CGAffineTransform(scaleX: s, y: s)
            // The skyline is drawn in a 342 x 240 box, then shrunk and moved down to leave room for the stars.
            let sky = base.translatedBy(x: 26, y: 33).scaledBy(x: 0.85, y: 0.85)
            let ink = GraphicsContext.Shading.color(Theme.ink)
            let round = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }

            for cx in [99, 147, 195, 243] as [CGFloat] {
                let path = Self.polygon(Self.star).applying(base.translatedBy(x: cx, y: 20))
                context.stroke(path, with: ink, style: round(2.5 * s))
            }

            let heavy: [[(CGFloat, CGFloat)]] = [
                [(12, 190), (330, 190)],
                [(22, 190), (22, 160), (48, 160), (48, 190)],
                [(54, 190), (54, 96), (78, 96), (78, 190)],
                [(92, 190), (100, 70), (124, 70), (132, 190)],
                [(106, 70), (106, 46)], [(118, 70), (118, 46)],
                [(148, 190), (148, 122), (160, 122), (160, 84), (170, 84), (170, 40), (186, 40), (186, 84), (196, 84), (196, 122), (204, 122), (204, 190)],
                [(174, 40), (174, 14)], [(182, 40), (182, 14)],
                [(214, 190), (214, 120), (238, 120), (238, 190)],
                [(246, 190), (246, 112), (252, 112), (252, 92), (266, 92), (266, 112), (272, 112), (272, 190)],
                [(259, 92), (259, 70)],
                [(286, 190), (298, 150), (310, 190)],
            ]
            for points in heavy {
                context.stroke(Self.line(points).applying(sky), with: ink, style: round(3.5 * 0.85 * s))
            }
            let light: [[(CGFloat, CGFloat)]] = [
                [(101, 80), (127, 130)], [(123, 80), (97, 130)], [(128, 130), (93, 182)], [(96, 130), (131, 182)],
                [(298, 122), (298, 178)], [(270, 150), (326, 150)], [(278, 130), (318, 170)], [(318, 130), (278, 170)],
            ]
            for points in light {
                context.stroke(Self.line(points).applying(sky), with: ink, style: round(2 * 0.85 * s))
            }
            let wheel = Path(ellipseIn: CGRect(x: 270, y: 122, width: 56, height: 56)).applying(sky)
            context.stroke(wheel, with: ink, style: round(3.5 * 0.85 * s))

            guard course else { return }
            // The course: dotted line with an open start and a solid finish.
            let course = Self.line([(24, 220), (318, 220)]).applying(base)
            context.stroke(course, with: .color(Theme.muted.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 3 * s, lineCap: .round, dash: [1 * s, 9 * s]))
            let start = Path(ellipseIn: CGRect(x: 18.5, y: 214.5, width: 11, height: 11)).applying(base)
            context.fill(start, with: .color(Theme.background))
            context.stroke(start, with: ink, style: round(3 * s))
            let finish = Path(ellipseIn: CGRect(x: 311.5, y: 213.5, width: 13, height: 13)).applying(base)
            context.fill(finish, with: ink)
        }
        .aspectRatio(342.0 / 240.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func line(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.0, y: p.1)) }
        return path
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = line(points)
        path.closeSubpath()
        return path
    }
}
