import SwiftUI
import UIKit

/// Consent, then three illustrated steps. Closes itself once the assistant uses the link.
struct SetupSheet: View {
    let provider: AIProvider
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var link: String?
    @State private var consented = false
    @State private var copied = false
    @State private var confirmDisconnect = false
    @State private var linkError: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.isSetUp(provider) && link == nil {
                    connectedView
                } else if link == nil && !consented {
                    consentView
                } else {
                    stepsView
                }
            }
            .navigationTitle("Connect \(provider.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear {
            link = model.existingLink(for: provider)
            if model.isSetUp(provider) { link = nil }
        }
    }

    private var consentView: some View {
        VStack(spacing: 0) {
            // Scrolls at large Dynamic Type sizes; Continue stays reachable below it.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 20) {
                        Spacer(minLength: 0)
                        Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(provider.tint.gradient)
                            .accessibilityHidden(true)
                        Text("Share your workouts with \(provider.name)?").font(.title2.bold()).multilineTextAlignment(.center)
                        Text("You'll get a private link. With it, \(provider.name) can read your workouts (including detailed measurements and GPS routes) and daily summaries whenever you ask it a question. \(provider.company) processes that data under its own terms. You can disconnect at any time.")
                            .multilineTextAlignment(.center).foregroundStyle(Theme.mutedText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VStack(spacing: 12) {
                if let linkError {
                    Label(linkError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Theme.warning).multilineTextAlignment(.center)
                        .accessibilityIdentifier("linkError")
                }
                Button {
                    Task {
                        linkError = nil
                        if let url = await model.link(for: provider) {
                            link = url
                            consented = true
                        } else {
                            // The app-level alert sits underneath this sheet, so show the reason here.
                            linkError = model.errorMessage ?? "Something went wrong. Please try again."
                            model.errorMessage = nil
                        }
                    }
                } label: {
                    HStack {
                        if model.busy { ProgressView() }
                        Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.busy)
                .accessibilityIdentifier("consentContinue")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var stepsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Array(provider.steps.enumerated()), id: \.offset) { index, step in
                    StepCard(number: index + 1, step: step, tint: provider.tint, badgeTint: provider.badgeTint) {
                        switch index {
                        case 0:
                            Button {
                                if let link {
                                    // The link is a credential: keep it off Universal Clipboard and let it expire.
                                    UIPasteboard.general.setItems([["public.utf8-plain-text": link]],
                                                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                                }
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                copied = true
                                Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    copied = false
                                }
                            } label: {
                                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("copyLink")
                        case 1:
                            Button {
                                openURL(provider.setupURL)
                            } label: {
                                Label("Open \(provider.websiteLabel)", systemImage: "safari").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("openWebsite")
                        default:
                            EmptyView()
                        }
                    }
                }
                if let tip = provider.tip {
                    Label(tip, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.mutedText)
                }
                waitingRow
            }
            .padding(20)
        }
        .task { await model.waitUntilSetUp(provider) }
        .onChange(of: model.isSetUp(provider)) { _, isSetUp in
            guard isSetUp else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            }
        }
    }

    private var waitingRow: some View {
        HStack(spacing: 12) {
            if model.isSetUp(provider) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.success)
                Text("\(provider.name) is set up").font(.headline)
            } else {
                ProgressView()
                Text("Waiting for \(provider.name) to connect…").foregroundStyle(Theme.mutedText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("waitingRow")
    }

    private var connectedView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            Text("\(provider.name) is set up").font(.title2.bold())
            Text("Ask \(provider.name) about your runs, rides, heart rate zones, pace and recovery. It reads your workout data only when you ask.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.mutedText)
            Spacer()
            Button("Disconnect \(provider.name)", role: .destructive) { confirmDisconnect = true }
                .accessibilityIdentifier("disconnect")
        }
        .padding(24)
        .confirmationDialog("Disconnect \(provider.name)?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await model.disconnect(provider)
                    dismiss()
                }
            }
        } message: {
            Text("\(provider.name) will immediately lose access. You can also remove the KROK connector in \(provider.name)'s settings.")
        }
    }
}

private struct StepCard<Actions: View>: View {
    let number: Int
    let step: AIProvider.Step
    let tint: Color
    let badgeTint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.subheadline.bold()).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(badgeTint, in: Circle())
                Text(step.title).font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(step.detail).font(.subheadline).foregroundStyle(Theme.mutedText)
            IllustrationView(kind: step.illustration, tint: tint)
            actions()
        }
    }
}
