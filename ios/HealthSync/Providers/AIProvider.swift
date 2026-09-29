import SwiftUI

/// An AI assistant the user can connect. Adding a new one = one entry in `all` (plus its id in
/// the server's PROVIDERS list).
struct AIProvider: Identifiable, Hashable {
    struct Step: Hashable {
        let title: String
        let detail: String
        let illustration: Illustration
    }

    enum Illustration: Hashable {
        case copyLink
        case openSettings(site: String, path: [String])
        case addConnector(site: String, button: String, fields: [String])
    }

    let id: String
    let name: String
    let company: String
    let symbol: String
    let tint: Color
    let setupURL: URL
    let websiteLabel: String
    let subtitle: String?
    let steps: [Step]
    let tip: String?

    static let claude = AIProvider(
        id: "claude", name: "Claude", company: "Anthropic", symbol: "sparkle", tint: Color(red: 0.85, green: 0.47, blue: 0.34),
        setupURL: URL(string: "https://claude.ai/settings/connectors")!, websiteLabel: "claude.ai", subtitle: nil,
        steps: [
            Step(title: "Copy your private link", detail: "This link lets Claude read your Health data. Keep it private.", illustration: .copyLink),
            Step(title: "Open Claude's connectors", detail: "Sign in if asked. If you don't land on it, go to Customize, then Connectors.", illustration: .openSettings(site: "claude.ai", path: ["Customize", "Connectors"])),
            Step(title: "Add the connector", detail: "Tap +, then \"Add custom connector\". Name it KROK, paste your link, then tap Add.", illustration: .addConnector(site: "claude.ai", button: "+ Add custom connector", fields: ["KROK", "https://…/mcp/…"])),
        ],
        tip: "On Claude's free plan you can have one custom connector. If you already have one, remove it first.")

    static let chatgpt = AIProvider(
        id: "chatgpt", name: "ChatGPT", company: "OpenAI", symbol: "circle.hexagongrid", tint: Color(red: 0.06, green: 0.64, blue: 0.5),
        setupURL: URL(string: "https://chatgpt.com/#settings/Connectors")!, websiteLabel: "chatgpt.com", subtitle: "Requires ChatGPT Plus",
        steps: [
            Step(title: "Copy your private link", detail: "This link lets ChatGPT read your Health data. Keep it private.", illustration: .copyLink),
            Step(title: "Open ChatGPT's settings", detail: "Sign in if asked. In Apps & Connectors, open Advanced settings and turn on Developer mode.", illustration: .openSettings(site: "chatgpt.com", path: ["Settings", "Apps & Connectors", "Developer mode"])),
            Step(title: "Create the connector", detail: "Tap Create, name it KROK, paste your link, choose \"No authentication\", then save.", illustration: .addConnector(site: "chatgpt.com", button: "Create", fields: ["KROK", "https://…/mcp/…", "No authentication"])),
        ],
        tip: "Custom connectors need ChatGPT Plus, Pro or Business.")

    static let all: [AIProvider] = [.claude, .chatgpt]
}
