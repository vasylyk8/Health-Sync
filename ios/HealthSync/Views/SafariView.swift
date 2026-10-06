import SafariServices
import SwiftUI

/// A web page shown in an in-app browser. Unlike `openURL`, it never hands the link to the
/// Claude or ChatGPT app through universal links, so setup always happens on the website.
struct WebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
