import AuthenticationServices
import SwiftUI

/// Sign in with Apple, or the linked state. On Welcome it is just the button (it can restore an
/// account after a reinstall); on Home it comes with a short explanation.
struct AppleAccountView: View {
    enum Style { case welcome, home }

    var style: Style = .home
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.appleAccountLinked {
                HStack(spacing: 12) {
                    CheckBadge().accessibilityHidden(true)
                    Text(Copy.Account.linked)
                        .bodyText(.semibold)
                        .foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                if style == .home {
                    Text(Copy.Account.title)
                        .bodyText(.semibold)
                        .foregroundStyle(Theme.ink)
                    Text(Copy.Account.detail)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SignInWithAppleButton(.signIn) { request in
                    do {
                        let fresh = try AppleNonce.generate()
                        nonce = fresh
                        request.requestedScopes = []
                        request.nonce = AppleNonce.hash(fresh)
                    } catch { model.errorMessage = error.localizedDescription }
                } onCompletion: { result in
                    defer { nonce = nil }
                    switch result {
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8),
                              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8), let nonce else {
                            model.errorMessage = AppleSignInError.invalidResponse.localizedDescription; return
                        }
                        let identity = AppleSignInResult(idToken: token, nonce: nonce, authorizationCode: code)
                        Task { await model.linkAppleAccount(identity) }
                    case .failure(let error):
                        if (error as NSError).code != ASAuthorizationError.canceled.rawValue { model.errorMessage = error.localizedDescription }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .whiteOutline)
                .frame(height: Theme.pillHeight)
                .clipShape(Capsule())
                .disabled(model.busy)
                .accessibilityIdentifier("appleSignIn")
            }
        }
    }
}
