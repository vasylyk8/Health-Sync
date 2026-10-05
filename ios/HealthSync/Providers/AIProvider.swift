import Foundation

/// An AI assistant the user can connect. Adding a new one = one entry in `all` (plus its id in
/// the server's PROVIDERS list).
struct AIProvider: Identifiable, Hashable {
    struct Step: Hashable {
        let title: String
        let detail: String
        /// Values to type or pick on the assistant's site, shown as chips under the step.
        let chips: [String]
    }

    let id: String
    let name: String
    let company: String
    let setupURL: URL
    let websiteLabel: String
    /// Where the Sign in with Apple setup sends people (the page that adds a custom connector).
    let oauthURL: URL
    let oauthLabel: String
    /// A requirement or tip shown above the steps.
    let notice: String?
    let steps: [Step]

    static let claude = AIProvider(
        id: "claude", name: "Claude", company: "Anthropic",
        setupURL: URL(string: "https://claude.ai/settings/connectors")!, websiteLabel: "claude.ai",
        oauthURL: URL(string: "https://claude.ai/new#customize/connectors")!, oauthLabel: "claude.ai",
        notice: "On Claude’s free plan you can have one custom connector. If you already have one, remove it first.",
        steps: [
            Step(title: "Copy your private link", detail: "This link lets Claude read your Health data. Keep it private.", chips: []),
            Step(title: "Open Claude’s connectors", detail: "Sign in if asked. If you don’t land on it, go to Customize, then Connectors.", chips: []),
            Step(title: "Add the connector", detail: "Tap +, then “Add custom connector”. Name it KROK, paste your link, then tap Add.", chips: ["KROK", "https://…/mcp/…"]),
        ])

    static let chatgpt = AIProvider(
        id: "chatgpt", name: "ChatGPT", company: "OpenAI",
        setupURL: URL(string: "https://chatgpt.com/#settings/Connectors")!, websiteLabel: "chatgpt.com",
        oauthURL: URL(string: "https://chatgpt.com/plugins")!, oauthLabel: "chatgpt.com/plugins",
        notice: "Requires ChatGPT Plus, Pro or Business.",
        steps: [
            Step(title: "Copy your private link", detail: "This link lets ChatGPT read your Health data. Keep it private.", chips: []),
            Step(title: "Open ChatGPT’s settings", detail: "Sign in if asked. In Apps & Connectors, open Advanced settings and turn on Developer mode.", chips: []),
            Step(title: "Create the connector", detail: "Tap Create, name it KROK, paste your link, choose “No authentication”, then save.", chips: ["KROK", "https://…/mcp/…", "No authentication"]),
        ])

    static let all: [AIProvider] = [.claude, .chatgpt]
}
