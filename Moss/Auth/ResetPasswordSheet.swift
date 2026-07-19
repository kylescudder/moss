import SwiftUI

/// Presented whenever Supabase establishes a password-recovery session. It
/// cannot be dismissed into the app: the user must set a password or sign out.
struct ResetPasswordSheet: View {
    @EnvironmentObject private var services: AppServices

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("Choose a new password to finish signing in.")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    SecureField("Confirm new password", text: $confirmation)
                        .textContentType(.newPassword)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    if let error = localError ?? services.auth.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    PrimaryButton(title: "Save new password", isLoading: isWorking) {
                        Task { await save() }
                    }
                    .disabled(!isFormValid || isWorking)
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Colors.background)
            .navigationTitle("Set a new password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") {
                        Task { await services.auth.signOut() }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled()
        }
    }

    private var isFormValid: Bool {
        password.count >= 6 && password == confirmation
    }

    private func save() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        localError = nil

        guard password == confirmation else {
            localError = "Passwords don't match."
            return
        }

        _ = await services.auth.updatePassword(newPassword: password)
    }
}
