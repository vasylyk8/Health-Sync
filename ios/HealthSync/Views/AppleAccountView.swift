import AuthenticationServices
import SwiftUI

/// Apple's Sign in with Apple button, styled like the app's own buttons (same height and corner radius, black in
/// light mode and white in dark mode, like the filled pills).
struct AppleSignInButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?

    var body: some View {
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
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: Theme.pillHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
        .disabled(model.busy)
        .accessibilityIdentifier("appleSignIn")
    }
}
