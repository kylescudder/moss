import SwiftUI

struct ForgotPasswordSheet: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var isWorking = false
    @State private var didSend = false
    @State private var localError: String?

    init(email: String = "") {
        self._email = State(initialValue: email)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text(didSend
                         ? "If an account exists for \(email), you'll get a reset link shortly. Check your spam folder if it isn't in your inbox."
                         : "Enter the email tied to your account and we'll send a link to set a new password.")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    if !didSend {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .background(Theme.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                        if let error = localError ?? services.auth.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        PrimaryButton(title: "Send reset link", isLoading: isWorking) {
                            Task { await send() }
                        }
                        .disabled(!isFormValid || isWorking)
                    } else {
                        PrimaryButton(title: "Done") { dismiss() }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Colors.background)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !didSend {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var isFormValid: Bool {
        email.contains("@") && email.contains(".")
    }

    private func send() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        localError = nil
        didSend = await services.auth.sendPasswordReset(email: email)
    }
}
