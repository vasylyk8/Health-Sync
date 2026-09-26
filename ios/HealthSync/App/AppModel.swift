import SwiftUI
import UIKit

/// App state and actions. Views stay dumb; everything testable lives here.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case welcome, home }

    @Published var phase: Phase
    @Published var status: ServerStatus = .empty
    @Published var progress = SyncProgress(typesDone: 0, typesTotal: 0, isSyncing: false)
    @Published var errorMessage: String?
    @Published var busy = false

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
        if !observing {
            observing = true
            let engine = self.engine
            source.observeChanges(types: types) { type, done in
                Task {
                    try? await engine.runTypes([type.id], deadline: Date().addingTimeInterval(20))
                    done()
                }
            }
        }
        Task { await syncNow() }
    }

    func syncNow() async {
        do {
            _ = try await backend.signIn()
            if !started {
                started = true
                try await backend.registerDevice(timeZone: TimeZone.current.identifier)
            }
            await refreshStatus()
            try await engine.run()
            await refreshStatus()
        } catch {
            telemetry.nonFatal("sync", code: (error as NSError).code)
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
            withAnimation { phase = .welcome }
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if (error as NSError).domain == NSURLErrorDomain { return "You appear to be offline. Try again when you're connected." }
        return "Something went wrong. Please try again."
    }
}
