import BackgroundTasks
import SwiftUI
import UIKit

/// App state and actions. Views stay dumb; everything testable lives here.
@MainActor
final class AppModel: ObservableObject {
    /// welcome → account (Apple sign-in, while the first sync already runs) → home.
    enum Phase { case welcome, account, home }

    @Published var phase: Phase
    @Published var status: ServerStatus = .empty
    @Published var progress = SyncProgress(detailsDone: 0, detailsTotal: 0, isSyncing: false) {
        didSet {
            keepScreenAwakeDuringFirstSync()
            updateEstimate()
            if progress.historyComplete, !uploadFinished {
                uploadFinished = true
                defaults.set(true, forKey: Self.uploadFinishedKey)
            }
        }
    }
    /// Rough time left for the first sync, in coarse steps (see `SyncEstimator`).
    @Published private(set) var estimate = SyncEstimate()
    private var estimator = SyncEstimator()
    @Published var errorMessage: String?
    @Published var busy = false
    @Published var appleAccountLinked = false
    private let appleSignIn = AppleSignIn()
    /// What the connect button is waiting for right now (shown under it), so a stall can be told apart.
    @Published var connectStage = ""
    /// Shown under the sync status when the last sync attempt failed; cleared by the next success.
    @Published var syncIssue: String?

    /// Result of the read-speed test (shown in a sheet); the sync is paused while it runs.
    @Published var benchmarkText = ""
    @Published var benchmarkRunning = false
    @Published var showBenchmark = false
    private var syncTask: Task<Void, Never>?

    let providers = AIProvider.all
    private let backend: Backend
    private let source: HealthSource
    private let engine: SyncEngine
    private let outbox: Outbox
    private let scope: SyncScope
    private let telemetry: Telemetry
    private let defaults: UserDefaults
    private let appVersion: String
    private let consent: ConsentStore
    /// Data categories switched on (core is always on).
    @Published private(set) var enabledCategories: Set<String> = ["core"]
    private var started = false
    private var observing = false
    private var medicationTask: Task<Void, Never>?
    static let healthConnectedKey = "healthConnected"
    /// Set once Health is connected until Sign in with Apple is done (the app reopens on the account page).
    static let pendingAccountKey = "pendingAccount"
    /// The anonymous account created during onboarding; the only one Sign in with Apple may replace on a restore.
    static let onboardingUidKey = "onboardingUid"
    /// The account this phone's outbox (what was already uploaded) belongs to.
    static let syncedUidKey = "syncedUid"
    /// Set once the first upload has finished, so Home opens straight into its finished look.
    static let uploadFinishedKey = "uploadFinished"

    /// The special edition (race medal) showing on Home, if any.
    var edition: SpecialEdition?
    /// The expected finish time the person entered for `edition`, in seconds.
    @Published private(set) var goalSeconds: Int?
    /// True from the moment the first upload has finished.
    @Published private(set) var uploadFinished: Bool
    private var goals: RaceGoalStore { RaceGoalStore(defaults: defaults) }

    init(backend: Backend, source: HealthSource, outbox: Outbox, scope: SyncScope, telemetry: Telemetry, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.source = source
        self.outbox = outbox
        self.scope = scope
        self.telemetry = telemetry
        self.defaults = defaults
        let edition = SpecialEdition.active()
        self.edition = edition
        goalSeconds = edition.flatMap { RaceGoalStore(defaults: defaults).goal(for: $0.id) }
        uploadFinished = defaults.bool(forKey: Self.uploadFinishedKey)
        let defaultCategories = Set(scope.categories.filter { $0.default == true }.map(\.id))
        let consent = ConsentStore(defaults: defaults, fallback: defaultCategories)
        self.consent = consent
        enabledCategories = consent.enabled
        var config = SyncEngine.Config()
        config.device = UIDevice.current.model
        config.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        appVersion = config.appVersion
        engine = SyncEngine(source: source, uploader: backend, outbox: outbox, scope: scope, config: config, telemetry: telemetry, categories: { consent.enabled })
        if !defaults.bool(forKey: Self.healthConnectedKey) {
            phase = .welcome
        } else {
            phase = defaults.bool(forKey: Self.pendingAccountKey) ? .account : .home
        }
    }

    /// The first sync only makes progress while the phone is unlocked (HealthKit data is unreadable
    /// when it locks), so keep the screen on until the history is in. Normal syncs don't need this.
    private func keepScreenAwakeDuringFirstSync() {
        let firstSync = progress.isSyncing && !progress.historyComplete
        if UIApplication.shared.isIdleTimerDisabled != firstSync { UIApplication.shared.isIdleTimerDisabled = firstSync }
    }

    private func updateEstimate() {
        estimator.record(detailsDone: progress.detailsDone, detailsTotal: progress.detailsTotal,
                         historyComplete: progress.historyComplete, now: ProcessInfo.processInfo.systemUptime)
        if estimator.estimate != estimate { estimate = estimator.estimate }
    }

    /// Analytics is deliberately fail-open and never delays a product action.
    private func reportProductEvent(_ name: String, outcome: String? = nil, durationMs: Int? = nil) {
        let backend = self.backend, version = appVersion
        Task { try? await backend.recordProductEvent(name: name, appVersion: version, outcome: outcome, durationMs: durationMs) }
    }

    /// Saves the running totals (called when the app goes to the background).
    func flushStats() {
        Task { await engine.flushStats() }
    }

    // MARK: Onboarding

    func connectHealth() async {
        busy = true
        defer {
            busy = false
            connectStage = ""
        }
        // Which step failed, so a failure can be told apart (Health permission, sign-in, registration).
        var stage = "start"
        do {
            // Best effort and intentionally before Health permission: this measures permission-flow drop-off.
            reportProductEvent("health_connect_started")
            guard source.isAvailable else {
                errorMessage = "Apple Health isn't available on this device."
                return
            }
            // HealthKit never reveals which read permissions were granted; we proceed either way
            // and show "No readable Health data found" later if nothing arrives.
            // First connection: the default data groups are on (changeable in ••• → Your data).
            let firstChoice = !consent.hasChoice
            consent.persist()
            enabledCategories = consent.enabled
            stage = "health-permission"
            // Only a stall is shown (progress is silent): if Apple Health neither shows its permission screen nor
            // answers, say what to do instead of spinning silently (seen on a real iPhone after many reinstalls).
            // This covers the main permission sheet only; the separate medications sheet comes later.
            let hint = Task { @MainActor [weak self, delay = permissionHintDelay] in
                try await Task.sleep(for: delay)
                self?.connectStage = Self.permissionStallHint
            }
            defer { hint.cancel() }
            try await source.requestAuthorization(scope: scope, categories: consent.enabled)
            hint.cancel()
            connectStage = ""
            stage = "sign-in"
            let backend = self.backend
            let uid = try await Self.withTimeout(seconds: 25) { try await backend.signIn() }
            stage = "register"
            let tz = TimeZone.current.identifier
            try await Self.withTimeout(seconds: 25) { try await backend.registerDevice(timeZone: tz) }
            if firstChoice {
                let chosen = consent.enabled.sorted()
                try await Self.withTimeout(seconds: 25) { try await backend.setCategories(chosen) }
            }
            defaults.set(true, forKey: Self.healthConnectedKey)
            defaults.set(true, forKey: Self.pendingAccountKey)
            defaults.set(uid, forKey: Self.onboardingUidKey)
            defaults.set(uid, forKey: Self.syncedUidKey)
            telemetry.event("health_connected")
            reportProductEvent("health_connected")
            busy = false
            withAnimation { phase = .account }
            // The upload starts now, while the person is on the account page.
            start()
            requestMedicationsInBackground()
        } catch {
            let ns = error as NSError
            telemetry.nonFatal("connect.\(stage)", code: ns.code)
            // The step and error code carry no health data; they make a failure diagnosable from a screenshot.
            // HealthKit's own text names the problem (for example which data type it refused); it contains no health data.
            let detail = ns.domain == "com.apple.healthkit" ? " \(ns.localizedDescription)" : ""
            errorMessage = friendly(error) + "\n\n(\(stage): \(ns.domain) \(ns.code))\(detail)"
        }
    }

    /// Apple's per-medication sheet comes after the main permission sheet and never blocks or fails onboarding:
    /// it runs on its own with a timeout, and the medication list is uploaded by the next sync pass.
    func requestMedicationsInBackground() {
        guard consent.isOn("medications"), medicationTask == nil else { return }
        let source = self.source
        medicationTask = Task { [weak self] in
            await Self.finishWithin(seconds: 90) { await source.requestMedicationAuthorization() }
            guard let self else { return }
            self.medicationTask = nil
            if self.phase != .welcome, !self.progress.isSyncing { self.syncTask = Task { await self.syncNow() } }
        }
    }

    /// How long to wait for Apple Health before showing `permissionStallHint` (tests shorten it).
    var permissionHintDelay: Duration = .seconds(12)
    static let permissionStallHint = "Apple Health isn't responding. If you don't see its permission screen, restart your iPhone, then open KROK and try again."

    private struct StepTimeout: LocalizedError {
        var errorDescription: String? { "This is taking too long. Check your connection and try again." }
    }

    /// Returns when `work` finishes or after `seconds`, whichever comes first (an unanswered system sheet is left behind
    /// rather than waited for; a task group would wait for it).
    private static func finishWithin(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        let gate = OneShot()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable () -> Void = { if gate.take() { continuation.resume() } }
            Task.detached {
                await work()
                finish()
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                finish()
            }
        }
    }

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
    }

    /// Fails instead of waiting forever when a network step stalls.
    private static func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw StepTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Lifecycle

    /// Called on launch (when already onboarded) and whenever the app becomes active.
    func start() {
        reportProductEvent("app_opened")
        guard phase != .welcome, !benchmarkRunning else { return }
        Task { await engine.onProgress { p in Task { @MainActor in self.progress = p } } }
        startObservers()
        syncTask = Task { await syncNow() }
        Task { await sendGoalIfPending() }
    }

    /// Saves the expected finish time (kept on the phone, and sent to the server so the person's AI can use it).
    func saveGoal(seconds: Int) {
        guard let edition, SpecialEdition.secondsRange.contains(seconds) else { return }
        goals.save(seconds, for: edition.id)
        goalSeconds = seconds
        Task { await sendGoalIfPending() }
    }

    /// Sends the goal if the server does not have it yet; a failure leaves it to the next app start.
    func sendGoalIfPending() async {
        guard let edition, goals.isPending(edition.id), let seconds = goals.goal(for: edition.id) else { return }
        do {
            try await backend.setRaceGoal(raceId: edition.id, raceName: edition.raceName, raceDate: edition.raceDate, goalSeconds: seconds)
            // Changed again while sending: the newer value is still pending.
            if goals.goal(for: edition.id) == seconds { goals.markSent(edition.id) }
        } catch {
            telemetry.nonFatal("goal.send", code: (error as NSError).code)
        }
    }

    /// Pauses the sync (it resumes where it left off), measures HealthKit read speed, then resumes.
    func runSpeedTest() {
        guard !benchmarkRunning else { return }
        benchmarkRunning = true
        benchmarkText = "Pausing sync…"
        showBenchmark = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            syncTask?.cancel()
            await syncTask?.value
            syncTask = nil
            await source.benchmark { text in Task { @MainActor in self.benchmarkText = text } }
            benchmarkRunning = false
        }
    }

    /// Closing the results resumes the sync.
    func finishSpeedTest() {
        showBenchmark = false
        guard !benchmarkRunning else { return }
        start()
    }

    /// Registers the HealthKit observers that let iOS wake the app for new data. Must also run when
    /// iOS relaunches the app in the background (before any screen appears), so the app calls it
    /// at launch, not only when a scene becomes active.
    func startObservers() {
        guard phase != .welcome, !observing else { return }
        observing = true
        let engine = self.engine
        source.observeWorkouts { done in
            Task {
                try? await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(20))
                done()
            }
        }
        observeOtherData()
    }

    /// Background wake-ups for heart rate, steps and the extra data groups that are switched on (also after one is switched on).
    private func observeOtherData() {
        let engine = self.engine
        source.observeOtherData(categories: consent.enabled) { done in
            Task {
                try? await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(20))
                done()
            }
        }
    }

    /// An existing install that never made a choice gets the default data groups the first time it runs this version.
    private func applyDefaultCategoriesIfNeeded() async {
        guard !consent.hasChoice else { return }
        consent.persist()
        enabledCategories = consent.enabled
        let chosen = consent.enabled
        do {
            try await source.requestAuthorization(scope: scope, categories: chosen)
            requestMedicationsInBackground()
            try await backend.setCategories(chosen.sorted())
            for id in chosen where id != "core" { try await engine.categoryEnabled(id) }
            observeOtherData()
        } catch {
            // Try again next time: forget the stored choice so the defaults are applied again.
            defaults.removeObject(forKey: ConsentStore.key)
        }
    }

    /// Pull down to refresh: starts a sync if none is running and returns after a moment, so the spinner never hangs
    /// for the minutes a large sync can take (a refresh that is still "in progress" ignores further pulls).
    func pullToRefresh() async {
        await refreshStatus()
        if !progress.isSyncing {
            syncTask?.cancel()
            syncTask = Task { await syncNow() }
        }
        try? await Task.sleep(for: .seconds(2))
    }

    /// Signs in and checks the account is the one this phone's outbox belongs to. If the account changed (for example the
    /// old one was deleted on the server and the app fell back to a new anonymous one), what was "already uploaded" went to
    /// the old account: register the new one and start the first sync over. Returns true when that happened.
    @discardableResult
    func ensureCurrentAccount() async throws -> Bool {
        let uid = try await backend.signIn()
        defer { defaults.set(uid, forKey: Self.syncedUidKey) }
        guard let known = defaults.string(forKey: Self.syncedUidKey), known != uid else { return false }
        try await startOverOnRestoredAccount()
        return true
    }

    func syncNow() async {
        let syncStarted = ProcessInfo.processInfo.systemUptime
        do {
            try await ensureCurrentAccount()
            appleAccountLinked = await backend.hasAppleAccount()
            if !started {
                started = true
                try await backend.registerDevice(timeZone: TimeZone.current.identifier)
            }
            await refreshStatus()
            await applyDefaultCategoriesIfNeeded()
            // A background wake-up may be using the engine for a moment; wait for it instead of skipping the sync.
            var outcome = try await engine.run()
            var waits = 0
            while outcome == .alreadyRunning && waits < 6 {
                waits += 1
                try await Task.sleep(for: .seconds(5))
                outcome = try await engine.run()
            }
            await refreshStatus()
            syncIssue = nil
            let duration = Int(max(0, (ProcessInfo.processInfo.systemUptime - syncStarted) * 1_000))
            reportProductEvent("sync_finished", outcome: "success", durationMs: min(duration, 3_600_000))
            scheduleBackgroundSyncIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            scheduleBackgroundSyncIfNeeded()
            telemetry.nonFatal("sync", code: (error as NSError).code)
            let offline = (error as NSError).domain == NSURLErrorDomain
            syncIssue = offline
                ? "You're offline. KROK will sync again when you're connected."
                : "Sync paused. Pull down to try again."
            let duration = Int(max(0, (ProcessInfo.processInfo.systemUptime - syncStarted) * 1_000))
            reportProductEvent("sync_finished", outcome: offline ? "offline" : "error", durationMs: min(duration, 3_600_000))
        }
    }

    /// While workout details are still uploading, ask iOS for background time to continue. (HealthKit
    /// data is only readable while the phone is unlocked, so this helps only when iOS runs it then.)
    /// Asks iOS for an occasional background refresh even when everything is in (it decides when; roughly every few hours at best).
    func scheduleBackgroundRefresh() {
        // Submitting a request for a task nobody registered a handler for crashes (UI tests, previews).
        guard phase != .welcome, BackgroundTaskRegistry.shared.refreshRegistered else { return }
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static let refreshTaskId = "app.healthsync.refresh"

    /// What a background refresh does: the same quick catch-up as a wake for new data.
    func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        try? await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(25))
    }

    func scheduleBackgroundSyncIfNeeded() {
        scheduleBackgroundRefresh()
        guard phase != .welcome, !progress.historyComplete else { return }
        let request = BGProcessingTaskRequest(identifier: AppModel.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static let backgroundTaskId = "app.healthsync.sync"

    func refreshStatus() async {
        guard let s = try? await backend.status() else { return }
        status = s
        // After a reinstall the phone has no choice yet: adopt what the server already holds.
        if !consent.hasChoice, let remote = s.categories {
            consent.set(Set(remote))
            enabledCategories = consent.enabled
        }
    }

    // MARK: Data categories

    /// Categories offered in Settings (everything in the coverage file except the always-on core group).
    var optionalCategories: [CoverageCategory] { scope.categories.filter { $0.id != "core" } }

    func isEnabled(_ id: String) -> Bool { enabledCategories.contains(id) }

    /// Switches a data category on (asks Apple Health for access to its types) or off (its data is deleted on the server).
    func setCategory(_ id: String, on: Bool) async {
        guard id != "core", isEnabled(id) != on else { return }
        busy = true
        defer { busy = false }
        var next = consent.enabled
        do {
            if on {
                next.insert(id)
                try await source.requestAuthorization(scope: scope, categories: next)
                if id == "medications" { requestMedicationsInBackground() }
            } else {
                next.remove(id)
            }
            // The server first: a failed call leaves the choice unchanged instead of syncing data it would reject.
            try await backend.setCategories(next.sorted())
            consent.set(next)
            enabledCategories = consent.enabled
            if on { try await engine.categoryEnabled(id) } else { try await engine.categoryDisabled(id) }
            telemetry.event(on ? "category_on" : "category_off", ["category": id])
            await refreshStatus()
            if on {
                observeOtherData()
                syncTask?.cancel()
                syncTask = Task { await syncNow() }
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    // MARK: Providers

    func isSetUp(_ p: AIProvider) -> Bool { status.setUp[p.id] == true }

    func existingLink(for p: AIProvider) -> String? { Keychain.get("link.\(p.id)") }

    /// Returns the provider's private link, creating it on first use (after consent).
    func link(for p: AIProvider) async -> String? {
        if let url = existingLink(for: p) { return url }
        busy = true
        defer { busy = false }
        do {
            if try await ensureCurrentAccount() { start() }
            let url = try await backend.createLink(provider: p.id)
            Keychain.set(url, for: "link.\(p.id)")
            telemetry.event("link_created", ["provider": p.id])
            return url
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    /// Polls until the provider has used its link at least once.
    func waitUntilSetUp(_ p: AIProvider) async {
        while !Task.isCancelled && !isSetUp(p) {
            try? await Task.sleep(for: .seconds(3))
            await refreshStatus()
        }
        if isSetUp(p) { telemetry.event("provider_set_up", ["provider": p.id]) }
    }

    func disconnect(_ p: AIProvider) async {
        busy = true
        defer { busy = false }
        do {
            try await backend.disconnect(provider: p.id)
            Keychain.set(nil, for: "link.\(p.id)")
            telemetry.event("provider_disconnected", ["provider": p.id])
            await refreshStatus()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func deleteAllData() async {
        busy = true
        defer { busy = false }
        do {
            if await backend.hasAppleAccount() {
                let identity = try await appleSignIn.authorize()
                try await backend.linkAppleAccount(identity, allowExistingAccount: false, replacingFreshAccount: nil)
                try await backend.revokeAppleAuthorization(identity.authorizationCode)
            }
            try await backend.deleteAllData()
            telemetry.event("data_deleted")
            Keychain.removeAll()
            outbox.reset()
            await engine.resetStats()
            estimator = SyncEstimator()
            estimate = SyncEstimate()
            progress = SyncProgress(detailsDone: 0, detailsTotal: 0, isSyncing: false)
            await backend.signOut()
            defaults.removeObject(forKey: Self.healthConnectedKey)
            defaults.removeObject(forKey: Self.pendingAccountKey)
            defaults.removeObject(forKey: Self.onboardingUidKey)
            defaults.removeObject(forKey: Self.syncedUidKey)
            defaults.removeObject(forKey: Self.uploadFinishedKey)
            goals.clear(editions: SpecialEdition.all)
            goalSeconds = nil
            uploadFinished = false
            status = .empty
            appleAccountLinked = false
            started = false
            // Clear `busy` before the screen changes: the new welcome screen must never render (or
            // miss an update to) a stale spinner with a disabled button.
            busy = false
            withAnimation { phase = .welcome }
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Sign in with Apple from the ••• menu (for accounts that were created before the account page existed).
    func signInWithAppleFromMenu() async {
        guard !busy else { return }
        do {
            let identity = try await appleSignIn.authorize()
            await linkAppleAccount(identity)
        } catch {
            if (error as NSError).code != 1001 { errorMessage = friendly(error) }  // 1001: the person closed Apple's sheet
        }
    }

    func linkAppleAccount(_ result: AppleSignInResult) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let onboarding = phase == .account
        // Whether the sync was stopped (only when the account changes); otherwise it keeps running during sign-in.
        var stopped = false
        do {
            let allowExisting = phase == .welcome && outbox.pending().isEmpty
            // On the account page the sync is already running on a fresh anonymous account; only that one may be replaced.
            let freshUid = onboarding ? defaults.string(forKey: Self.onboardingUidKey) : nil
            // Linking keeps the same account, so the sync does not wait for it (a running sync can take a minute
            // to stop). Only a restore, which switches to another account, stops the sync first.
            try await backend.linkAppleAccount(result, allowExistingAccount: allowExisting, replacingFreshAccount: freshUid)
            reportProductEvent("apple_linked")
            appleAccountLinked = await backend.hasAppleAccount()
            if let freshUid, let current = try? await backend.signIn(), current != freshUid {
                stopped = true
                await stopSync(waitingAtMost: 20)
                try await startOverOnRestoredAccount()
            }
            if onboarding {
                defaults.set(false, forKey: Self.pendingAccountKey)
                defaults.removeObject(forKey: Self.onboardingUidKey)
                withAnimation { phase = .home }
            }
            Task { await refreshStatus() }
            if stopped { start() }
        } catch {
            errorMessage = friendly(error)
            if stopped, phase != .welcome { start() }
        }
    }

    /// Cancels the running sync and waits for it to stop, but never longer than `seconds`.
    private func stopSync(waitingAtMost seconds: Double) async {
        guard let task = syncTask else { return }
        task.cancel()
        syncTask = nil
        await Self.finishWithin(seconds: seconds) { await task.value }
    }

    /// An existing KROK account was restored during onboarding: what this phone had queued belongs to the account that
    /// was just replaced, so the first sync starts again from scratch against the restored one.
    private func startOverOnRestoredAccount() async throws {
        outbox.reset()
        await engine.resetStats()
        estimator = SyncEstimator()
        estimate = SyncEstimate()
        progress = SyncProgress(detailsDone: 0, detailsTotal: 0, isSyncing: false)
        started = false
        try await backend.registerDevice(timeZone: TimeZone.current.identifier)
        try await backend.setCategories(consent.enabled.sorted())
        telemetry.event("account_restored")
    }

    /// Turns an error into something a person can act on.
    static func message(for error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "You appear to be offline. Try again when you're connected." }
        // HealthKit error 3 at the permission step ("Failed to look up source with bundle identifier") comes
        // from the phone's Health database losing track of the app, e.g. after reinstalling; a restart fixes it.
        if ns.domain == "com.apple.healthkit" && ns.code == 3 {
            return "Apple Health couldn't set up KROK (this can happen after reinstalling). Restart your iPhone, then open KROK and try again."
        }
        if ns.domain == "com.firebase.functions" {
            switch ns.code {
            case 8: return "Too many attempts. Please wait a while and try again."
            case 9: return ns.localizedDescription  // e.g. "This account is being deleted."
            case 14: return "KROK's servers can't be reached right now. Try again in a moment."
            default: break
            }
        }
        return "Something went wrong. Please try again."
    }

    private func friendly(_ error: Error) -> String { Self.message(for: error) }
}
