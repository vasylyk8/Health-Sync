import SwiftUI
import UIKit

/// Consent, then three steps. Closes itself once the assistant uses the link.
struct SetupSheet: View {
    let provider: AIProvider
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var webPage: WebPage?
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
        case .connected: return Copy.Sheet.connectedTitle(provider.name)
        case .oauth: return Copy.Sheet.connectTitle(provider.name)
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
        .fullScreenCover(item: $webPage) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
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
                        if model.busy { ProgressView().tint(Theme.buttonText) }
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
                                    webPage = WebPage(url: provider.setupURL)
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
        let chatGPT = provider.id == "chatgpt"
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    OAuthStep(number: 1, title: Copy.Sheet.oauthCopyTitle, detail: nil, isLast: false) {
                        linkCard
                    }
                    OAuthStep(number: 2, title: Copy.Sheet.oauthOpenTitle(chatGPT: chatGPT), detail: Copy.Sheet.oauthOpenDetail(chatGPT: chatGPT), isLast: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            choiceHint(chatGPT: chatGPT)
                            Button {
                                webPage = WebPage(url: provider.oauthURL)
                            } label: {
                                Label(Copy.Sheet.openSite(provider.oauthLabel), systemImage: "arrow.up.right")
                                    .labelStyle(TrailingIconLabelStyle())
                            }
                            .buttonStyle(StepActionStyle(filled: true))
                            .accessibilityIdentifier("openWebsite")
                        }
                    }
                    OAuthStep(number: 3, title: Copy.Sheet.oauthFormTitle, detail: Copy.Sheet.oauthFormDetail(chatGPT: chatGPT), isLast: false) {
                        formCard(chatGPT: chatGPT)
                    }
                    OAuthStep(number: 4, title: Copy.Sheet.oauthSignInTitle, detail: Copy.Sheet.oauthSignInDetail, isLast: true) {
                        EmptyView()
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            waitingRow
                .padding(.bottom, 16)
        }
        .closesWhenSetUp(provider: provider) { dismiss() }
    }

    /// What to tap on the assistant's own page. Outlined, so it reads as a label and not as one of our buttons.
    private func choiceHint(chatGPT: Bool) -> some View {
        FlowLayout(spacing: 6) {
            if chatGPT {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(Theme.track, lineWidth: 1))
            } else {
                Label("Add", systemImage: "plus")
                    .smallText()
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.track, lineWidth: 1))
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(height: 32)
            Text(Copy.Sheet.oauthChoice(chatGPT: chatGPT))
                .smallText()
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.track, lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Sheet.oauthChoice(chatGPT: chatGPT))
    }

    /// The values to type into the assistant's form.
    private func formCard(chatGPT: Bool) -> some View {
        var rows = [
            (Copy.Sheet.oauthName, Copy.Sheet.oauthAppName),
            (Copy.Sheet.oauthLinkField(chatGPT: chatGPT), Copy.Sheet.oauthYourLink),
        ]
        if chatGPT { rows.append((Copy.Sheet.oauthAuthField, Copy.Sheet.oauthAuthValue)) }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(row.0).smallText().foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    Text(row.1).smallText(.semibold).foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { Divider().overlay(Theme.track) }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The KROK server link and its Copy button in one card (the middle of a long link is shortened).
    private var linkCard: some View {
        let url = Theme.mcpURL.absoluteString.replacingOccurrences(of: "https://", with: "")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(url)
                    .smallText()
                    .monospaced()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = Theme.mcpURL.absoluteString
                    Haptics.success()
                    copied = true
                } label: {
                    Label(copied ? Copy.Sheet.copied : Copy.Sheet.copy, systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(StepActionStyle(filled: true))
                .accessibilityIdentifier("copyOAuthURL")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if copied {
                Text(Copy.Sheet.copied)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("oauthCopied")
            }
        }
    }

    // MARK: Connected

    private var connectedView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Copy.Sheet.connectedLead(provider.name))
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Copy.Sheet.askYourAI)
                        .tracking(4.5)
                        .smallText(.semibold)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 32)
                        .padding(.bottom, 16)
                    VStack(alignment: .trailing, spacing: 10) {
                        ForEach(exampleQuestions, id: \.self) { question in
                            Text(question)
                                .bodyText()
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    Theme.surface,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                                .frame(maxWidth: 300, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.top, 8)
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

    /// Example questions: the race question first when a goal is set, then general ones.
    private var exampleQuestions: [String] {
        var list = Copy.Sheet.exampleQuestions
        if let edition = model.edition, let goal = model.goalSeconds {
            list.insert(edition.prompt(SpecialEdition.timeText(seconds: goal)), at: 0)
        }
        return list.filter { !$0.isEmpty }
    }
}

/// One step of the connect sheet: a numbered dot joined to the next one by a line.
private struct OAuthStep<Content: View>: View {
    let number: Int
    let title: String
    let detail: String?
    let isLast: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .smallText(.semibold)
                .foregroundStyle(Theme.onInk)
                .frame(width: 28, height: 28)
                .background(Theme.ink, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bodyText(.semibold)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
                    .padding(.top, 12)
            }
            .padding(.bottom, isLast ? 0 : 28)
        }
        .background(alignment: .topLeading) {
            if !isLast {
                // The line from this dot down to the next one.
                Rectangle()
                    .fill(Theme.track)
                    .frame(width: 2)
                    .padding(.top, 36)
                    .padding(.leading, 13)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// Title first, then the icon (the arrow of "Open claude.ai").
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
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
