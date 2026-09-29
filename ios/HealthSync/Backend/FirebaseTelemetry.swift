import FirebaseAnalytics
import FirebaseCrashlytics
import Foundation

struct FirebaseTelemetry: Telemetry {
    func event(_ name: String, _ params: [String: String]) {
        Analytics.logEvent(name, parameters: params.isEmpty ? nil : params)
    }

    func nonFatal(_ domain: String, code: Int) {
        Crashlytics.crashlytics().record(error: NSError(domain: domain, code: code))
    }
}
