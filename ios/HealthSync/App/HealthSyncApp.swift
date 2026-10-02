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
            backend = FakeBackend()
            source = FakeHealthSource()
            telemetry = NoTelemetry()
        } else {
            backend = FirebaseBackend()
            source = HealthKitSource(scope: scope)
            telemetry = FirebaseTelemetry()
        }
        let defaults = uiTesting ? UserDefaults(suiteName: "uitest-\(UUID().uuidString)")! : .standard
        if uiTesting && args.contains("-onboarded") { defaults.set(true, forKey: "healthConnected") }
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
            if phase == .active, !benchMode { model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .welcome: WelcomeView()
            case .home: ConnectView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

enum Theme {
    /// Small secondary text: darker than SwiftUI's .secondary so it clears the 4.5:1 contrast audit
    /// on every background (the audit flagged .secondary as "nearly passed").
    static let mutedText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.72) : UIColor(white: 0, alpha: 0.72)
    })
    /// Slightly deeper pink in light mode so small pink text and white-on-pink buttons meet 4.5:1 contrast.
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1) : UIColor(red: 0.86, green: 0.11, blue: 0.29, alpha: 1)
    })
    /// Green that stays readable as small text on a light background.
    static let success = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.systemGreen : UIColor(red: 0.10, green: 0.50, blue: 0.20, alpha: 1)
    })
    /// Orange that stays readable as small text on a light background.
    static let warning = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.systemOrange : UIColor(red: 0.70, green: 0.32, blue: 0.0, alpha: 1)
    })
    /// Set at build time from the deployed site (Info.plist key PrivacyPolicyURL).
    static let privacyURL: URL = (Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String).flatMap(URL.init(string:))
        ?? URL(string: "https://krok-1d60a.web.app/privacy")!
    static var supportURL: URL { privacyURL.deletingLastPathComponent().appendingPathComponent("support") }
}
