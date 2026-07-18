import SwiftUI

struct SignUpView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var confirmationMessage: String?

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name", text: $displayName)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
            }

            Section {
                PrimaryButton(title: "Create account", systemImage: "person.badge.plus", isLoading: isWorking) {
                    Task { await signUp() }
                }
                .disabled(displayName.isEmpty || email.isEmpty || password.count < 8)
            }

            if let confirmationMessage {
                Section {
                    Text(confirmationMessage)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }

            if let message = services.auth.lastError {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Create Account")
    }

    private func signUp() async {
        isWorking = true
        defer { isWorking = false }
        let result = await services.auth.signUp(email: email, password: password, displayName: displayName)
        switch result {
        case .signedIn:
            dismiss()
        case .needsEmailConfirmation(let email):
            confirmationMessage = "Check \(email) to confirm your account."
        case nil:
            break
        }
    }
}

