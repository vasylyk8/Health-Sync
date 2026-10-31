import SwiftUI

/// The two onboarding pages as one screen: the questions keep scrolling while the text slides from page 1 (Apple
/// Health) to page 2 (Sign in with Apple, the first sync already running behind it). Once Apple Health is
/// connected the button shows a check for a moment, then the text slides and the button becomes Apple's.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onAccount: Bool { model.phase == .account }
    /// Page 2 is on screen (the text has slid); `onAccount` turns true a moment earlier, while the check shows.
    @State private var slid: Bool
    /// "Apple Health connected" shows on page 2 for a few seconds, then fades (its space stays).
    @State private var badgeShown = true
    private var change: Animation? { Motion.resolved(.smooth(duration: 0.55), reduceMotion: reduceMotion) }
    private static let uiTesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
    @State private var showReviewSignIn = false

    init(startOnAccount: Bool = false) {
        _slid = State(initialValue: startOnAccount)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The text scrolls (at large Dynamic Type sizes or on small screens); the button stays reachable.
            GeometryReader { geo in
                ScrollView {
                    content(width: geo.size.width).frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            button
                .staggeredReveal(index: 3, base: 0.1)
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, onAccount ? 16 : 4)
            if !onAccount {
                // Visible and plainly labeled: App Review signs in here with the test account (no Apple Account or Health data).
                Button { showReviewSignIn = true } label: {
                    Text(Copy.Review.link)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 8)
                .accessibilityIdentifier("reviewLink")
            }
        }
        .sheet(isPresented: $showReviewSignIn) { ReviewSignInView() }
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: model.phase) { _, phase in
            guard phase == .account else { return }
            if reduceMotion || Self.uiTesting {
                slid = true
            } else {
                Haptics.success()
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    withAnimation(.smooth(duration: 0.7)) { slid = true }
                }
            }
        }
        .task(id: slid) {
            guard slid, !Self.uiTesting else { return }
            badgeShown = true
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Motion.smooth) { badgeShown = false }
        }
    }

    private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .frame(height: 44)
            Spacer(minLength: 16)
            QuestionFeed(questions: Copy.Welcome.questions)
                .staggeredReveal(index: 1)
                .padding(.bottom, 40)
            // Both texts sit in the same place: the first slides out to the left, the second in from the right.
            ZStack(alignment: .topLeading) {
                text(Copy.Welcome.tagline, Copy.Welcome.subtitle)
                    .staggeredReveal(index: 2, base: 0.05)
                    .offset(x: slid ? -width : 0)
                    .opacity(slid ? 0 : 1)
                    .blur(radius: slid ? 6 : 0)
                    .accessibilityHidden(slid)
                text(Copy.Account.headline, Copy.Account.body, badge: Copy.Account.connected)
                    .offset(x: slid ? 0 : width)
                    .opacity(slid ? 1 : 0)
                    .blur(radius: slid ? 0 : 6)
                    .accessibilityHidden(!slid)
            }
            .padding(.bottom, 24)
            // UI tests cannot drive Apple's own sign-in sheet; this stands in for it (never shown otherwise).
            if slid, Self.uiTesting {
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

    private func text(_ headline: String, _ body: String, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let badge {
                // Confirms the step that was just done; it fades after a few seconds and keeps its space.
                Label {
                    Text(badge).smallText(.semibold).foregroundStyle(Theme.ink)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                }
                .padding(.bottom, 4)
                .opacity(badgeShown ? 1 : 0)
                .accessibilityHidden(!badgeShown)
            }
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

    /// One slot, three states (all black pills): "Connect to Apple Health", then a check ("Connected") while the text
    /// slides, then Apple's own button.
    private var button: some View {
        ZStack(alignment: .top) {
            // Each is in the tree only in its own state (fading in and out), so the others never linger for
            // accessibility or UI tests.
            if !onAccount {
                connectButton
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if onAccount && !slid {
                ConnectedPill()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            // Apple's button is never altered: while the sign-in runs it is swapped for a plain pill (no Apple logo or wording).
            if slid && !model.busy {
                AppleSignInButton()
                    .transition(.opacity)
            }
            if slid && model.busy {
                signingInPill
                    .transition(.opacity)
            }
        }
        .animation(change, value: onAccount)
        .animation(change, value: slid)
    }

    private var signingInPill: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.buttonText)
            Text(Copy.Account.signingIn)
        }
        .bodyText(.semibold)
        .foregroundStyle(Theme.buttonText)
        .frame(maxWidth: .infinity, minHeight: Theme.pillHeight)
        .background(Theme.buttonFill, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signingIn")
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

/// The black "Connected" pill. Its check bounces once as the pill lands (not with Reduce Motion), with a success tick.
private struct ConnectedPill: View {
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(Copy.Welcome.connectedButton)
        } icon: {
            Image(systemName: "checkmark")
                .symbolEffect(.bounce, options: .nonRepeating, value: landed)
        }
        .bodyText(.semibold)
        .foregroundStyle(Theme.buttonText)
        .frame(maxWidth: .infinity, minHeight: Theme.pillHeight)
        .background(Theme.buttonFill, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .onAppear {
            guard Motion.resolved(Motion.bouncy, reduceMotion: reduceMotion) != nil else { return }
            landed = true
        }
    }
}
