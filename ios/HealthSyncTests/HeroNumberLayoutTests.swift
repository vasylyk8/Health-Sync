import XCTest
import SwiftUI
@testable import HealthSync

/// The big number must take exactly the room its digits take (plus a small margin), so the unit beside it never
/// overlaps the last digit and never drifts away from it.
@MainActor
final class HeroNumberLayoutTests: XCTestCase {
    private func width<V: View>(of view: V) -> CGFloat {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 2000, height: 2000)).width
    }

    func testNumberIsAsWideAsItsTightenedDigitsPlusTheTrailingMargin() {
        for (value, size): (Double, CGFloat) in [(12_400_000, 148), (73, 176), (1_500_000, 124), (36, 176), (5_555, 148)] {
            let spec = NumberSpec.make(for: value, wholeNumber: value < 10_000)
            let bare = Text(spec.text(value))
                .tracking(-size * CountingNumber.trackingShare)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            let expected = width(of: bare) + size * CountingNumber.trailingShare
            let actual = width(of: CountingNumber(value: value, spec: spec, size: size))
            XCTAssertEqual(actual, expected, accuracy: 1.5, "value \(value) at size \(size)")
        }
    }

    func testGuardSpaceHasRealWidthAndIsMeasuredFromTheFont() {
        XCTAssertGreaterThan(CountingNumber.guardSpaceWidth(size: 100), 5)
        XCTAssertEqual(CountingNumber.guardSpaceWidth(size: 200), CountingNumber.guardSpaceWidth(size: 100) * 2, accuracy: 1.0)
    }
}
