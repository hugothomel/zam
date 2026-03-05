import SwiftUI

/// Email/password login sheet with sign-in / sign-up toggle.
struct LoginView: View {
    let auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(isSignUp ? "SIGN UP" : "SIGN IN")
                .font(ForgeTheme.titleFont)
                .foregroundStyle(ForgeTheme.cyan)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(ForgeTheme.bodyFont)
                    .padding(ForgeTheme.buttonPadding)
                    .background(ForgeTheme.surface)
                    .border(ForgeTheme.border, width: ForgeTheme.borderWidth)
                    .foregroundStyle(ForgeTheme.white)

                SecureField("Password", text: $password)
                    .textContentType(isSignUp ? .newPassword : .password)
                    .font(ForgeTheme.bodyFont)
                    .padding(ForgeTheme.buttonPadding)
                    .background(ForgeTheme.surface)
                    .border(ForgeTheme.border, width: ForgeTheme.borderWidth)
                    .foregroundStyle(ForgeTheme.white)
            }

            if let error = auth.errorMessage {
                Text(error)
                    .font(ForgeTheme.captionFont)
                    .foregroundStyle(ForgeTheme.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                submit()
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(ForgeTheme.background)
                    } else {
                        Text(isSignUp ? "CREATE ACCOUNT" : "SIGN IN")
                            .font(ForgeTheme.bodyFont)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(ForgeTheme.buttonPadding)
                .background(ForgeTheme.cyan)
                .foregroundStyle(ForgeTheme.background)
            }
            .disabled(email.isEmpty || password.isEmpty || isLoading)

            Button {
                isSignUp.toggle()
                auth.errorMessage = nil
            } label: {
                Text(isSignUp ? "Already have an account? Sign In" : "No account? Sign Up")
                    .font(ForgeTheme.captionFont)
                    .foregroundStyle(ForgeTheme.dimWhite)
            }

            Spacer()
        }
        .padding(24)
        .background(ForgeTheme.background.ignoresSafeArea())
    }

    private func submit() {
        isLoading = true
        Task {
            if isSignUp {
                await auth.signUp(email: email, password: password)
            } else {
                await auth.signIn(email: email, password: password)
            }
            isLoading = false
            if auth.state == .signedIn {
                dismiss()
            }
        }
    }
}
