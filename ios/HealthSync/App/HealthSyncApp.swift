import BackgroundTasks
import SwiftUI
import UIKit

@main
struct HealthSyncApp: App {
    /// nil when a Release build cannot configure Firebase; the app then shows StartupUnavailableView
    /// and never creates the model, observes HealthKit or syncs.
    private let model: AppModel?
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    private let benchMode = ProcessInfo.processInfo.arguments.contains("-healthBench")
    #else
    private let benchMode = false
    #endif

    init() {
        #if DEBUG
        // Synthetic sources exist only in Debug builds; Release ignores these launch arguments.
        let args = ProcessInfo.processInfo.arguments
        #else
        let args: [String] = []
        #endif
        let uiTesting = args.contains("-uiTesting")
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        let backend: Backend
        let source: HealthSource
        let telemetry: Telemetry
        var synthetic = uiTesting || args.contains("-healthBench")
        #if DEBUG
        // Test hosts and simulators have no GoogleService-Info.plist; Release never falls back to fakes.
        if !synthetic, !FirebaseBackend.configure() { synthetic = true }
        #endif
        if synthetic {
            backend = FakeBackend(appleLinked: uiTesting && args.contains("-appleLinked"))
            source = FakeHealthSource()
            telemetry = NoTelemetry()
        } else {
            guard FirebaseBackend.configure() else {
                model = nil
                return
            }
            backend = FirebaseBackend()
            source = HealthKitSource(scope: scope)
            telemetry = FirebaseTelemetry()
        }
        let defaults = uiTesting ? UserDefaults(suiteName: "uitest-\(UUID().uuidString)")! : .standard
        if uiTesting && args.contains("-onboarded") { defaults.set(true, forKey: AppModel.healthConnectedKey) }
        if uiTesting && args.contains("-accountPending") {
            defaults.set(true, forKey: AppModel.healthConnectedKey)
            defaults.set(true, forKey: AppModel.pendingAccountKey)
        }
        let outboxRoot = uiTesting ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) : Outbox.defaultRoot()
        let model = AppModel(backend: backend, source: source, outbox: Outbox(root: outboxRoot), scope: scope, telemetry: telemetry, defaults: defaults)
        // HealthKit background delivery can relaunch the app without ever showing a scene.
        model.startObservers()
        // Lets iOS give the app time to finish uploading workout details in the background.
        if !uiTesting {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.backgroundTaskId, using: nil) { task in
                let work = Task { @MainActor in
                    await model.syncNow()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = {
                    work.cancel()
                    task.setTaskCompleted(success: false)
                }
            }
        }
        if !uiTesting {
            BackgroundTaskRegistry.shared.refreshRegistered = true
            BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.refreshTaskId, using: nil) { task in
                let work = Task { @MainActor in
                    await model.runBackgroundRefresh()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = {
                    work.cancel()
                    task.setTaskCompleted(success: false)
                }
            }
        }
        self.model = model
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                #if DEBUG
                if benchMode {
                    BenchView()
                } else {
                    LiveRoot(model: model)
                }
                #else
                LiveRoot(model: model)
                #endif
            } else {
                StartupUnavailableView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let model else { return }
            if phase == .active, !benchMode { model.start() }
            if phase == .background { model.flushStats() }
        }
    }
}

/// Observes the model for the app's lifetime (the App struct holds the strong reference).
private struct LiveRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        RootView()
            .environmentObject(model)
            .tint(Theme.accent)
    }
}

struct StartupUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("KROK is unavailable")
                .font(.title2.bold())
            Text("KROK couldn't start because its configuration is missing or invalid. Please update the app or reinstall it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            // One onboarding view for both pages, so the questions keep scrolling when the page changes.
            if model.phase == .home {
                ConnectView()
            } else {
                OnboardingView(startOnAccount: model.phase == .account)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
