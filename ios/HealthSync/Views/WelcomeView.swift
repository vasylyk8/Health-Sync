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
            Text("Ask Claude or ChatGPT about your Apple Health workouts.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.mutedText)
                .padding(.top, 8)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 4) {
                Text("Your workouts, with their detailed measurements and GPS routes, plus daily and hourly summaries (sleep, heart rate, steps and similar) are copied securely to our servers in the EU so the assistants you connect can read them. It also reads nutrition, heart alerts, glucose, symptoms, cycle, medication and profile data if you track them; you choose in Apple Health and can switch each group off later. Nothing is shared until you connect an assistant.")
                    .font(.footnote)
                    .foregroundStyle(Theme.mutedText)
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
        VStack(spacing: 8) {
            connectButtonBody
            if model.busy, !model.connectStage.isEmpty {
                Text(model.connectStage).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("connectStage")
            }
        }
    }

    private var connectButtonBody: some View {
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
