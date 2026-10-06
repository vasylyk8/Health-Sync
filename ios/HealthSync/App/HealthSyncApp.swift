import BackgroundTasks
import SwiftUI
import UIKit

@main
struct HealthSyncApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let benchMode = ProcessInfo.processInfo.arguments.contains("-healthBench")

    init() {
        let args = ProcessInfo.processInfo.arguments
        let uiTesting = args.contains("-uiTesting")
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        let backend: Backend
        let source: HealthSource
        let telemetry: Telemetry
        if uiTesting || args.contains("-healthBench") || !FirebaseBackend.configure() {
            backend = FakeBackend(appleLinked: uiTesting && args.contains("-appleLinked"), autoSetUp: !(uiTesting && args.contains("-noAutoSetUp")))
            source = FakeHealthSource()
            telemetry = NoTelemetry()
        } else {
            backend = FirebaseBackend()
            source = HealthKitSource(scope: scope)
            telemetry = FirebaseTelemetry()
        }
        let defaults = uiTesting ? UserDefaults(suiteName: "uitest-\(UUID().uuidString)")! : .standard
        #if DEBUG
        if uiTesting && args.contains("-seedDiagnosticReports") { DiagnosticReportStore.seedSamples() }
        #endif
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
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if benchMode {
                BenchView()
            } else {
                RootView()
                    .environmentObject(model)
                    .tint(Theme.accent)
            }
            #else
            RootView()
                .environmentObject(model)
                .tint(Theme.accent)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.stopDiagnosticSuite(); model.stopSyncComparison(reason: "KROK left the foreground or the phone locked") }
            if phase == .active, !benchMode { model.start() }
            if phase == .background { model.flushStats() }
        }
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
