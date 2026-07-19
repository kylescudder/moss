import AuthenticationServices
import Combine
import Foundation
import Supabase

@MainActor
final class AuthClient: ObservableObject {
    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(userID: UUID, email: String?)
    }

    private enum AuthOperationError: LocalizedError {
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let operation):
                return "\(operation) timed out. Check your connection and try again."
            }
        }
    }

    private final class AuthContinuationGate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }

    private static let authOperationTimeoutSeconds = 20
    private static let recoveryPendingKey = "auth.recoveryPendingUntil"

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?
    /// True while the app holds a password-recovery session. RootView uses
    /// this to keep the main app hidden and present ResetPasswordSheet.
    @Published var isPasswordRecovery = false

    let supabase: SupabaseClient

    private var stateTask: Task<Void, Never>?
    private var pendingAppleNonce: String?
    private var lastHandledCallback: (url: String, at: Date)?
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
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    func currentAccessToken() async -> String? {
        do {
            return try await supabase.auth.session.accessToken
        } catch {
            return nil
        }
    }

    func bootstrap() async {
        guard ensureSupabaseConfigured(category: "auth.configuration") else {
            apply(session: nil)
            return
        }

        Log.breadcrumb("auth bootstrap started", category: "auth")
        do {
            let session = try await supabase.auth.session
            Log.event("auth bootstrap session read", category: "auth", metadata: [
                "hasSession": true,
                "isExpired": session.isExpired,
            ])
            apply(session: session)
        } catch {
            Log.event(
                "auth bootstrap has no active session",
                category: "auth",
                metadata: ["reason": error.localizedDescription]
            )
            apply(session: nil)
        }

        stateTask?.cancel()
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in supabase.auth.authStateChanges {
                Log.event("auth state changed", category: "auth", metadata: [
                    "event": String(describing: event),
                    "hasSession": session != nil,
                ])
                if event == .passwordRecovery {
                    self.isPasswordRecovery = true
                    Log.breadcrumb("password recovery auth event received", category: "auth")
                }
                self.apply(session: session)
            }
        }
    }

    private func apply(session: Session?) {
        if let session, !session.isExpired {
            state = .signedIn(userID: session.user.id, email: session.user.email)
            Log.breadcrumb("session active", category: "auth")
        } else {
            state = .signedOut
            Log.breadcrumb("signed out", category: "auth")
        }
    }

    private func withAuthTimeout<T>(
        operationName: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AuthContinuationGate(continuation)
            let task = Task { @MainActor in
                do {
                    gate.resume(returning: try await operation())
                } catch {
                    gate.resume(throwing: error)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.authOperationTimeoutSeconds)) {
                task.cancel()
                gate.resume(throwing: AuthOperationError.timedOut(operationName))
            }
        }
    }

    // MARK: - Email and password

    enum SignUpResult: Equatable {
        case signedIn
        case needsEmailConfirmation(email: String)
    }

    func signUp(email: String, password: String, displayName: String?) async -> SignUpResult? {
        guard ensureSupabaseConfigured(category: "auth.signUp.configuration") else { return nil }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        Log.event("signup started", category: "auth", metadata: [
            "hasDisplayName": trimmedDisplayName?.isEmpty == false,
        ])

        do {
            let metadata: [String: AnyJSON]?
            if let trimmedDisplayName, !trimmedDisplayName.isEmpty {
                metadata = ["display_name": .string(trimmedDisplayName)]
            } else {
                metadata = nil
            }

            let client = supabase
            let response = try await withAuthTimeout(operationName: "Sign up") {
                try await client.auth.signUp(
                    email: trimmedEmail,
                    password: password,
                    data: metadata,
                    redirectTo: AppSecrets.authRedirectURL
                )
            }
            Self.clearPendingRecoveryFlag()

            if let session = response.session {
                apply(session: session)
            }

            let result: SignUpResult = response.session != nil
                ? .signedIn
                : .needsEmailConfirmation(email: trimmedEmail)
            Log.event("signup completed", category: "auth", metadata: [
                "createdSession": response.session != nil,
                "needsEmailConfirmation": response.session == nil,
            ])
            return result
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.signUp")
            return nil
        }
    }

    func resendSignupConfirmation(email: String) async -> Bool {
        guard ensureSupabaseConfigured(category: "auth.resendConfirmation.configuration") else { return false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil

        do {
            let client = supabase
            try await withAuthTimeout(operationName: "Resend confirmation") {
                try await client.auth.resend(
                    email: trimmedEmail,
                    type: .signup,
                    emailRedirectTo: AppSecrets.authRedirectURL
                )
            }
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.resendConfirmation")
            return false
        }
    }

    func signIn(email: String, password: String) async {
        guard ensureSupabaseConfigured(category: "auth.signIn.configuration") else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        Log.breadcrumb("email signin started", category: "auth")

        do {
            let client = supabase
            _ = try await withAuthTimeout(operationName: "Sign in") {
                try await client.auth.signIn(email: trimmedEmail, password: password)
            }
            Self.clearPendingRecoveryFlag()
            Log.breadcrumb("email signin completed", category: "auth")
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.signIn")
        }
    }

    // MARK: - Password reset

    func sendPasswordReset(email: String) async -> Bool {
        guard ensureSupabaseConfigured(category: "auth.resetPassword.configuration") else { return false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        Log.breadcrumb("password reset requested", category: "auth.reset")

        do {
            let client = supabase
            try await withAuthTimeout(operationName: "Password reset") {
                try await client.auth.resetPasswordForEmail(
                    trimmedEmail,
                    redirectTo: AppSecrets.authRedirectURL
                )
            }
            UserDefaults.standard.set(
                Date().addingTimeInterval(3600),
                forKey: Self.recoveryPendingKey
            )
            Log.breadcrumb("password reset email sent", category: "auth.reset")
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.resetPassword")
            return false
        }
    }

    func updatePassword(newPassword: String) async -> Bool {
        guard ensureSupabaseConfigured(category: "auth.updatePassword.configuration") else { return false }
        lastError = nil
        Log.breadcrumb("password update started", category: "auth.updatePassword")

        do {
            let client = supabase
            _ = try await withAuthTimeout(operationName: "Password update") {
                try await client.auth.update(user: UserAttributes(password: newPassword))
            }
            isPasswordRecovery = false
            Self.clearPendingRecoveryFlag()
            try await client.auth.signOut()
            apply(session: nil)
            Log.breadcrumb("password updated; recovery session signed out", category: "auth.updatePassword")
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.updatePassword")
            return false
        }
    }

    // MARK: - Apple

    func beginAppleSignIn(request: ASAuthorizationAppleIDRequest) {
        lastError = nil
        Log.breadcrumb("apple signin started", category: "auth.apple")
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
                Log.breadcrumb("apple signin cancelled", category: "auth.apple")
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
                let client = supabase
                let session = try await withAuthTimeout(operationName: "Apple sign in") {
                    try await client.auth.signInWithIdToken(
                        credentials: .init(provider: .apple, idToken: token, nonce: nonce)
                    )
                }
                apply(session: session)
                Self.clearPendingRecoveryFlag()
                Log.breadcrumb("apple signin completed", category: "auth.apple")

                if let firstName = credential.fullName?.givenName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !firstName.isEmpty {
                    await setInitialAppleDisplayName(
                        firstName,
                        userID: session.user.id,
                        email: session.user.email
                    )
                }
            } catch {
                lastError = error.localizedDescription
                Log.error(error, category: "auth.apple")
            }
        }
    }

    /// Apple can return a name for an existing linked account after consent is
    /// granted again. Only replace an unset or known email-derived placeholder;
    /// a user-edited display name must always win.
    private func setInitialAppleDisplayName(
        _ firstName: String,
        userID: UUID,
        email: String?
    ) async {
        do {
            _ = try await supabase
                .from("profiles")
                .update(["display_name": firstName])
                .eq("id", value: userID.uuidString)
                .is("display_name", value: nil)
                .execute()

            if let emailPrefix = email?.split(separator: "@", maxSplits: 1).first.map(String.init),
               !emailPrefix.isEmpty {
                _ = try await supabase
                    .from("profiles")
                    .update(["display_name": firstName])
                    .eq("id", value: userID.uuidString)
                    .eq("display_name", value: emailPrefix)
                    .execute()
            }
        } catch {
            Log.error(error, category: "auth.apple.displayName")
        }
    }

    // MARK: - Google OAuth

    func signInWithGoogle() async {
        guard ensureSupabaseConfigured(category: "auth.google.configuration") else { return }
        lastError = nil
        Log.breadcrumb("google signin started", category: "auth.google")

        do {
            let authURL = try supabase.auth.getOAuthSignInURL(
                provider: .google,
                scopes: "openid email profile",
                redirectTo: AppSecrets.authRedirectURL
            )
            let callback = try await GoogleSignIn.start(
                authURL: authURL,
                callbackScheme: AppSecrets.authRedirectURL.scheme ?? "moss"
            )
            let client = supabase
            try await withAuthTimeout(operationName: "Google sign in") {
                try await client.auth.session(from: callback)
            }
            let session = try await client.auth.session
            apply(session: session)
            Self.clearPendingRecoveryFlag()
            Log.breadcrumb("google signin completed", category: "auth.google")
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                Log.breadcrumb("google signin cancelled", category: "auth.google")
                return
            }
            lastError = error.localizedDescription
            Log.error(error, category: "auth.google")
        }
    }

    // MARK: - Callbacks

    func handle(callbackURL url: URL) async {
        guard ensureSupabaseConfigured(category: "auth.callback.configuration") else { return }

        let now = Date()
        if let lastHandledCallback,
           lastHandledCallback.url == url.absoluteString,
           now.timeIntervalSince(lastHandledCallback.at) < 5 {
            Log.breadcrumb("auth callback ignored (duplicate within 5s)", category: "auth.callback")
            return
        }
        lastHandledCallback = (url.absoluteString, now)

        let urlSaysRecovery = Self.urlContainsTypeRecovery(url)
        let flagSaysRecovery = Self.consumePendingRecoveryFlag()
        let isRecovery = urlSaysRecovery || flagSaysRecovery

        Log.event("auth callback received", category: "auth.callback", metadata: [
            "recovery": isRecovery,
            "url": Log.redactedURLDescription(url),
        ])

        if isRecovery {
            isPasswordRecovery = true
        }

        do {
            let client = supabase
            try await withAuthTimeout(operationName: "Auth callback") {
                try await client.auth.session(from: url)
            }
            let session = try await client.auth.session
            apply(session: session)
            Log.breadcrumb("auth callback session established", category: "auth.callback")
        } catch {
            if isRecovery {
                isPasswordRecovery = false
            }
            lastError = "Couldn't finish from this link: \(error.localizedDescription)"
            Log.error(error, category: "auth.callback")
        }
    }

    private static func urlContainsTypeRecovery(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        if components.queryItems?.contains(where: {
            $0.name == "type" && $0.value == "recovery"
        }) == true {
            return true
        }

        if let fragment = components.fragment {
            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == "type", parts[1] == "recovery" {
                    return true
                }
            }
        }

        return false
    }

    private static func consumePendingRecoveryFlag() -> Bool {
        guard let until = UserDefaults.standard.object(forKey: recoveryPendingKey) as? Date else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: recoveryPendingKey)
        return until > Date()
    }

    private static func clearPendingRecoveryFlag() {
        UserDefaults.standard.removeObject(forKey: recoveryPendingKey)
    }

    // MARK: - Session management

    func signOut() async {
        Self.clearPendingRecoveryFlag()
        isPasswordRecovery = false
        Log.breadcrumb("signout started", category: "auth")

        do {
            try await supabase.auth.signOut()
            apply(session: nil)
            Log.breadcrumb("signout completed", category: "auth")
        } catch {
            Log.error(error, category: "auth.signOut")
        }
    }

    func deleteAccount() async throws {
        Self.clearPendingRecoveryFlag()
        try await supabase.rpc("delete_my_account").execute()
        try await supabase.auth.signOut()
        isPasswordRecovery = false
        apply(session: nil)
    }

    private func ensureSupabaseConfigured(category: String) -> Bool {
        guard let configurationError else { return true }
        lastError = "Auth is not configured for this build."
        Log.error(AppConfigurationError(message: configurationError), category: category)
        return false
    }
}

struct AppConfigurationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
