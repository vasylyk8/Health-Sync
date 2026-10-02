import AuthenticationServices
import SwiftUI

struct AppleAccountView: View {
    @EnvironmentObject var model: AppModel
    @State private var nonce: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.appleAccountLinked {
                Label("Apple Account linked", systemImage: "checkmark.shield")
            } else {
                Text("Connect your KROK account").font(.headline)
                Text("Sign in with Apple to access these workouts from Claude or ChatGPT. Your synced data stays in your KROK account.")
                    .font(.footnote).foregroundStyle(Theme.mutedText)
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
                .frame(height: 46)
                .disabled(model.busy)
                .accessibilityIdentifier("appleSignIn")
            }
        }
    }
}
