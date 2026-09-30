import BackgroundTasks
import SwiftUI
import UIKit

/// App state and actions. Views stay dumb; everything testable lives here.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case welcome, home }

    @Published var phase: Phase
    @Published var status: ServerStatus = .empty
    @Published var progress = SyncProgress(detailsDone: 0, detailsTotal: 0, isSyncing: false) {
        didSet { keepScreenAwakeDuringFirstSync() }
    }
    @Published var errorMessage: String?
    @Published var busy = false
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
    private var started = false
    private var observing = false

    init(backend: Backend, source: HealthSource, outbox: Outbox, scope: SyncScope, telemetry: Telemetry, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.source = source
        self.outbox = outbox
        self.scope = scope
        self.telemetry = telemetry
        self.defaults = defaults
        var config = SyncEngine.Config()
        config.device = UIDevice.current.model
        config.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        engine = SyncEngine(source: source, uploader: backend, outbox: outbox, scope: scope, config: config, telemetry: telemetry)
        phase = defaults.bool(forKey: "healthConnected") ? .home : .welcome
    }

    /// The first sync only makes progress while the phone is unlocked (HealthKit data is unreadable
    /// when it locks), so keep the screen on until the history is in. Normal syncs don't need this.
    private func keepScreenAwakeDuringFirstSync() {
        let firstSync = progress.isSyncing && !progress.historyComplete
        if UIApplication.shared.isIdleTimerDisabled != firstSync { UIApplication.shared.isIdleTimerDisabled = firstSync }
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
            guard source.isAvailable else {
                errorMessage = "Apple Health isn't available on this device."
                return
            }
            // HealthKit never reveals which read permissions were granted; we proceed either way
            // and show "No readable Health data found" later if nothing arrives.
            stage = "health-permission"
            connectStage = "Waiting for Apple Health…"
            try await source.requestAuthorization(scope: scope)
            stage = "sign-in"
            connectStage = "Signing in…"
            let backend = self.backend
            _ = try await Self.withTimeout(seconds: 25) { try await backend.signIn() }
            stage = "register"
            connectStage = "Registering this iPhone…"
            let tz = TimeZone.current.identifier
            try await Self.withTimeout(seconds: 25) { try await backend.registerDevice(timeZone: tz) }
            defaults.set(true, forKey: "healthConnected")
            telemetry.event("health_connected")
            busy = false
            withAnimation { phase = .home }
            start()
        } catch {
            let ns = error as NSError
            telemetry.nonFatal("connect.\(stage)", code: ns.code)
            // The step and error code carry no health data; they make a failure diagnosable from a screenshot.
            // HealthKit's own text names the problem (for example which data type it refused); it contains no health data.
            let detail = ns.domain == "com.apple.healthkit" ? " \(ns.localizedDescription)" : ""
            errorMessage = friendly(error) + "\n\n(\(stage): \(ns.domain) \(ns.code))\(detail)"
        }
    }

    private struct StepTimeout: LocalizedError {
        var errorDescription: String? { "This is taking too long. Check your connection and try again." }
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
        guard phase == .home, !benchmarkRunning else { return }
        Task { await engine.onProgress { p in Task { @MainActor in self.progress = p } } }
        startObservers()
        syncTask = Task { await syncNow() }
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
        guard phase == .home, !observing else { return }
        observing = true
        let engine = self.engine
        source.observeWorkouts { done in
            Task {
                try? await engine.runWorkoutChanges(deadline: Date().addingTimeInterval(20))
                done()
            }
        }
    }

    func syncNow() async {
        do {
            _ = try await backend.signIn()
            if !started {
                started = true
                try await backend.registerDevice(timeZone: TimeZone.current.identifier)
            }
            await refreshStatus()
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
            scheduleBackgroundSyncIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            scheduleBackgroundSyncIfNeeded()
            telemetry.nonFatal("sync", code: (error as NSError).code)
            syncIssue = (error as NSError).domain == NSURLErrorDomain
                ? "You're offline. KROK will sync again when you're connected."
                : "Sync paused. Pull down to try again."
        }
    }

    /// While workout details are still uploading, ask iOS for background time to continue. (HealthKit
    /// data is only readable while the phone is unlocked, so this helps only when iOS runs it then.)
    func scheduleBackgroundSyncIfNeeded() {
        guard phase == .home, !progress.historyComplete else { return }
        let request = BGProcessingTaskRequest(identifier: AppModel.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static let backgroundTaskId = "app.healthsync.sync"

    func refreshStatus() async {
        if let s = try? await backend.status() { status = s }
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
            try await backend.deleteAllData()
            telemetry.event("data_deleted")
            Keychain.removeAll()
            outbox.reset()
            await backend.signOut()
            defaults.removeObject(forKey: "healthConnected")
            status = .empty
            started = false
            // Clear `busy` before the screen changes: the new welcome screen must never render (or
            // miss an update to) a stale spinner with a disabled button.
            busy = false
            withAnimation { phase = .welcome }
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Turns an error into something a person can act on.
    static func message(for error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "You appear to be offline. Try again when you're connected." }
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
