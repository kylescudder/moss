import Foundation
import XCTest
@testable import Moss

final class PushGatewayConfigurationTests: XCTestCase {
    func testEmptyMissingAndMalformedURLDisableGateway() {
        XCTAssertNil(PushGatewayConfiguration(
            urlString: "",
            applicationID: "moss"
        ))
        XCTAssertNil(PushGatewayConfiguration(
            urlString: nil,
            applicationID: "moss"
        ))
        XCTAssertNil(PushGatewayConfiguration(
            urlString: "not a URL",
            applicationID: "moss"
        ))
        XCTAssertNil(PushGatewayConfiguration(
            urlString: "ftp://push.example.test",
            applicationID: "moss"
        ))
    }

    func testMissingOrInvalidApplicationIDDisablesGateway() {
        XCTAssertNil(PushGatewayConfiguration(
            urlString: "https://push.example.test",
            applicationID: nil
        ))
        XCTAssertNil(PushGatewayConfiguration(
            urlString: "https://push.example.test",
            applicationID: "Moss"
        ))
        XCTAssertNil(PushGatewayConfiguration(
            urlString: "https://push.example.test",
            applicationID: "mo"
        ))
    }

    func testValidConfigurationParsesWithoutAClientSecret() {
        let configuration = PushGatewayConfiguration(
            urlString: "https://push.example.test/",
            applicationID: "moss"
        )

        XCTAssertEqual(configuration?.baseURL.absoluteString, "https://push.example.test/")
        XCTAssertEqual(configuration?.applicationID, "moss")
    }

    func testInstallationIDIsStableLowercaseAndReplacesCorruptText() throws {
        let store = InMemoryPushInstallationIDStore()
        let provider = KeychainPushInstallationIDProvider(store: store)

        let first = try provider.installationID()
        let second = try provider.installationID()

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.lastAccount, "push-gateway.installation-id")
        XCTAssertEqual(store.value, first.uuidString.lowercased())

        store.value = "corrupt"
        let replacement = try provider.installationID()
        XCTAssertNotEqual(replacement, first)
        XCTAssertEqual(store.value, replacement.uuidString.lowercased())
    }

    func testInstallationIDStorageFailureIsSurfaced() {
        let store = InMemoryPushInstallationIDStore()
        store.error = TestStoreError.unavailable
        let provider = KeychainPushInstallationIDProvider(store: store)

        XCTAssertThrowsError(try provider.installationID()) { error in
            XCTAssertEqual(error as? TestStoreError, .unavailable)
        }
    }
}

private enum TestStoreError: Error, Equatable {
    case unavailable
}

private final class InMemoryPushInstallationIDStore: PushInstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    private var storedAccount: String?
    private var storedError: Error?

    var value: String? {
        get { withLock { storedValue } }
        set { withLock { storedValue = newValue } }
    }

    var lastAccount: String? {
        withLock { storedAccount }
    }

    var error: Error? {
        get { withLock { storedError } }
        set { withLock { storedError = newValue } }
    }

    func read(account: String) throws -> String? {
        try withLock {
            storedAccount = account
            if let storedError { throw storedError }
            return storedValue
        }
    }

    func write(_ value: String, account: String) throws {
        try withLock {
            storedAccount = account
            if let storedError { throw storedError }
            storedValue = value
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
