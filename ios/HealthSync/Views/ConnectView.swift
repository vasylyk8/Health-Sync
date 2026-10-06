import SwiftUI

/// Home: the big rotating number, how far the sync is, and the two assistants to connect.
struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: AIProvider?
    @State private var confirmDelete = false
    @State private var confirmLogOut = false
    @State private var confirmComparison = false
    /// The race medal's finish-time picker is open (the number and sync status step aside).
    @State private var editingGoal = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                ScrollView {
                    content.frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(.hidden)
                // Scrolling the finish-time picker must not drag the page into a refresh.
                .scrollDisabled(editingGoal)
                .refreshable { await model.pullToRefresh() }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(item: $selected) { provider in
            SetupSheet(provider: provider)
        }
        .sheet(isPresented: $model.showBenchmark, onDismiss: { model.finishSpeedTest() }) {
            speedTest
        }
        .confirmationDialog(Copy.LogOut.title, isPresented: $confirmLogOut, titleVisibility: .visible) {
            Button(Copy.LogOut.confirm) { Task { await model.logOut() } }
        } message: {
            Text(Copy.LogOut.message)
        }
        .confirmationDialog(Copy.Delete.title, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Copy.Delete.confirm, role: .destructive) { Task { await model.deleteAllData() } }
        } message: {
            Text(Copy.Delete.message)
        }
        .alert("Compare initial sync?", isPresented: $confirmComparison) {
            Button("Start comparison") { model.runSyncComparison() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reads your history with 1, 2 and 4 daily reads, twice each. Allow 20–40 minutes, plus cooling. Keep KROK open and unlocked. Uploads are simulated locally; your synced data is retained.")
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
                if !model.appleAccountLinked {
                    Button { Task { await model.signInWithAppleFromMenu() } } label: { Label(Copy.Menu.signIn, systemImage: "person.crop.circle") }
                }
                if Theme.isInternalBuild {
                    Button { model.runSpeedTest() } label: { Label(Copy.Menu.speedTest, systemImage: "speedometer") }
                    Button { confirmComparison = true } label: { Label("Compare initial sync", systemImage: "arrow.left.arrow.right") }
                }
                if model.appleAccountLinked {
                    Button { confirmLogOut = true } label: { Label(Copy.Menu.logOut, systemImage: "rectangle.portrait.and.arrow.right") }
                }
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

    /// The race medal (if a special edition is showing and the upload is done) replaces the big number as the
    /// main art; the number then shrinks and moves down above the buttons.
    private var activeEdition: SpecialEdition? { model.uploadFinished ? model.edition : nil }

    /// Three groups with air between them: the main art (the big number, or the medal) floats in the middle;
    /// what is happening (sync state) and what to do about it (the connect buttons) sit together at the bottom.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let edition = activeEdition {
                Spacer(minLength: 8)
                EditionMedalView(edition: edition, editing: $editingGoal)
                    .transition(.opacity)
                Spacer(minLength: editingGoal ? 0 : 40)
            } else {
                Spacer(minLength: 24)
            }
            // Kept in place (just hidden) while the picker is open, so it does not count up from 0 again afterwards.
            Group {
                HeroMetricView(metrics: heroMetrics, compact: activeEdition != nil)
                Spacer(minLength: activeEdition == nil ? 40 : 32)
                progress
            }
            .opacity(editingGoal ? 0 : 1)
            .frame(maxHeight: editingGoal ? 0 : nil)
            .clipped()
            .accessibilityHidden(editingGoal)
            if showRecentReady {
                Text(Copy.Home.recentReady)
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 24)
            }
            HStack(spacing: 12) {
                ForEach(model.providers) { provider in
                    ProviderPill(provider: provider, setUp: model.isSetUp(provider)) { selected = provider }
                }
            }
            .padding(.top, showRecentReady ? 16 : 24)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, Theme.margin)
        .animation(.easeInOut(duration: 0.6), value: activeEdition != nil)
    }

    /// While the first sync runs and recent workouts are already readable: the nudge above the connect buttons.
    private var showRecentReady: Bool {
        let p = model.progress
        return p.stepsTotal > 0 && !p.historyComplete && p.recentReady
    }

    private var heroMetrics: [HeroMetric] {
        HeroMetrics.make(stats: model.progress.stats, workoutsUploaded: model.progress.detailsTotal, historyStart: model.status.historyStart)
    }

    /// Sync state under the number: the four lines, what is being read and the time left while syncing, otherwise how things stand.
    @ViewBuilder private var progress: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 0) {
            if p.stepsTotal > 0 && !p.historyComplete {
                StepBar(lines: p.lines)
                Text(p.headline)
                    .bodyText(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                Text("\(model.estimate.text) · \(Copy.Home.keepOpen)")
                    .smallText()
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .accessibilityIdentifier("syncEstimate")
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
                // Upload hasn't begun: the first line is already loading.
                StepBar(lines: p.lines)
                Text(Copy.Home.gettingReady).bodyText(.semibold)
                    .padding(.top, 16)
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

    private var speedTest: some View {
        NavigationStack {
            ScrollView {
                Text(model.benchmarkText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(model.benchmarkTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.benchmarkRunning { ShareLink("Share", item: model.benchmarkText) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.comparisonRunning { Button("Stop") { model.stopSyncComparison() } }
                    else if model.benchmarkRunning { ProgressView() } else { Button("Done") { model.showBenchmark = false } }
                }
            }
        }
        .interactiveDismissDisabled(model.benchmarkRunning)
    }
}

/// One assistant as a half-width pill: "Connect Claude" until it is set up, then its name and a check mark.
struct ProviderPill: View {
    let provider: AIProvider
    let setUp: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if setUp {
                HStack(spacing: 8) {
                    Text(provider.name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    CheckBadge(size: 22)
                }
            } else {
                Text(Copy.Home.connect(provider.name))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(PillButtonStyle(kind: setUp ? .secondary : .primary, horizontalPadding: 12))
        .accessibilityLabel(setUp ? "\(provider.name), \(Copy.Home.connected)" : Copy.Home.connect(provider.name))
        .accessibilityHint(setUp ? "Shows connection details" : "Opens setup steps")
        .accessibilityValue(setUp ? "Set up" : "Not set up")
        .accessibilityIdentifier("provider.\(provider.id)")
    }
}
