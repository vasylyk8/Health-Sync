import SwiftUI

/// Home: the big rotating number, how far the sync is, and the two assistants to connect.
struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: AIProvider?
    @State private var confirmDelete = false
    @State private var showChoices = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                ScrollView {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await model.syncNow() }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(item: $selected) { provider in
            SetupSheet(provider: provider)
        }
        .sheet(isPresented: $showChoices) {
            DataChoicesView().environmentObject(model)
        }
        #if DEBUG
        .sheet(isPresented: $model.showBenchmark, onDismiss: { model.finishSpeedTest() }) {
            speedTest
        }
        #endif
        .confirmationDialog(Copy.Delete.title, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Copy.Delete.confirm, role: .destructive) { Task { await model.deleteAllData() } }
        } message: {
            Text(Copy.Delete.message)
        }
        .task { await model.refreshStatus() }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Wordmark()
            Spacer()
            Menu {
                Link(destination: Theme.supportURL) { Label(Copy.Menu.help, systemImage: "questionmark.circle") }
                Link(destination: Theme.privacyURL) { Label(Copy.Menu.privacy, systemImage: "hand.raised") }
                Button { showChoices = true } label: { Label(Copy.Menu.yourData, systemImage: "slider.horizontal.3") }
                #if DEBUG
                Button { model.runSpeedTest() } label: { Label(Copy.Menu.speedTest, systemImage: "speedometer") }
                #endif
                Button { confirmDelete = true } label: { Label(Copy.Menu.deleteAll, systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Copy.Home.moreLabel)
            .accessibilityIdentifier("moreMenu")
        }
        .padding(.leading, Theme.margin)
        .padding(.trailing, Theme.margin - 10)
        .frame(height: 44)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroMetricView(metrics: heroMetrics)
                .padding(.top, 48)
            progress
                .padding(.top, 40)
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                ForEach(model.providers) { provider in
                    ProviderPill(provider: provider, setUp: model.isSetUp(provider)) { selected = provider }
                }
            }
            .padding(.bottom, 24)
            // Below the assistants so they stay in reach; its explanation can grow at large text sizes.
            AppleAccountView(style: .home)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, Theme.margin)
    }

    private var heroMetrics: [HeroMetric] {
        HeroMetrics.make(stats: model.progress.stats, workoutsUploaded: model.progress.detailsTotal, historyStart: model.status.historyStart)
    }

    /// Sync state under the number: the step bar and estimate while syncing, otherwise how things stand.
    @ViewBuilder private var progress: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 0) {
            if p.stepsTotal > 0 && !p.historyComplete {
                StepBar(done: p.stepFlags)
                Text(model.estimate.text)
                    .bodyText(.semibold)
                    .padding(.top, 16)
                    .accessibilityIdentifier("syncEstimate")
                Text(Copy.Home.keepOpen)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
                if p.recentReady {
                    Text(Copy.Home.recentReady)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 12)
                }
            } else if p.historyComplete && model.status.typesWithData == 0 && model.status.registered {
                Text(Copy.Home.noData).bodyText(.semibold)
                Text(Copy.Home.noDataDetail)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            } else if let last = model.status.lastVisibleDate {
                Text(Copy.Home.upToDate).bodyText(.semibold)
                Text("Last synced \(last, format: .relative(presentation: .named))")
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            } else {
                Text(Copy.Home.gettingReady).bodyText(.semibold)
            }
            if let issue = model.syncIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .smallText()
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 12)
                    .accessibilityIdentifier("syncIssue")
            }
        }
    }

    #if DEBUG
    private var speedTest: some View {
        NavigationStack {
            ScrollView {
                Text(model.benchmarkText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Speed test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.benchmarkRunning { ShareLink("Share", item: model.benchmarkText) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.benchmarkRunning { ProgressView() } else { Button("Done") { model.showBenchmark = false } }
                }
            }
        }
        .interactiveDismissDisabled(model.benchmarkRunning)
    }
    #endif
}

/// One assistant as a full-width pill: "Connect Claude" until it is set up, then its name and a check mark.
struct ProviderPill: View {
    let provider: AIProvider
    let setUp: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if setUp {
                HStack {
                    Text(provider.name)
                    Spacer()
                    CheckBadge()
                }
            } else {
                Text(Copy.Home.connect(provider.name))
            }
        }
        .buttonStyle(PillButtonStyle(kind: setUp ? .secondary : .primary))
        .accessibilityLabel(setUp ? "\(provider.name), \(Copy.Home.connected)" : Copy.Home.connect(provider.name))
        .accessibilityHint(setUp ? "Shows connection details" : "Opens setup steps")
        .accessibilityValue(setUp ? "Set up" : "Not set up")
        .accessibilityIdentifier("provider.\(provider.id)")
    }
}
