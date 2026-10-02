import SwiftUI
import UIKit

/// Design tokens: a neutral grey ramp (no accent colour), a short type scale, two font weights.
/// Values come from the approved design (light, dark).
enum Theme {
    // MARK: Colour

    /// Screen background.
    static let background = dynamic(0xFFFFFF, 0x141414)
    /// Text and filled buttons.
    static let ink = dynamic(0x3A3A3C, 0xEDEDED)
    /// Text on an ink-filled button.
    static let onInk = background
    /// Secondary text (5:1 or better on the background).
    static let muted = dynamic(0x6E6E73, 0x98989D)
    /// Cards, secondary buttons and chips.
    static let surface = dynamic(0xF4F4F5, 0x242424)
    /// Unfilled step segments, spinner rings and other quiet strokes.
    static let track = dynamic(0xD8D8DC, 0x3C3C3E)

    /// Tint for system controls (menus, links, progress views).
    static let accent = ink
    /// Kept for existing call sites.
    static let mutedText = muted

    /// Set at build time from the deployed site (Info.plist key PrivacyPolicyURL).
    static let privacyURL: URL = (Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String).flatMap(URL.init(string:))
        ?? URL(string: "https://krok-1d60a.web.app/privacy")!
    static var supportURL: URL { privacyURL.deletingLastPathComponent().appendingPathComponent("support") }

    /// The public MCP endpoint people paste into an assistant when they sign in with Apple.
    static let mcpURL: URL = (Bundle.main.object(forInfoDictionaryKey: "MCPServerURL") as? String).flatMap(URL.init(string:))
        ?? URL(string: "https://krok-1d60a.firebaseapp.com/mcp")!

    // MARK: Metrics

    /// Side margin of every screen.
    static let margin: CGFloat = 24
    /// Height of a full-width pill button.
    static let pillHeight: CGFloat = 56
    /// Corner radius shared by the main buttons and Apple's sign-in button.
    static let buttonRadius: CGFloat = 14
    /// Corner radius of the sheet.
    static let sheetRadius: CGFloat = 38

    /// True in debug and TestFlight builds, false in the App Store release (its receipt is not a sandbox receipt).
    static let isInternalBuild: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: Type scale

/// A system font at a fixed design size that still follows the user's text size setting.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    /// 15 pt: captions, details, small labels.
    func smallText(_ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledSystemFont(size: 15, weight: weight, style: .subheadline))
    }

    /// 17 pt: buttons, body text, step titles.
    func bodyText(_ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledSystemFont(size: 17, weight: weight, style: .body))
    }

    /// 24 pt: headlines (metric label, sheet titles).
    func headlineText() -> some View {
        modifier(ScaledSystemFont(size: 24, weight: .semibold, style: .title2))
    }

    /// 44 pt: the Welcome tagline.
    func displayText() -> some View {
        modifier(ScaledSystemFont(size: 44, weight: .semibold, style: .largeTitle))
    }
}
