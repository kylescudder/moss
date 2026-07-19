import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var services: AppServices
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var showSignUp = false
    @State private var showForgotPassword = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.sm) {
                    Image("MossBallLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)

                    Text("Moss")
                        .font(.largeTitle.weight(.bold))
                    Text("Travel, together")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Spacing.xxl)

                VStack(spacing: Theme.Spacing.md) {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .onSubmit {
                            guard isFormValid else { return }
                            Task { await signIn() }
                        }

                    HStack {
                        Spacer()
                        Button("Forgot password?") {
                            showForgotPassword = true
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.accent)
                    }
                }

                if let message = services.auth.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: Theme.Spacing.md) {
                    PrimaryButton(title: "Sign in", isLoading: isWorking) {
                        Task { await signIn() }
                    }
                    .disabled(!isFormValid || isWorking)

                    HStack {
                        Rectangle()
                            .fill(Theme.Colors.separator)
                            .frame(height: 1)
                        Text("or")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Rectangle()
                            .fill(Theme.Colors.separator)
                            .frame(height: 1)
                    }

                    AppleSignInButton()
                        .frame(height: 50)
                        .disabled(isWorking)

                    SecondaryButton(title: "Continue with Google", assetImage: "GoogleLogo") {
                        Task { await googleSignIn() }
                    }
                    .disabled(isWorking)
                }

                Button("Create an account") {
                    showSignUp = true
                }
                .font(.callout)
                .padding(.top, Theme.Spacing.sm)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Colors.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: $showSignUp) {
            SignUpView()
        }
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordSheet(email: email)
                .presentationDetents([.medium, .large])
        }
    }

    private var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password.count >= 6
    }

    private func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await services.auth.signIn(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    private func googleSignIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await services.auth.signInWithGoogle()
    }
}
