import SwiftUI

/// The two onboarding pages as one screen, so the move from one to the other is a change of text and button
/// while the questions keep scrolling: page 1 asks for Apple Health, page 2 (the first sync already running
/// behind it) asks for Sign in with Apple.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onAccount: Bool { model.phase == .account }
    private var change: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.55) }

    var body: some View {
        VStack(spacing: 0) {
            // The text scrolls (at large Dynamic Type sizes or on small screens); the button stays reachable.
            GeometryReader { geo in
                ScrollView {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            button
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
            QuestionFeed(questions: Copy.Welcome.questions)
                .padding(.bottom, 40)
            // Both texts sit in the same place and cross-fade, the old one drifting up and the new one rising in.
            ZStack(alignment: .topLeading) {
                text(Copy.Welcome.tagline, Copy.Welcome.subtitle)
                    .riseIn(delay: 0.05)
                    .opacity(onAccount ? 0 : 1)
                    .offset(y: onAccount ? -24 : 0)
                    .accessibilityHidden(onAccount)
                text(Copy.Account.headline, Copy.Account.body)
                    .opacity(onAccount ? 1 : 0)
                    .offset(y: onAccount ? 0 : 24)
                    .accessibilityHidden(!onAccount)
            }
            .animation(change, value: onAccount)
            .padding(.bottom, 24)
            // UI tests cannot drive Apple's own sign-in sheet; this stands in for it (never shown otherwise).
            if onAccount, ProcessInfo.processInfo.arguments.contains("-uiTesting") {
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

    private func text(_ headline: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .tracking(-1.8)
                .displayText()
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .smallText()
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One slot, two buttons (both black pills): "Connect to Apple Health" fades into Apple's own button.
    private var button: some View {
        ZStack(alignment: .top) {
            connectButton
                .opacity(onAccount ? 0 : 1)
                .allowsHitTesting(!onAccount)
                .accessibilityHidden(onAccount)
            AppleSignInButton()
                .opacity(onAccount ? 1 : 0)
                .allowsHitTesting(onAccount)
                .accessibilityHidden(!onAccount)
        }
        .animation(change, value: onAccount)
    }

    private var connectButton: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.connectHealth() }
            } label: {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(Theme.buttonText) }
                    Text(Copy.Welcome.connectButton)
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.busy)
            .accessibilityIdentifier("connectHealth")
            // Progress is silent; only a stall (Apple Health not answering) is explained here.
            if model.busy, !model.connectStage.isEmpty {
                Text(model.connectStage)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("connectStage")
            }
        }
    }
}
