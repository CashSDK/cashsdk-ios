import Foundation
import XCTest
@testable import CashSDK

/// The owner-keyed cache used to load only after the user token passed its local check, so an
/// offline launch with an expired token showed no access at all. And `identify` published an
/// empty snapshot before reloading the cache, so re-identifying the same user flashed Pro to free.
final class IdentityCacheTests: XCTestCase {

    private func cachedStore(_ entitlements: [Entitlement], owner: String = "A") async -> EntitlementStore {
        let store = temporaryStore()
        let highest = entitlements.max { ($0.rank ?? 0) < ($1.rank ?? 0) }
        let snapshot = Entitlements(entitlements: entitlements, tier: highest?.rank ?? 0, tierIdentifier: highest?.identifier, consumables: [])
        await store.update(snapshot, owner: owner, environment: "Production", etag: "W/\"cached\"")
        return store
    }

    func testOfflineLaunchWithAnExpiredTokenStillShowsCachedAccess() async throws {
        let store = await cachedStore([Entitlement(identifier: "pro", name: "Pro", rank: 2)])
        let server = StubServer { _ in StubServer.Response(status: 503) }
        let sdk = makeSDK(server, store: store)
        sdk.identify(userId: "A", userToken: fixtureToken("A", expiresIn: -600))
        do {
            _ = try await sdk.waitUntilReady()
            XCTFail("the token has expired")
        } catch CashSDKError.identityTokenExpired {}
        XCTAssertTrue(sdk.entitlements.isActive("pro"), "cached access is offline-valid and belongs to this user")
        XCTAssertEqual(sdk.tierIdentifier, "pro")
    }

    func testCachedAccessIsStillFilteredByExpiry() async throws {
        let store = await cachedStore([
            Entitlement(identifier: "pro", name: "Pro", rank: 2, expiresAt: isoDate(fromNow: -60)),
            Entitlement(identifier: "basic", name: "Basic", rank: 1),
        ])
        let sdk = makeSDK(StubServer(), store: store)
        sdk.identify(userId: "A", userToken: fixtureToken("A", expiresIn: -600))
        _ = try? await sdk.waitUntilReady()
        XCTAssertFalse(sdk.entitlements.isActive("pro"))
        XCTAssertEqual(sdk.tier, 1)
        XCTAssertEqual(sdk.tierIdentifier, "basic")
    }

    func testCacheOfAnotherUserIsNeverServed() async throws {
        let store = await cachedStore([Entitlement(identifier: "pro", name: "Pro", rank: 2)], owner: "A")
        let sdk = makeSDK(StubServer(), store: store)
        sdk.identify(userId: "B", userToken: fixtureToken("B", expiresIn: -600))
        _ = try? await sdk.waitUntilReady()
        XCTAssertTrue(sdk.entitlements.isEmpty)
    }

    func testIdentifyingTheSameUserAgainKeepsAccessOnScreen() async throws {
        let server = StubServer { request in
            request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        _ = try await sdk.refreshEntitlements()
        XCTAssertTrue(sdk.entitlements.isActive("pro"))

        let seen = Locked<[Entitlements]>([])
        let task = Task { for await value in sdk.entitlementUpdates { seen.withValue { $0.append(value) } } }
        defer { task.cancel() }
        await eventually { !seen.value.isEmpty }

        sdk.identify(userId: "A", userToken: fixtureToken("A"))
        XCTAssertTrue(sdk.entitlements.isActive("pro"), "a fresh token for the same user is not a sign-out")
        _ = try await sdk.waitUntilReady()
        XCTAssertTrue(sdk.entitlements.isActive("pro"))
        XCTAssertFalse(seen.value.contains { !$0.isActive("pro") }, "the stream flashed an empty snapshot")
    }

    func testAnotherUserSeesNothingOfThePreviousOne() async throws {
        let server = StubServer { request in
            request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        _ = try await sdk.refreshEntitlements()
        XCTAssertTrue(sdk.entitlements.isActive("pro"))

        sdk.identify(userId: "B", userToken: fixtureToken("B"))
        XCTAssertTrue(sdk.entitlements.isEmpty, "B must not see A's access, not even before B's cache loads")
        _ = try await sdk.waitUntilReady()
        XCTAssertTrue(sdk.entitlements.isEmpty)
    }
}
