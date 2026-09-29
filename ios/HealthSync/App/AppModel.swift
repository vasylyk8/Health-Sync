import SwiftUI
import UIKit

/// App state and actions. Views stay dumb; everything testable lives here.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case welcome, home }

    @Published var phase: Phase
    @Published var status: ServerStatus = .empty
    @Published var progress = SyncProgress(typesDone: 0, typesTotal: 0, isSyncing: false) {
        didSet { keepScreenAwakeDuringFirstSync() }
    }
    @Published var errorMessage: String?
    @Published var busy = false
    /// Shown under the sync status when the last sync attempt failed; cleared by the next success.
    @Published var syncIssue: String?

    let providers = AIProvider.all
    private let backend: Backend
    private let source: HealthSource
    private let engine: SyncEngine
    private let outbox: Outbox
    private let types: [SyncType]
    private let telemetry: Telemetry
    private let defaults: UserDefaults
    private var started = false
    private var observing = false

    init(backend: Backend, source: HealthSource, outbox: Outbox, types: [SyncType], telemetry: Telemetry, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.source = source
        self.outbox = outbox
        self.types = types
        self.telemetry = telemetry
        self.defaults = defaults
        var config = SyncEngine.Config()
        config.device = UIDevice.current.model
        config.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        engine = SyncEngine(source: source, uploader: backend, outbox: outbox, types: types, config: config, telemetry: telemetry)
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
        defer { busy = false }
        do {
            guard source.isAvailable else {
                errorMessage = "Apple Health isn't available on this device."
                return
            }
            // HealthKit never reveals which read permissions were granted; we proceed either way
            // and show "No readable Health data found" later if nothing arrives.
            try await source.requestAuthorization(types: types)
            _ = try await backend.signIn()
            try await backend.registerDevice(timeZone: TimeZone.current.identifier)
            defaults.set(true, forKey: "healthConnected")
            telemetry.event("health_connected")
            busy = false
            withAnimation { phase = .home }
            start()
        } catch {
            errorMessage = friendly(error)
        }
    }

    // MARK: Lifecycle

    /// Called on launch (when already onboarded) and whenever the app becomes active.
    func start() {
        guard phase == .home else { return }
        Task { await engine.onProgress { p in Task { @MainActor in self.progress = p } } }
        startObservers()
        Task { await syncNow() }
    }

    /// Registers the HealthKit observers that let iOS wake the app for new data. Must also run when
    /// iOS relaunches the app in the background (before any screen appears), so the app calls it
    /// at launch, not only when a scene becomes active.
    func startObservers() {
        guard phase == .home, !observing else { return }
        observing = true
        let engine = self.engine
        source.observeChanges(types: types) { type, done in
            Task {
                try? await engine.runTypes([type.id], deadline: Date().addingTimeInterval(20))
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
        } catch is CancellationError {
            return
        } catch {
            telemetry.nonFatal("sync", code: (error as NSError).code)
            syncIssue = (error as NSError).domain == NSURLErrorDomain
                ? "You're offline. KROK will sync again when you're connected."
                : "Sync paused. Pull down to try again."
        }
    }

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
