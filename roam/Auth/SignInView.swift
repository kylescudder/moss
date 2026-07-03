import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var services: AppServices
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var showSignUp = false
    @State private var showReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("roam")
                        .font(.largeTitle.bold())
                    Text("Plan trips, build daily itineraries, and keep travel details synced across devices.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.top, 48)

                VStack(spacing: Theme.Spacing.md) {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    PrimaryButton(title: "Sign in", systemImage: "arrow.right", isLoading: isWorking) {
                        Task { await signIn() }
                    }
                    Button("Forgot password?") {
                        showReset = true
                    }
                    .font(.footnote)
                }
                .textFieldStyle(.roundedBorder)

                VStack(spacing: Theme.Spacing.sm) {
                    Button {
                        services.auth.beginProviderSignIn(providerName: "Apple")
                    } label: {
                        Label("Continue with Apple", systemImage: "apple.logo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        services.auth.beginProviderSignIn(providerName: "Google")
                    } label: {
                        Label("Continue with Google", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if let message = services.auth.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button("Create an account") {
                    showSignUp = true
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
        .navigationDestination(isPresented: $showSignUp) {
            SignUpView()
        }
        .sheet(isPresented: $showReset) {
            ForgotPasswordSheet(email: email)
        }
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        await services.auth.signIn(email: email, password: password)
    }
}

