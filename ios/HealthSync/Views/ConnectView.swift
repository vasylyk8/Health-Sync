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
                            .accessibilityIdentifier("provider.\(provider.id)")
                    }
                } header: {
                    Text("Connect an assistant")
                } footer: {
                    Text("Then ask it things like \"How did I sleep this week?\"")
                }
                Section {
                    SyncStatusView(progress: model.progress, status: model.status)
                }
            }
            .navigationTitle("Health Sync")
            .refreshable { await model.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
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
            .confirmationDialog("Delete all your data from Health Sync?", isPresented: $confirmDelete, titleVisibility: .visible) {
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
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if setUp {
                Label("Set up", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setUp.\(provider.id)")
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct SyncStatusView: View {
    let progress: SyncProgress
    let status: ServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.typesTotal > 0 && !progress.historyComplete {
                ProgressView(value: progress.fraction) {
                    Text("Syncing your history… \(Int(progress.fraction * 100))%").font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("syncProgress")
                Text("Keep the app open while your history syncs. You can connect an assistant meanwhile.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let last = status.lastVisibleDate {
                Label {
                    Text("Synced \(last, format: .relative(presentation: .named))")
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } else if progress.historyComplete && status.typesWithData == 0 && status.registered {
                Text("No readable Health data found").font(.subheadline.weight(.medium))
                Text("Check Settings › Health › Data Access & Devices › Health Sync and turn on the categories you want to share.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("Getting ready…", systemImage: "hourglass").font(.subheadline)
            }
            if let start = status.historyStart {
                Text("History synced back to \(start, format: .dateTime.month(.abbreviated).year())")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
