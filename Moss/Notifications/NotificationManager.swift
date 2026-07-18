import Foundation
import Supabase
import UIKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?

    private weak var auth: AuthClient?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func bind(auth: AuthClient) {
        self.auth = auth
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            await registerIfAuthorized()
        } catch {
            Log.error(error, category: "notifications.authorization")
        }
    }

    func registerIfAuthorized() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral else { return }
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func updateDeviceToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        await uploadDeviceToken(token)
    }

    private func uploadDeviceToken(_ token: String) async {
        guard let auth, let userID = auth.currentUserID else { return }
        do {
            try await auth.supabase
                .from("device_tokens")
                .upsert(DeviceTokenUpsert(userID: userID, token: token, platform: "ios"), onConflict: "user_id,token")
                .execute()
        } catch {
            Log.error(error, category: "notifications.uploadToken")
        }
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
