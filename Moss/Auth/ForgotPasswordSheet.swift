import SwiftUI

struct ForgotPasswordSheet: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var didSend = false
    @State private var isWorking = false

    init(email: String) {
        self._email = State(initialValue: email)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    PrimaryButton(title: "Send reset link", systemImage: "envelope", isLoading: isWorking) {
                        Task { await send() }
                    }
                }

                if didSend {
                    Section {
                        Text("Check your email for a password reset link.")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
            .navigationTitle("Reset Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func send() async {
        isWorking = true
        defer { isWorking = false }
        didSend = await services.auth.sendPasswordReset(email: email)
    }
}

