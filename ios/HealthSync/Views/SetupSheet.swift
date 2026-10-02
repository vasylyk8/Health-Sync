import SwiftUI
import UIKit

/// Consent, then three steps. Closes itself once the assistant uses the link.
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

    private enum Screen { case consent, steps, connected, oauth }

    private var screen: Screen {
        if model.isSetUp(provider) && link == nil { return .connected }
        if model.appleAccountLinked { return .oauth }
        if link == nil && !consented { return .consent }
        return .steps
    }

    private var title: String {
        switch screen {
        case .consent: return Copy.Sheet.consentTitle(provider.name)
        case .steps: return Copy.Sheet.connectTitle(provider.name)
        case .connected: return Copy.Sheet.isSetUp(provider.name)
        case .oauth: return Copy.Sheet.authorizeTitle(provider.name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch screen {
            case .consent: consentView
            case .steps: stepsView
            case .connected: connectedView
            case .oauth: oauthView
            }
        }
        .padding(.horizontal, Theme.margin)
        .background(Theme.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.sheetRadius)
        .presentationBackground(Theme.background)
        .onAppear {
            link = model.existingLink(for: provider)
            if model.isSetUp(provider) { link = nil }
        }
    }

    private var header: some View {
        SheetHeader(title: title) { dismiss() }
    }

    // MARK: Consent

    private var consentView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Copy.Sheet.consentBody(provider.name))
                        .bodyText()
                        .foregroundStyle(Theme.ink)
                    Text(Copy.Sheet.consentTerms(provider.company))
                        .bodyText()
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 12) {
                if let linkError {
                    Label(linkError, systemImage: "exclamationmark.triangle.fill")
                        .smallText()
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
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
                            linkError = model.errorMessage ?? Copy.Sheet.genericError
                            model.errorMessage = nil
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if model.busy { ProgressView().tint(Theme.onInk) }
                        Text(Copy.Sheet.continueButton)
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.busy)
                .accessibilityIdentifier("consentContinue")
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: Steps

    private var stepsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let notice = provider.notice {
                        Label {
                            Text(notice).smallText().foregroundStyle(Theme.ink)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(Theme.ink)
                        }
                    }
                    ForEach(Array(provider.steps.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, step: step) {
                            switch index {
                            case 0:
                                Button(action: copyLink) {
                                    Label(copied ? Copy.Sheet.copied : Copy.Sheet.copyLink, systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(StepActionStyle(filled: true))
                                .accessibilityIdentifier("copyLink")
                            case 1:
                                Button {
                                    openURL(provider.setupURL)
                                } label: {
                                    Label(Copy.Sheet.openSite(provider.websiteLabel), systemImage: "arrow.up.right")
                                }
                                .buttonStyle(StepActionStyle(filled: false))
                                .accessibilityIdentifier("openWebsite")
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            waitingRow
                .padding(.bottom, 16)
        }
        .closesWhenSetUp(provider: provider) { dismiss() }
    }

    private func copyLink() {
        if let link {
            // The link is a credential: keep it off Universal Clipboard and let it expire.
            UIPasteboard.general.setItems([["public.utf8-plain-text": link]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        }
        Haptics.success()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            copied = false
        }
    }

    private var waitingRow: some View {
        HStack(spacing: 12) {
            if model.isSetUp(provider) {
                CheckBadge()
                Text(Copy.Sheet.isSetUp(provider.name))
                    .bodyText(.semibold)
                    .foregroundStyle(Theme.ink)
            } else {
                ProgressView()
                Text(Copy.Sheet.waiting(provider.name))
                    .smallText()
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.pillHeight)
        .background(Theme.surface, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("waitingRow")
    }

    // MARK: Sign in with Apple (public connector)

    private var oauthView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(Copy.Sheet.oauthIntro)
                        .bodyText()
                        .foregroundStyle(Theme.ink)
                    Text(Copy.Sheet.oauthPending)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                    Text(Theme.mcpURL.absoluteString)
                        .smallText()
                        .monospaced()
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = Theme.mcpURL.absoluteString
                            Haptics.success()
                            copied = true
                        } label: {
                            Label(Copy.Sheet.copyServerURL, systemImage: "doc.on.doc")
                        }
                        .buttonStyle(StepActionStyle(filled: true))
                        .accessibilityIdentifier("copyOAuthURL")
                        if copied {
                            Text(Copy.Sheet.copied)
                                .smallText()
                                .foregroundStyle(Theme.muted)
                                .accessibilityIdentifier("oauthCopied")
                        }
                    }
                    Button {
                        openURL(provider.setupURL)
                    } label: {
                        Label(Copy.Sheet.openSite(provider.websiteLabel), systemImage: "arrow.up.right")
                    }
                    .buttonStyle(StepActionStyle(filled: false))
                    .accessibilityIdentifier("openWebsite")
                    Text(Copy.Sheet.oauthHowTo(chatGPT: provider.id == "chatgpt"))
                        .bodyText()
                        .foregroundStyle(Theme.ink)
                    Text(Copy.Sheet.oauthWarning)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            waitingRow
                .padding(.bottom, 16)
        }
        .closesWhenSetUp(provider: provider) { dismiss() }
    }

    // MARK: Connected

    private var connectedView: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(Copy.Sheet.connectedBody(provider.name))
                    .bodyText()
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button(Copy.Sheet.disconnect(provider.name)) { confirmDisconnect = true }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .accessibilityIdentifier("disconnect")
                .padding(.vertical, 16)
        }
        .confirmationDialog(Copy.Sheet.disconnectTitle(provider.name), isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(Copy.Sheet.disconnectConfirm, role: .destructive) {
                Task {
                    await model.disconnect(provider)
                    dismiss()
                }
            }
        } message: {
            Text(Copy.Sheet.disconnectMessage(provider.name))
        }
    }
}

private struct StepRow<Actions: View>: View {
    let number: Int
    let step: AIProvider.Step
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .smallText(.semibold)
                .foregroundStyle(Theme.onInk)
                .frame(width: 28, height: 28)
                .background(Theme.ink, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .bodyText(.semibold)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(step.detail)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.chips.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(step.chips, id: \.self) { chip in
                            Text(chip)
                                .smallText()
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.top, 12)
                }
                actions()
                    .padding(.top, 12)
            }
        }
    }
}

private extension View {
    /// Waits for the assistant to start using the connection, then closes the sheet with a short confirmation.
    func closesWhenSetUp(provider: AIProvider, dismiss: @escaping () -> Void) -> some View {
        modifier(ClosesWhenSetUp(provider: provider, dismiss: dismiss))
    }
}

private struct ClosesWhenSetUp: ViewModifier {
    let provider: AIProvider
    let dismiss: () -> Void
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .task { await model.waitUntilSetUp(provider) }
            .onChange(of: model.isSetUp(provider)) { _, isSetUp in
                guard isSetUp else { return }
                Haptics.success()
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    dismiss()
                }
            }
    }
}
