import Foundation
import XCTest
@testable import Moss

@MainActor
final class PushRegistrationLifecycleTests: XCTestCase {
    private let installationID = UUID(
        uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07"
    )!
    private let accountA = PushIdentity(
        principalID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        accessToken: "token-a"
    )
    private let accountB = PushIdentity(
        principalID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        accessToken: "token-b"
    )

    func testTokenBeforeSignInIsRetainedThenRegistered() async {
        let fixture = makeFixture(identity: nil)

        await fixture.lifecycle.receivedDeviceToken(Data([0x01]))
        XCTAssertTrue(fixture.transport.events.isEmpty)

        fixture.identity.current = accountA
        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: true)

        XCTAssertEqual(fixture.transport.events, [
            .register(installationID, Data([0x01]), .sandbox, accountA),
        ])
        XCTAssertEqual(fixture.registrar.registrationCount, 1)
    }

    func testSignInBeforeTokenWaitsForTokenCallback() async {
        let fixture = makeFixture(identity: accountA)

        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: true)
        XCTAssertTrue(fixture.transport.events.isEmpty)

        await fixture.lifecycle.receivedDeviceToken(Data([0x02]))
        XCTAssertEqual(fixture.transport.events, [
            .register(installationID, Data([0x02]), .sandbox, accountA),
        ])
    }

    func testForegroundRefreshRegistersWithIOSOnlyWhenSignedInAndAuthorized() async {
        let fixture = makeFixture(identity: accountA)

        await fixture.lifecycle.refreshRegistration(
            authorizationAllowsRemoteRegistration: false
        )
        XCTAssertEqual(fixture.registrar.registrationCount, 0)

        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: false)
        await fixture.lifecycle.refreshRegistration(
            authorizationAllowsRemoteRegistration: true
        )
        XCTAssertEqual(fixture.registrar.registrationCount, 1)
    }

    func testRepeatedTokenCallbackIsSafeAndIdempotentlyRegistersAgain() async {
        let fixture = makeFixture(identity: accountA)
        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: false)

        await fixture.lifecycle.receivedDeviceToken(Data([0x03]))
        await fixture.lifecycle.receivedDeviceToken(Data([0x03]))

        XCTAssertEqual(fixture.transport.events.count, 2)
        XCTAssertEqual(fixture.transport.events[0], fixture.transport.events[1])
    }

    func testAccountSwitchUnregistersAThenRegistersBWithSameInstallation() async {
        let fixture = makeFixture(identity: accountA)
        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: false)
        await fixture.lifecycle.receivedDeviceToken(Data([0x04]))

        await fixture.lifecycle.deactivate()
        fixture.identity.current = accountB
        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: false)

        XCTAssertEqual(fixture.transport.events, [
            .register(installationID, Data([0x04]), .sandbox, accountA),
            .unregister(installationID, accountA),
            .register(installationID, Data([0x04]), .sandbox, accountB),
        ])
    }

    func testFailedUnregisterDoesNotBlockLaterAccountRebind() async {
        let fixture = makeFixture(identity: accountA)
        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: false)
        await fixture.lifecycle.receivedDeviceToken(Data([0x05]))
        fixture.transport.unregisterError = TestLifecycleError.expected

        await fixture.lifecycle.deactivate()
        fixture.identity.current = accountB
        fixture.transport.unregisterError = nil
        await fixture.lifecycle.activate(authorizationAllowsRemoteRegistration: false)

        XCTAssertEqual(fixture.transport.events.last, .register(
            installationID,
            Data([0x05]),
            .sandbox,
            accountB
        ))
    }

    func testConfigurationSelectsExactlyOneTransport() async throws {
        let gateway = SpyPushRegistrationTransport()
        let legacy = SpyPushRegistrationTransport()
        let configured = PushGatewayConfiguration(
            urlString: "https://push.example.test",
            applicationID: "moss"
        )

        let selectedGateway = selectPushRegistrationTransport(
            configuration: configured,
            gateway: { _ in gateway },
            legacy: { legacy }
        )
        try await selectedGateway.register(
            installationID: installationID,
            deviceToken: Data([0x06]),
            environment: .sandbox,
            identity: accountA
        )
        XCTAssertEqual(gateway.events.count, 1)
        XCTAssertTrue(legacy.events.isEmpty)

        gateway.events.removeAll()
        let selectedLegacy = selectPushRegistrationTransport(
            configuration: nil,
            gateway: { _ in gateway },
            legacy: { legacy }
        )
        try await selectedLegacy.register(
            installationID: installationID,
            deviceToken: Data([0x06]),
            environment: .sandbox,
            identity: accountA
        )
        XCTAssertTrue(gateway.events.isEmpty)
        XCTAssertEqual(legacy.events.count, 1)
    }

    func testSessionInvalidationRunsUnregisterFirstAndReactivatesOnFailure() async {
        let auth = AuthClient()
        var events: [String] = []
        auth.beforeSessionInvalidation = { events.append("unregister") }
        auth.afterSessionInvalidationFailure = { events.append("activate") }

        do {
            let _: Void = try await auth.performSessionInvalidation {
                events.append("invalidate")
                throw TestLifecycleError.expected
            }
            XCTFail("Expected invalidation failure")
        } catch {
            XCTAssertEqual(error as? TestLifecycleError, .expected)
        }

        XCTAssertEqual(events, ["unregister", "invalidate", "activate"])
    }

    private func makeFixture(identity: PushIdentity?) -> LifecycleFixture {
        let identityProvider = FakePushIdentityProvider(current: identity)
        let transport = SpyPushRegistrationTransport()
        let registrar = SpyRemoteNotificationRegistrar()
        let lifecycle = PushRegistrationLifecycle(
            identityProvider: identityProvider,
            installationIDProvider: FixedInstallationIDProvider(id: installationID),
            transport: transport,
            remoteNotifications: registrar,
            environment: .sandbox
        )
        return LifecycleFixture(
            lifecycle: lifecycle,
            identity: identityProvider,
            transport: transport,
            registrar: registrar
        )
    }
}

private struct LifecycleFixture {
    let lifecycle: PushRegistrationLifecycle
    let identity: FakePushIdentityProvider
    let transport: SpyPushRegistrationTransport
    let registrar: SpyRemoteNotificationRegistrar
}

private enum TestLifecycleError: Error, Equatable {
    case expected
}

@MainActor
private final class FakePushIdentityProvider: PushIdentityProviding {
    var current: PushIdentity?

    init(current: PushIdentity?) {
        self.current = current
    }

    func currentPushIdentity() async -> PushIdentity? { current }
}

private struct FixedInstallationIDProvider: PushInstallationIDProviding {
    let id: UUID

    func installationID() throws -> UUID { id }
}

@MainActor
private final class SpyRemoteNotificationRegistrar: RemoteNotificationRegistering {
    private(set) var registrationCount = 0

    func registerForRemoteNotifications() {
        registrationCount += 1
    }
}

@MainActor
private final class SpyPushRegistrationTransport: PushRegistrationTransport {
    enum Event: Equatable {
        case register(UUID, Data, APNSEnvironment, PushIdentity)
        case unregister(UUID, PushIdentity)
    }

    var events: [Event] = []
    var unregisterError: Error?

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        events.append(.register(
            installationID,
            deviceToken,
            environment,
            identity
        ))
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        events.append(.unregister(installationID, identity))
        if let unregisterError { throw unregisterError }
    }
}
