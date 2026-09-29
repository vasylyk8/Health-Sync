import Foundation

/// Product analytics and diagnostics. Never receives health values, links or free text.
protocol Telemetry: Sendable {
    func event(_ name: String, _ params: [String: String])
    func nonFatal(_ domain: String, code: Int)
}

extension Telemetry {
    func event(_ name: String) { event(name, [:]) }
}

struct NoTelemetry: Telemetry {
    func event(_ name: String, _ params: [String: String]) {}
    func nonFatal(_ domain: String, code: Int) {}
}
