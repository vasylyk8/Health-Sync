import SwiftUI

@main
struct HealthSyncApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let args = ProcessInfo.processInfo.arguments
        let uiTesting = args.contains("-uiTesting")
        let types = HealthTypes.resolve(HealthTypes.loadCoverage())
        let backend: Backend
        let source: HealthSource
        let telemetry: Telemetry
        if uiTesting || !FirebaseBackend.configure() {
            backend = FakeBackend()
            source = FakeHealthSource()
            telemetry = NoTelemetry()
        } else {
            backend = FirebaseBackend()
            source = HealthKitSource()
            telemetry = FirebaseTelemetry()
        }
        let defaults = uiTesting ? UserDefaults(suiteName: "uitest-\(UUID().uuidString)")! : .standard
        if uiTesting && args.contains("-onboarded") { defaults.set(true, forKey: "healthConnected") }
        let outboxRoot = uiTesting ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) : Outbox.defaultRoot()
        _model = StateObject(wrappedValue: AppModel(backend: backend, source: source, outbox: Outbox(root: outboxRoot), types: types, telemetry: telemetry, defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() }
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
    static let accent = Color(red: 1.0, green: 0.22, blue: 0.37)
    /// Set at build time from the deployed site (Info.plist key PrivacyPolicyURL).
    static let privacyURL: URL = (Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String).flatMap(URL.init(string:))
        ?? URL(string: "https://health-sync.web.app/privacy")!
}
