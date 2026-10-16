import SwiftUI

/// App Review sign-in: a test account with sample data, so a reviewer needs no Apple Account and no Apple Health data.
struct ReviewSignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Copy.Review.title) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Copy.Review.body)
                        .bodyText()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(Copy.Review.email, text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reviewEmail")
                    SecureField(Copy.Review.password, text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reviewPassword")
                }
                .padding(.top, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button(action: submit) {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(Theme.buttonText) }
                    Text(Copy.Review.signIn)
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.busy || email.isEmpty || password.isEmpty)
            .accessibilityIdentifier("reviewSignIn")
            .padding(.vertical, 16)
        }
        .padding(.horizontal, Theme.margin)
        .background(Theme.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.sheetRadius)
        .presentationBackground(Theme.background)
        // The app-level alert sits under this sheet, so errors are shown here.
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        Task {
            if await model.signInAsReviewer(email: email, password: password) { dismiss() }
        }
    }
}
