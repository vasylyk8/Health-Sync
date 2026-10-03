import SwiftUI

/// Second onboarding page: Sign in with Apple. The first sync is already running while the person reads it.
struct AccountView: View {
    @EnvironmentObject var model: AppModel
    private let showChicago = ChicagoMarathon.isActive()

    var body: some View {
        VStack(spacing: 0) {
            // The text scrolls (at large Dynamic Type sizes or on small screens); the button stays reachable.
            GeometryReader { geo in
                ScrollView {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            AppleSignInButton()
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 16)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .frame(height: 44)
            Spacer(minLength: 16)
            if showChicago {
                chicago
                    .riseIn()
                // Two spacers below, one above: the art sits in the upper part of the free space.
                Spacer(minLength: 40)
                Spacer(minLength: 0)
            }
            Text(Copy.Account.headline)
                .tracking(-1.8)
                .displayText()
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .riseIn(delay: 0.05)
                .padding(.bottom, 16)
            Text(Copy.Account.body)
                .smallText()
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            // UI tests cannot drive Apple's own sign-in sheet; this stands in for it (never shown otherwise).
            if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
                Button("Continue (UI test)") {
                    Task { await model.linkAppleAccount(AppleSignInResult(idToken: "ui-test", nonce: "ui-test", authorizationCode: "ui-test")) }
                }
                .smallText()
                .accessibilityIdentifier("uiTestSignIn")
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    /// A send-off to Chicago Marathon runners, shown until race day ends.
    private var chicago: some View {
        VStack(spacing: 12) {
            ChicagoMarathonArt()
                .frame(maxWidth: 320)
            Text(Copy.Account.chicagoCaption)
                .tracking(4.5)
                .smallText(.semibold)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
