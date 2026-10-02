import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct AppleSignInResult: Sendable {
    let idToken: String
    let nonce: String
    let authorizationCode: String
}

enum AppleSignInError: LocalizedError {
    case invalidResponse, alreadyRunning, accountConflict, randomFailure
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Apple could not complete sign-in. Please try again."
        case .alreadyRunning: return "A sign-in request is already open."
        case .accountConflict: return "This Apple Account is linked to another KROK account. Your current workouts have not changed. Contact support before switching accounts."
        case .randomFailure: return "Could not start a secure sign-in. Please try again."
        }
    }
}

enum AppleNonce {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppleSignInError.randomFailure }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func hash(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Retained by AppModel for the lifetime of Apple's system authorization sheet.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var nonce: String?
    private var controller: ASAuthorizationController?

    func authorize() async throws -> AppleSignInResult {
        guard continuation == nil else { throw AppleSignInError.alreadyRunning }
        let nonce = try AppleNonce.generate()
        self.nonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // KROK needs an identity, not the user's name or real email.
        request.requestedScopes = []
        request.nonce = AppleNonce.hash(nonce)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8),
              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8),
              let nonce else { finish(.failure(AppleSignInError.invalidResponse)); return }
        finish(.success(AppleSignInResult(idToken: token, nonce: nonce, authorizationCode: code)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }
    private func finish(_ result: Result<AppleSignInResult, Error>) {
        let pending = continuation
        continuation = nil
        nonce = nil
        controller = nil
        pending?.resume(with: result)
    }
}
