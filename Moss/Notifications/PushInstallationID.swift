import Foundation
import Security

protocol PushInstallationIDProviding: Sendable {
    func installationID() throws -> UUID
}

protocol PushInstallationIDStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
}

struct KeychainPushInstallationIDProvider: PushInstallationIDProviding {
    static let account = "push-gateway.installation-id"

    private let store: any PushInstallationIDStoring

    init(store: any PushInstallationIDStoring = SecurityPushInstallationIDStore()) {
        self.store = store
    }

    func installationID() throws -> UUID {
        if let stored = try store.read(account: Self.account),
           let installationID = UUID(uuidString: stored) {
            return installationID
        }

        let installationID = UUID()
        try store.write(
            installationID.uuidString.lowercased(),
            account: Self.account
        )
        return installationID
    }
}

struct SecurityPushInstallationIDStore: PushInstallationIDStoring {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "app.getmoss.moss") {
        self.service = service
    }

    func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { throw KeychainError.invalidData }
        return value
    }

    func write(_ value: String, account: String) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var insertion = identity
        for (key, value) in attributes {
            insertion[key] = value
        }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }
}

private enum KeychainError: LocalizedError {
    case invalidData
    case status(OSStatus)

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidData:
            "The push installation identifier in Keychain was not readable."
        case .status(let status):
            "Keychain returned status \(status)."
        }
    }
}
