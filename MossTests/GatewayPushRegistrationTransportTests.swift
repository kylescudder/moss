import Foundation
import XCTest
@testable import Moss

@MainActor
final class GatewayPushRegistrationTransportTests: XCTestCase {
    private let installationID = UUID(
        uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07"
    )!
    private let identity = PushIdentity(
        principalID: "principal-must-not-be-sent",
        accessToken: "test-access-token"
    )

    func testRegisterRequestMatchesSharedContractAndPreservesLeadingZeros() async throws {
        prepare(response: .http(statusCode: 204))
        let transport = makeTransport(baseURL: "https://push.example.test/")

        try await transport.register(
            installationID: installationID,
            deviceToken: Data([0x00, 0x0a, 0xff]),
            environment: .sandbox,
            identity: identity
        )

        let request = try XCTUnwrap(PushURLProtocolStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://push.example.test/v1/apps/moss/installations/550d5a6b-7248-49da-a4dc-92db45608c07"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["apns_token"] as? String, "000aff")
        XCTAssertEqual(json["apns_environment"] as? String, "sandbox")
        XCTAssertNil(json["principal_id"])
        XCTAssertNil(json["bundle_id"])
        XCTAssertNil(json["apple_team_id"])
        XCTAssertNil(json["key_id"])
        XCTAssertNil(json["supabase_url"])
    }

    func testUnregisterSendsNoBodyOrDeviceToken() async throws {
        prepare(response: .http(statusCode: 204))
        let transport = makeTransport()

        try await transport.unregister(
            installationID: installationID,
            identity: identity
        )

        let request = try XCTUnwrap(PushURLProtocolStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://push.example.test/v1/apps/moss/installations/550d5a6b-7248-49da-a4dc-92db45608c07/account-link"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(request.httpBody)
    }

    func testEvery2xxStatusSucceeds() async throws {
        PushURLProtocolStub.reset()
        for statusCode in [200, 201, 202, 204, 299] {
            PushURLProtocolStub.response = .http(statusCode: statusCode)
            try await makeTransport().unregister(
                installationID: installationID,
                identity: identity
            )
        }
    }

    func testHTTPFailureIsTyped() async {
        prepare(response: .http(statusCode: 503))

        do {
            try await makeTransport().unregister(
                installationID: installationID,
                identity: identity
            )
            XCTFail("Expected a typed status error")
        } catch {
            XCTAssertEqual(error as? PushGatewayError, .httpStatus(503))
        }
    }

    func testNonHTTPResponseIsTyped() async {
        prepare(response: .nonHTTP)

        do {
            try await makeTransport().unregister(
                installationID: installationID,
                identity: identity
            )
            XCTFail("Expected an invalid response error")
        } catch {
            XCTAssertEqual(error as? PushGatewayError, .invalidResponse)
        }
    }

    private func makeTransport(
        baseURL: String = "https://push.example.test"
    ) -> GatewayPushRegistrationTransport {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PushURLProtocolStub.self]
        return GatewayPushRegistrationTransport(
            configuration: PushGatewayConfiguration(
                urlString: baseURL,
                applicationID: "moss"
            )!,
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    private func prepare(response: PushURLProtocolStub.Response) {
        PushURLProtocolStub.reset()
        PushURLProtocolStub.response = response
    }
}

private final class PushURLProtocolStub: URLProtocol, @unchecked Sendable {
    enum Response {
        case http(statusCode: Int)
        case nonHTTP
    }

    private static let state = State()

    static var response: Response {
        get { state.response }
        set { state.response = newValue }
    }

    static var lastRequest: URLRequest? {
        state.lastRequest
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.lastRequest = request
        let response: URLResponse
        switch Self.state.response {
        case .http(let statusCode):
            response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        case .nonHTTP:
            response = URLResponse(
                url: request.url!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResponse = Response.http(statusCode: 204)
        private var storedRequest: URLRequest?

        var response: Response {
            get { withLock { storedResponse } }
            set { withLock { storedResponse = newValue } }
        }

        var lastRequest: URLRequest? {
            get { withLock { storedRequest } }
            set { withLock { storedRequest = newValue } }
        }

        func reset() {
            withLock {
                storedResponse = .http(statusCode: 204)
                storedRequest = nil
            }
        }

        private func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }
}
