import SwiftUI
import CoreMotion

/// Reads how far the phone is tilted from where it was when the screen appeared, as -1...1 on each axis.
/// Device motion (attitude) needs no permission. Nothing happens on a simulator or a device without the sensors.
final class TiltSource: ObservableObject {
    @Published private(set) var roll = 0.0
    @Published private(set) var pitch = 0.0

    /// About 29 degrees of tilt reads as full deflection.
    static let fullDeflection = 0.5

    private let manager = CMMotionManager()
    private var reference: CMAttitude?

    /// Maps radians of tilt to -1...1.
    static func normalized(_ radians: Double) -> Double {
        max(-1, min(1, radians / fullDeflection))
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // The first reading is "flat": tilt is measured from how the person happens to hold the phone.
            guard let reference = self.reference else {
                self.reference = motion.attitude.copy() as? CMAttitude
                return
            }
            let attitude = motion.attitude
            attitude.multiply(byInverseOf: reference)
            self.roll = Self.normalized(attitude.roll)
            self.pitch = Self.normalized(attitude.pitch)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        roll = 0
        pitch = 0
    }
}

/// A few degrees of 3D tilt that follows the phone, with perspective, like the race medal's turn. Off for Reduce Motion,
/// in UI tests, and while the app is not in front.
private struct DepthTilt: ViewModifier {
    let enabled: Bool
    let degrees: Double
    @StateObject private var source = TiltSource()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var active: Bool { enabled && Motion.resolved(Motion.smooth, reduceMotion: reduceMotion) != nil }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(source.roll * degrees), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
            .rotation3DEffect(.degrees(-source.pitch * degrees), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.5)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: source.roll)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: source.pitch)
            .onAppear { update() }
            .onDisappear { source.stop() }
            .onChange(of: scenePhase) { _, _ in update() }
            .onChange(of: active) { _, _ in update() }
    }

    private func update() {
        if active && scenePhase == .active { source.start() } else { source.stop() }
    }
}

extension View {
    /// Follows the phone's tilt by up to `degrees` (a restrained 6 by default).
    func depthTilt(enabled: Bool = true, degrees: Double = 6) -> some View {
        modifier(DepthTilt(enabled: enabled, degrees: degrees))
    }
}
