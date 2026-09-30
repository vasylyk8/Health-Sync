import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: AIProvider?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.providers) { provider in
                        Button { selected = provider } label: { ProviderRow(provider: provider, setUp: model.isSetUp(provider)) }
                            .buttonStyle(.plain)
                            .accessibilityHint(model.isSetUp(provider) ? "Shows connection details" : "Opens setup steps")
                            .accessibilityIdentifier("provider.\(provider.id)")
                            .accessibilityValue(model.isSetUp(provider) ? "Set up" : "Not set up")
                    }
                } header: {
                    Text("Connect an assistant").foregroundStyle(Theme.mutedText)
                } footer: {
                    Text("Then ask it things like \"How did I sleep this week?\"").foregroundStyle(Theme.mutedText)
                }
                Section {
                    SyncStatusView(progress: model.progress, status: model.status, issue: model.syncIssue)
                }
            }
            .navigationTitle("KROK")
            .refreshable { await model.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Link(destination: Theme.supportURL) { Label("Help & Support", systemImage: "questionmark.circle") }
                        Link(destination: Theme.privacyURL) { Label("Privacy Policy", systemImage: "hand.raised") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete All My Data", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                    }
                    .accessibilityIdentifier("moreMenu")
                }
            }
            .sheet(item: $selected) { provider in
                SetupSheet(provider: provider)
            }
            .confirmationDialog("Delete all your data from KROK?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete All My Data", role: .destructive) { Task { await model.deleteAllData() } }
            } message: {
                Text("Connected assistants lose access immediately and your copy on our servers is erased. Apple Health itself is not changed.")
            }
        }
        .task { await model.refreshStatus() }
    }
}

struct ProviderRow: View {
    let provider: AIProvider
    let setUp: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(provider.tint.gradient)
                Image(systemName: provider.symbol).font(.title3.weight(.semibold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.headline).foregroundStyle(.primary)
                if let subtitle = provider.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.mutedText)
                }
            }
            Spacer()
            if setUp {
                Label("Set up", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.success)
                    .accessibilityIdentifier("setUp.\(provider.id)")
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.mutedText)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct SyncStatusView: View {
    let progress: SyncProgress
    let status: ServerStatus
    var issue: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.stepsTotal > 0 && !progress.historyComplete {
                ProgressView(value: progress.fraction) {
                    Text("\(progress.stepTitle) · \(Int(progress.fraction * 100))%").font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("syncProgress")
                if progress.recentReady {
                    Text("Your recent workouts are ready. You can already ask Claude or ChatGPT about them.")
                        .font(.footnote)
                }
                Text("Keep the app open while your workouts sync. You can connect an assistant meanwhile.")
                    .font(.footnote).foregroundStyle(Theme.mutedText)
            } else if progress.historyComplete && status.typesWithData == 0 && status.registered {
                Text("No readable Health data found").font(.subheadline.weight(.medium))
                Text("Check Settings › Health › Data Access & Devices › KROK and turn on Workouts, Workout Routes and the other categories you want to share.")
                    .font(.footnote).foregroundStyle(Theme.mutedText)
            } else if let last = status.lastVisibleDate {
                Label {
                    Text("Synced \(last, format: .relative(presentation: .named))")
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.mutedText)
                }
                .font(.subheadline)
            } else {
                Label("Getting ready…", systemImage: "hourglass").font(.subheadline)
            }
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("syncIssue")
            }
            if let start = status.historyStart {
                Text("History synced back to \(start, format: .dateTime.month(.abbreviated).year())")
                    .font(.footnote).foregroundStyle(Theme.mutedText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }
}
