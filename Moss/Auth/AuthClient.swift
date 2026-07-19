import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import Supabase

@MainActor
final class AuthClient: ObservableObject {
    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(UUID, String?)
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?
    @Published var isPasswordRecovery = false

    let supabase: SupabaseClient
    private var stateTask: Task<Void, Never>?
    private var pendingAppleNonce: String?
    private let configurationError = AppSecrets.supabaseConfigurationError

    init() {
        supabase = SupabaseClient(
            supabaseURL: AppSecrets.supabaseURL,
            supabaseKey: AppSecrets.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    deinit { stateTask?.cancel() }

    var currentUserID: UUID? {
        if case let .signedIn(id, _) = state { id } else { nil }
    }

    func currentAccessToken() async -> String? {
        do {
            return try await supabase.auth.session.accessToken
        } catch {
            return nil
        }
    }

    func bootstrap() async {
        if let configurationError {
            Log.error(AppConfigurationError(message: configurationError), category: "auth.configuration")
            apply(session: nil)
            return
        }

        do {
            let session = try await supabase.auth.session
            apply(session: session)
        } catch {
            apply(session: nil)
        }

        stateTask?.cancel()
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in supabase.auth.authStateChanges {
                if event == .passwordRecovery {
                    isPasswordRecovery = true
                }
                self.apply(session: session)
            }
        }
    }

    func signIn(email: String, password: String) async {
        lastError = nil
        guard ensureSupabaseConfigured(category: "auth.signIn.configuration") else { return }
        do {
            _ = try await supabase.auth.signIn(email: email, password: password)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.signIn")
        }
    }

    enum SignUpResult: Equatable {
        case signedIn
        case needsEmailConfirmation(email: String)
    }

    func signUp(email: String, password: String, displayName: String) async -> SignUpResult? {
        lastError = nil
        guard ensureSupabaseConfigured(category: "auth.signUp.configuration") else { return nil }
        do {
            let response = try await supabase.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(displayName)],
                redirectTo: AppSecrets.authRedirectURL
            )
            if response.session != nil {
                apply(session: response.session)
                return .signedIn
            }
            return .needsEmailConfirmation(email: email)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.signUp")
            return nil
        }
    }

    func sendPasswordReset(email: String) async -> Bool {
        lastError = nil
        guard ensureSupabaseConfigured(category: "auth.resetPassword.configuration") else { return false }
        do {
            try await supabase.auth.resetPasswordForEmail(email, redirectTo: AppSecrets.authRedirectURL)
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.resetPassword")
            return false
        }
    }

    func updatePassword(newPassword: String) async -> Bool {
        lastError = nil
        guard ensureSupabaseConfigured(category: "auth.updatePassword.configuration") else { return false }
        do {
            _ = try await supabase.auth.update(user: UserAttributes(password: newPassword))
            isPasswordRecovery = false
            try await supabase.auth.signOut()
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.updatePassword")
            return false
        }
    }

    func signOut() async {
        do {
            try await supabase.auth.signOut()
            apply(session: nil)
        } catch {
            Log.error(error, category: "auth.signOut")
        }
    }

    func deleteAccount() async throws {
        try await supabase.rpc("delete_my_account").execute()
        try await supabase.auth.signOut()
        apply(session: nil)
    }

    func handle(callbackURL url: URL) async {
        guard ensureSupabaseConfigured(category: "auth.callback.configuration") else { return }
        do {
            try await supabase.auth.session(from: url)
            let session = try await supabase.auth.session
            apply(session: session)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.callback")
        }
    }

    func beginAppleSignIn(request: ASAuthorizationAppleIDRequest) {
        lastError = nil
        let nonce = AppleNonce.random()
        pendingAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleNonce.sha256(nonce)
    }

    func completeAppleSignIn(result: Result<ASAuthorization, Error>) async {
        defer { pendingAppleNonce = nil }

        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                return
            }
            lastError = error.localizedDescription
            Log.error(error, category: "auth.apple")

        case .success(let authorization):
            guard ensureSupabaseConfigured(category: "auth.apple.configuration") else { return }
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = pendingAppleNonce else {
                lastError = "Apple did not return a valid identity token."
                return
            }

            do {
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: token, nonce: nonce)
                )
                apply(session: session)

                if let firstName = credential.fullName?.givenName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !firstName.isEmpty {
                    _ = try? await supabase
                        .from("profiles")
                        .update(["display_name": firstName])
                        .eq("id", value: session.user.id.uuidString)
                        .execute()
                }
            } catch {
                lastError = error.localizedDescription
                Log.error(error, category: "auth.apple")
            }
        }
    }

    func signInWithGoogle() async {
        lastError = nil
        guard ensureSupabaseConfigured(category: "auth.google.configuration") else { return }

        do {
            let session = try await supabase.auth.signInWithOAuth(
                provider: .google,
                redirectTo: AppSecrets.authRedirectURL,
                scopes: "openid email profile"
            )
            apply(session: session)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                return
            }
            lastError = error.localizedDescription
            Log.error(error, category: "auth.google")
        }
    }

    private func apply(session: Session?) {
        if let session, !session.isExpired {
            state = .signedIn(session.user.id, session.user.email)
        } else {
            state = .signedOut
        }
    }

    private func ensureSupabaseConfigured(category: String) -> Bool {
        guard let configurationError else { return true }
        lastError = "Auth is not configured for this build."
        Log.error(AppConfigurationError(message: configurationError), category: category)
        return false
    }
}

private enum AppleNonce {
    private static let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    static func random(length: Int = 32) -> String {
        var result = ""
        var randomByte: UInt8 = 0

        while result.count < length {
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte) == errSecSuccess else {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }
            if Int(randomByte) < characters.count {
                result.append(characters[Int(randomByte)])
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct AppConfigurationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
