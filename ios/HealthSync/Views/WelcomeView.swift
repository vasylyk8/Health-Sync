import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    private let showChicago = ChicagoMarathon.isActive()

    var body: some View {
        VStack(spacing: 0) {
            // The text fits without scrolling when it can; with the art on a short screen the art is dropped, and at
            // large text sizes the text scrolls. Either way the buttons stay reachable.
            ViewThatFits(in: .vertical) {
                content(withArt: showChicago)
                    .frame(maxHeight: .infinity, alignment: .top)
                ScrollView {
                    content(withArt: false)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            connectButton
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 16)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func content(withArt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .frame(height: 44)
            Spacer(minLength: 16)
            if withArt {
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
            Text(Copy.Welcome.dataNote)
                .smallText()
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}
