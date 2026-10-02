import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    private let showChicago = ChicagoMarathon.isActive()

    var body: some View {
        VStack(spacing: 0) {
            // The text scrolls (at large Dynamic Type sizes or on small screens); the buttons stay reachable.
            GeometryReader { geo in
                ScrollView {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            connectButton
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
                Spacer(minLength: 16)
            }
            Text(Copy.Welcome.tagline)
                .tracking(-1.8)
                .displayText()
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .riseIn(delay: 0.05)
                .padding(.bottom, 16)
            // In the scrolling part: pinned next to the buttons it would push them off screen at large text sizes.
            Text(Copy.Welcome.dataNote)
                .smallText()
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, Theme.margin)
    }

    private var chicago: some View {
        VStack(spacing: 12) {
            ChicagoMarathonArt()
                .frame(maxWidth: 280)
            VStack(spacing: 2) {
                Text(Copy.Welcome.chicagoCaption)
                    .tracking(4.5)
                    .smallText(.semibold)
                Text(Copy.Welcome.chicagoDate)
                    .tracking(1.5)
                    .smallText()
            }
            .foregroundStyle(Theme.muted)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectButton: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.connectHealth() }
            } label: {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(Theme.onInk) }
                    Text(Copy.Welcome.connectButton)
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.busy)
            .accessibilityIdentifier("connectHealth")
            if model.busy, !model.connectStage.isEmpty {
                Text(model.connectStage)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("connectStage")
            }
            AppleAccountView(style: .welcome)
        }
    }
}
