import Foundation

struct PushGatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let applicationID: String

    init?(urlString: String?, applicationID: String?) {
        guard
            let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty,
            let baseURL = URL(string: urlString),
            ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""),
            baseURL.host != nil,
            let applicationID = applicationID?.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationID.range(
                of: #"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$"#,
                options: .regularExpression
            ) != nil
        else { return nil }

        self.baseURL = baseURL
        self.applicationID = applicationID
    }

    static var fromBundle: PushGatewayConfiguration? {
        from(bundle: .main)
    }

    static func from(bundle: Bundle) -> PushGatewayConfiguration? {
        PushGatewayConfiguration(
            urlString: bundle.object(forInfoDictionaryKey: "PUSH_GATEWAY_URL") as? String,
            applicationID: bundle.object(
                forInfoDictionaryKey: "PUSH_GATEWAY_APPLICATION_ID"
            ) as? String
        )
    }
}

struct PushIdentity: Equatable, Sendable {
    let principalID: String
    let accessToken: String
}

@MainActor
protocol PushIdentityProviding: AnyObject {
    func currentPushIdentity() async -> PushIdentity?
}

extension AuthClient: PushIdentityProviding {
    func currentPushIdentity() async -> PushIdentity? {
        guard
            let principalID = currentUserID?.uuidString.lowercased(),
            let accessToken = await currentAccessToken()
        else { return nil }
        return PushIdentity(
            principalID: principalID,
            accessToken: accessToken
        )
    }
}

enum APNSEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    static var current: APNSEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

protocol PushRegistrationTransport: Sendable {
    @MainActor
    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws

    @MainActor
    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws
}

struct GatewayPushRegistrationTransport: PushRegistrationTransport {
    let configuration: PushGatewayConfiguration
    let session: URLSession

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        let url = installationURL(installationID)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(identity.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(RegisterInstallationRequest(
            version: 1,
            platform: "ios",
            apnsToken: deviceToken.hexadecimalString,
            apnsEnvironment: environment
        ))

        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        let url = installationURL(installationID)
            .appending(path: "account-link")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(
            "Bearer \(identity.accessToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    private func installationURL(_ installationID: UUID) -> URL {
        configuration.baseURL
            .appending(path: "v1/apps")
            .appending(path: configuration.applicationID)
            .appending(path: "installations")
            .appending(path: installationID.uuidString.lowercased())
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PushGatewayError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PushGatewayError.httpStatus(http.statusCode)
        }
    }
}

private struct RegisterInstallationRequest: Encodable {
    let version: Int
    let platform: String
    let apnsToken: String
    let apnsEnvironment: APNSEnvironment

    enum CodingKeys: String, CodingKey {
        case version
        case platform
        case apnsToken = "apns_token"
        case apnsEnvironment = "apns_environment"
    }
}

enum PushGatewayError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
}

@MainActor
func selectPushRegistrationTransport(
    configuration: PushGatewayConfiguration?,
    gateway: (PushGatewayConfiguration) -> any PushRegistrationTransport,
    legacy: () -> any PushRegistrationTransport
) -> any PushRegistrationTransport {
    if let configuration {
        gateway(configuration)
    } else {
        legacy()
    }
}

extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
