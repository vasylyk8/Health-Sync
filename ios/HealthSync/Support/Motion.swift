import SwiftUI

/// One motion language for the whole app: a few named springs, one stagger step, and a single place that decides
/// whether motion is allowed at all (Reduce Motion, or the `-uiTesting` launch argument that lets Apple's accessibility
/// audit wait for a settled screen).
enum Motion {
    /// Quick, tight response: presses, toggles, small state changes.
    static let snappy = Animation.snappy(duration: 0.35)
    /// Calm default for layout and content changes.
    static let smooth = Animation.smooth(duration: 0.5)
    /// A little overshoot, for moments that should feel alive (a check landing, a pill filling).
    static let bouncy = Animation.spring(duration: 0.5, bounce: 0.25)
    /// Finger down / finger up.
    static let press = Animation.spring(duration: 0.28, bounce: 0.2)
    /// Entrance of a block of content: fast start, long gentle stop.
    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)
    /// Delay between neighbours in a staggered entrance.
    static let stagger: Double = 0.06

    /// True when launched by the UI tests.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    /// The animation to run, or nil when motion is not allowed.
    static func resolved(_ animation: Animation, reduceMotion: Bool, uiTesting: Bool = isUITesting) -> Animation? {
        reduceMotion || uiTesting ? nil : animation
    }

    /// Delay for the n-th item of a staggered entrance (the first item has none).
    static func staggerDelay(index: Int, base: Double = 0) -> Double {
        base + Double(max(index, 0)) * stagger
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that switches itself off for Reduce Motion and UI tests.
    func motion<Value: Equatable>(_ animation: Animation = Motion.smooth, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

/// Runs a state change with an animation unless motion is not allowed, in which case it applies the change instantly.
@MainActor
func withMotion<Result>(_ animation: Animation = Motion.smooth, _ body: () throws -> Result) rethrows -> Result {
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    if let resolved = Motion.resolved(animation, reduceMotion: reduceMotion) {
        return try withAnimation(resolved, body)
    }
    return try body()
}
