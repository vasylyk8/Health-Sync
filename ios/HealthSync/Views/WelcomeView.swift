import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // The text scrolls (at large Dynamic Type sizes or on small screens); the button stays reachable.
            GeometryReader { geo in
                ScrollView {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            connectButton
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 88))
                .foregroundStyle(Theme.accent.gradient)
                .accessibilityHidden(true)
            Text("KROK")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)
            Text("Ask Claude or ChatGPT about your Apple Health data.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 4) {
                Text("Your Health data is copied securely to our servers in the EU so the assistants you connect can read it. Nothing is shared until you connect one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Link("Privacy Policy", destination: Theme.privacyURL)
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 24)
        }
    }

    private var connectButton: some View {
        Button {
            Task { await model.connectHealth() }
        } label: {
            HStack {
                if model.busy { ProgressView().tint(.white) }
                Text("Connect to Apple Health")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.busy)
        .accessibilityIdentifier("connectHealth")
    }
}
