import Foundation
import XCTest
@testable import CashSDK

private final class DelegateRecorder: CashSDKDelegate {
    let seen = Locked<[Entitlements]>([])
    func cashSDK(_ sdk: CashSDK, didUpdateEntitlements entitlements: Entitlements) {
        seen.withValue { $0.append(entitlements) }
    }
}

/// Nothing refreshed at an entitlement's `expiresAt`, and the stream and delegate published the
/// raw snapshot: expired entitlements with a stale tier. The server's `expiresAt` already carries
/// the renewal grace, so the client adds none and acts exactly at the deadline, asking the
/// server before it takes any access away.
final class EntitlementExpiryTests: XCTestCase {

    private static func entitlement(_ id: String, rank: Int, expiresIn seconds: TimeInterval?) -> [String: Any] {
        var value: [String: Any] = ["identifier": id, "name": id.capitalized, "rank": rank, "source": "subscription"]
        if let seconds { value["expiresAt"] = isoDate(fromNow: seconds) }
        return value
    }

    private static func snapshotBody(_ entitlements: [[String: Any]], tier: Int, tierIdentifier: String) -> StubServer.Response {
        StubServer.Response(status: 200, body: json([
            "entitlements": entitlements, "tier": tier, "tierIdentifier": tierIdentifier,
            "consumables": [], "userId": "A",
        ]))
    }

    /// Whether a published snapshot lists `id`, whatever the time is now.
    private static func lists(_ snapshot: Entitlements, _ id: String) -> Bool {
        snapshot.entitlements.contains { $0.identifier == id }
    }

    private func collect(_ sdk: CashSDK) -> (Locked<[Entitlements]>, Task<Void, Never>) {
        let seen = Locked<[Entitlements]>([])
        let task = Task { for await value in sdk.entitlementUpdates { seen.withValue { $0.append(value) } } }
        return (seen, task)
    }

    func testNextExpiryIgnoresPastAndUnreadableDeadlines() {
        let now = Date()
        let soon = Entitlement(identifier: "a", name: "A", expiresAt: isoDate(fromNow: 30))
        let later = Entitlement(identifier: "b", name: "B", expiresAt: isoDate(fromNow: 3600))
        let past = Entitlement(identifier: "c", name: "C", expiresAt: isoDate(fromNow: -30))
        let garbage = Entitlement(identifier: "d", name: "D", expiresAt: "tomorrow")
        let perpetual = Entitlement(identifier: "e", name: "E")
        let snapshot = Entitlements(entitlements: [later, past, garbage, perpetual, soon], tier: 1, tierIdentifier: "a")
        XCTAssertEqual(snapshot.nextExpiry(after: now)?.timeIntervalSince(now) ?? 0, 30, accuracy: 1)
        XCTAssertNil(Entitlements(entitlements: [past, garbage, perpetual], tier: 0, tierIdentifier: nil).nextExpiry(after: now))
        XCTAssertFalse(garbage.isActive, "an unreadable deadline fails closed")
    }

    func testExpiredEntitlementsLeaveTheTierToo() {
        let snapshot = Entitlements(entitlements: [
            Entitlement(identifier: "pro", name: "Pro", rank: 2, expiresAt: isoDate(fromNow: -1)),
            Entitlement(identifier: "basic", name: "Basic", rank: 1),
        ], tier: 2, tierIdentifier: "pro", transferredFromAnotherAccount: true)
        let visible = snapshot.removingExpiredAccess()
        XCTAssertEqual(visible.entitlements.map(\.identifier), ["basic"])
        XCTAssertEqual(visible.tier, 1)
        XCTAssertEqual(visible.tierIdentifier, "basic")
        XCTAssertEqual(visible.transferredFromAnotherAccount, true)
    }

    func testStreamAndDelegateNeverPublishExpiredAccess() async throws {
        let server = StubServer { request in
            guard request.path == "/v1/entitlements" else { return StubServer.Response(status: 202) }
            return Self.snapshotBody([Self.entitlement("pro", rank: 2, expiresIn: -60), Self.entitlement("basic", rank: 1, expiresIn: nil)],
                                     tier: 2, tierIdentifier: "pro")
        }
        let sdk = makeSDK(server)
        let delegate = DelegateRecorder()
        sdk.delegate = delegate
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        await eventually { seen.value.contains { $0.tier == 1 } && delegate.seen.value.contains { $0.tier == 1 } }
        for published in seen.value + delegate.seen.value {
            XCTAssertFalse(Self.lists(published, "pro"), "expired access was published")
            XCTAssertNotEqual(published.tierIdentifier, "pro", "a stale tier was published")
        }
        XCTAssertEqual(sdk.entitlements.tier, 1)
    }

    /// Whether the stream took `pro` away after first granting it.
    private static func withdrawn(_ values: [Entitlements]) -> Bool {
        guard let granted = values.firstIndex(where: { lists($0, "pro") }) else { return false }
        return values[(granted + 1)...].contains { !lists($0, "pro") }
    }

    /// Serves `pro` expiring in one second on the first read, then whatever `later` returns.
    private func expiringServer(
        reads: Locked<[RecordedRequest]>,
        later: @escaping @Sendable (RecordedRequest, Int) -> StubServer.Response
    ) -> StubServer {
        StubServer { request in
            guard request.path == "/v1/entitlements" else { return StubServer.Response(status: 202) }
            let count = reads.withValue { $0.append(request); return $0.count }
            if count == 1 {
                return StubServer.Response(status: 200, headers: ["ETag": "W/\"first\""], body: json([
                    "entitlements": [Self.entitlement("pro", rank: 2, expiresIn: 1)], "tier": 2,
                    "tierIdentifier": "pro", "consumables": [], "userId": "A",
                ]))
            }
            return later(request, count)
        }
    }

    private static var renewed: StubServer.Response {
        snapshotBody([entitlement("pro", rank: 2, expiresIn: 3600)], tier: 2, tierIdentifier: "pro")
    }

    func testRenewalAtExpiresAtIsPublishedWithoutAGap() async throws {
        let reads = Locked<[RecordedRequest]>([])
        let server = expiringServer(reads: reads) { request, _ in
            // The real server answers 304 to a matching If-None-Match. The refresh must not send one.
            request.header("If-None-Match") == nil ? Self.renewed : StubServer.Response(status: 304)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        XCTAssertTrue(sdk.entitlements.isActive("pro"))
        await eventually("no refresh at expiresAt") { reads.value.count >= 2 }
        await eventually("the renewal was not applied") { sdk.entitlements.entitlements.first?.expiryDate.map { $0 > Date().addingTimeInterval(60) } == true }
        XCTAssertNil(reads.value[1].header("If-None-Match"), "a 304 would only confirm the deadline that just passed")
        XCTAssertFalse(Self.withdrawn(seen.value), "access flickered off and on for a subscription the server had renewed")
        XCTAssertTrue(sdk.entitlements.isActive("pro"))
    }

    func testFailedRefreshAtExpiresAtEndsAccessAndRetries() async throws {
        let reads = Locked<[RecordedRequest]>([])
        let server = expiringServer(reads: reads) { _, count in
            count == 2 ? StubServer.Response(status: 503) : Self.renewed
        }
        let sdk = makeSDK(server)
        sdk.expiryRetryBase.value = 0.2
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        // Nothing proves the access continues, so it ends (fail closed)...
        await eventually("access was not withdrawn when the server could not be asked") { Self.withdrawn(seen.value) }
        XCTAssertFalse(sdk.entitlements.isActive("pro"))
        // ...and the refresh is tried again, which finds the renewal.
        await eventually("the failed refresh was not retried") { reads.value.count >= 3 }
        await eventually("the retry's answer was not published") { seen.value.last.map { Self.lists($0, "pro") } == true }
        XCTAssertTrue(sdk.entitlements.isActive("pro"))
    }

    func testUnchangedAnswerAtExpiresAtEndsAccessWithoutAskingAgain() async throws {
        let reads = Locked<[RecordedRequest]>([])
        // A 304 even without If-None-Match (a caching proxy): the snapshot on screen is current.
        let server = expiringServer(reads: reads) { _, _ in StubServer.Response(status: 304) }
        let sdk = makeSDK(server)
        sdk.expiryRetryBase.value = 0.1
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        await eventually("an answered refresh must still end expired access") { Self.withdrawn(seen.value) }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(reads.value.count, 2, "the server answered, so there is nothing to retry")
        XCTAssertFalse(sdk.entitlements.isActive("pro"))
    }

    func testExpiredTokenIsRenewedForTheRefreshAtExpiresAt() async throws {
        let fresh = fixtureToken("A", expiresIn: 3600)
        let reads = Locked<[RecordedRequest]>([])
        let server = expiringServer(reads: reads) { request, _ in
            request.header("X-CashSDK-User-Token") == fresh ? Self.renewed : StubServer.Response(status: 401, body: json(["error": "unauthenticated_user"]))
        }
        let sdk = makeSDK(server)
        // The token runs out just before the entitlement does.
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A", expiresIn: 0.6))
        let provided = Locked(0)
        sdk.userTokenProvider = { _ in provided.withValue { $0 += 1 }; return fresh }
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        await eventually("no refresh at expiresAt") { reads.value.count >= 2 }
        await eventually("the renewal was not applied") { sdk.entitlements.entitlements.first?.expiryDate.map { $0 > Date().addingTimeInterval(60) } == true }
        XCTAssertEqual(reads.value[1].header("X-CashSDK-User-Token"), fresh, "renewed before asking, not rejected locally")
        XCTAssertEqual(provided.value, 1)
        XCTAssertFalse(Self.withdrawn(seen.value))
    }

    func testHangingProviderStillEndsAccessAfterTheTimeout() async throws {
        let reads = Locked<[RecordedRequest]>([])
        let server = expiringServer(reads: reads) { _, _ in Self.renewed }
        let sdk = makeSDK(server)
        sdk.expiryRefreshTimeout.value = 0.3
        // The token runs out before the entitlement, and the host's provider never answers.
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A", expiresIn: 0.6))
        let latch = TestLatch()
        sdk.userTokenProvider = { _ in await latch.wait(); return fixtureToken("A") }
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        let deadline = Date().addingTimeInterval(1)
        await eventually("access stayed on while the provider hung") { Self.withdrawn(seen.value) }
        XCTAssertLessThan(Date().timeIntervalSince(deadline), 1.5, "withdrawn soon after the timeout, not after the provider")
        XCTAssertEqual(reads.value.count, 1, "nothing was read without a token")

        // The provider answers late: the refresh it was holding up still goes through.
        await latch.open()
        await eventually("the late answer was dropped") { seen.value.last.map { Self.lists($0, "pro") } == true }
        XCTAssertTrue(sdk.entitlements.isActive("pro"))
    }

    func testRetryWaitsForRetryAfter() async throws {
        let reads = Locked<[RecordedRequest]>([])
        let times = Locked<[Date]>([])
        let server = expiringServer(reads: reads) { _, count in
            times.withValue { $0.append(Date()) }
            return count == 2 ? StubServer.Response(status: 429, headers: ["Retry-After": "1"]) : Self.renewed
        }
        let sdk = makeSDK(server)
        sdk.expiryRetryBase.value = 0.05
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        await eventually("the throttled refresh was not retried") { reads.value.count >= 3 }
        let gap = times.value[1].timeIntervalSince(times.value[0])
        XCTAssertGreaterThanOrEqual(gap, 0.95, "retried before the server's Retry-After")
        await eventually { seen.value.last.map { Self.lists($0, "pro") } == true }
    }

    func testRejectedTokenIsRenewedForTheRefreshAtExpiresAt() async throws {
        let original = fixtureToken("A")
        let fresh = fixtureToken("A", expiresIn: 7200)
        let reads = Locked<[RecordedRequest]>([])
        let server = expiringServer(reads: reads) { request, _ in
            // The server stopped accepting the original token (a rotated secret, say).
            request.header("X-CashSDK-User-Token") == original
                ? StubServer.Response(status: 401, body: json(["error": "unauthenticated_user"]))
                : Self.renewed
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: original)
        sdk.userTokenProvider = { _ in fresh }
        let (seen, task) = collect(sdk)
        defer { task.cancel() }

        _ = try await sdk.refreshEntitlements()
        await eventually("the rejected refresh was not retried with a new token") { reads.value.count >= 3 }
        XCTAssertEqual(reads.value.map { $0.header("X-CashSDK-User-Token") }, [original, original, fresh])
        await eventually("the renewal was not applied") { sdk.entitlements.entitlements.first?.expiryDate.map { $0 > Date().addingTimeInterval(60) } == true }
        XCTAssertFalse(Self.withdrawn(seen.value))
    }

    func testANewSnapshotReplacesTheScheduledRefresh() async throws {
        let reads = Locked(0)
        let server = StubServer { request in
            guard request.path == "/v1/entitlements" else { return StubServer.Response(status: 202) }
            let read = reads.withValue { $0 += 1; return $0 }
            // The second snapshot has no deadline, so the wake-up set for the first must go.
            return Self.snapshotBody([Self.entitlement("pro", rank: 2, expiresIn: read == 1 ? 0.5 : nil)], tier: 2, tierIdentifier: "pro")
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        _ = try await sdk.refreshEntitlements()
        _ = try await sdk.refreshEntitlements()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(reads.value, 2, "a replaced wake-up must not refresh")
        XCTAssertTrue(sdk.entitlements.isActive("pro"))
    }
}
