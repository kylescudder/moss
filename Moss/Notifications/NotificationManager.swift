import Foundation
import Supabase
import UIKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?

    private var lifecycle: PushRegistrationLifecycle?
    private var latestDeviceToken: Data?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func bind(auth: AuthClient) {
        let configuration = PushGatewayConfiguration.fromBundle
        let transport = selectPushRegistrationTransport(
            configuration: configuration,
            gateway: { configuration in
                GatewayPushRegistrationTransport(
                    configuration: configuration,
                    session: URLSession(configuration: .ephemeral)
                )
            },
            legacy: { LegacyPushRegistrationTransport(auth: auth) }
        )
        let lifecycle = PushRegistrationLifecycle(
            identityProvider: auth,
            installationIDProvider: KeychainPushInstallationIDProvider(),
            transport: transport,
            remoteNotifications: UIApplicationRemoteNotificationRegistrar(),
            environment: .current
        )
        self.lifecycle = lifecycle

        if let latestDeviceToken {
            Task { await lifecycle.receivedDeviceToken(latestDeviceToken) }
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            await registerIfAuthorized()
            return granted
        } catch {
            Log.error(error, category: "notifications.authorization")
            return false
        }
    }

    func registerIfAuthorized() async {
        await refreshAuthorizationStatus()
        await lifecycle?.refreshRegistration(
            authorizationAllowsRemoteRegistration: authorizationAllowsRemoteRegistration
        )
    }

    func updateDeviceToken(_ tokenData: Data) async {
        latestDeviceToken = tokenData
        deviceToken = tokenData.hexadecimalString
        await lifecycle?.receivedDeviceToken(tokenData)
    }

    func activate() async {
        await refreshAuthorizationStatus()
        await lifecycle?.activate(
            authorizationAllowsRemoteRegistration: authorizationAllowsRemoteRegistration
        )
    }

    func deactivate() async {
        await lifecycle?.deactivate()
    }

    func sessionEnded() {
        lifecycle?.sessionEnded()
    }

    func refreshRegistration() async {
        await registerIfAuthorized()
    }

    func registrationFailed(_ error: Error) {
        Log.error(error, category: "notifications.remoteRegistration")
    }

    private var authorizationAllowsRemoteRegistration: Bool {
        authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
    }
}

@MainActor
private final class LegacyPushRegistrationTransport: PushRegistrationTransport {
    private weak var auth: AuthClient?
    private var registeredToken: String?

    init(auth: AuthClient) {
        self.auth = auth
    }

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        guard let auth, let userID = UUID(uuidString: identity.principalID) else { return }
        let token = deviceToken.hexadecimalString
        try await auth.supabase
            .from("device_tokens")
            .upsert(
                DeviceTokenUpsert(
                    userID: userID,
                    token: token,
                    platform: "ios"
                ),
                onConflict: "user_id,token"
            )
            .execute()
        registeredToken = token
    }

    func unregister(installationID: UUID, identity: PushIdentity) async throws {
        guard let auth, let registeredToken else { return }
        try await auth.supabase
            .from("device_tokens")
            .delete()
            .eq("user_id", value: identity.principalID)
            .eq("token", value: registeredToken)
            .execute()
        self.registeredToken = nil
    }
}

private struct DeviceTokenUpsert: Encodable {
    let userID: UUID
    let token: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case token
        case platform
    }
}
