import Foundation
import XCTest
@testable import CashSDK

private actor ReadinessLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

// One hour, like the token the dashboard's backend snippet mints. A purchase needs at least
// five minutes left (`CashSDK.minimumTokenLifetimeForPurchase`).
private func token(_ user: String, expires: TimeInterval = Date().timeIntervalSince1970 + 3600) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["sub": user, "exp": expires])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private final class ReadinessProtocol: URLProtocol {
    static let requests = Locked<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withValue { $0.append(request) }
        let owner = request.value(forHTTPHeaderField: "X-CashSDK-User-Id") ?? ""
        let data = try! JSONSerialization.data(withJSONObject: ["entitlements": [], "tier": 0, "userId": owner, "version": 1, "consumables": []])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class IdentityReadinessTests: XCTestCase {
    private func sdk(observer: Bool = false) -> CashSDK {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadinessProtocol.self]
        let sdk = CashSDK(session: URLSession(configuration: configuration), automaticRecovery: false,
                          store: temporaryStore(), purchaseLog: temporaryPurchaseLog(), eventQueue: temporaryEventQueue())
        sdk.configure(with: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: URL(string: "https://fixture.invalid")!, observerMode: observer))
        return sdk
    }

    func testPurchaseWaitsForBlockedIdentityQueue() async throws {
        let sdk = sdk()
        let latch = ReadinessLatch()
        let blocked = expectation(description: "identity queue blocked")
        sdk.identityQueue.enqueue { blocked.fulfill(); await latch.wait() }
        await fulfillment(of: [blocked], timeout: 2)
        sdk.identify(userId: "A", userToken: token("A"))
        let loaded = Locked(false)
        sdk.storeKit.productsLoader = { _ in loaded.value = true; return [] }
        let purchase = Task { try await sdk.purchase("bet.midgame.monthly") }
        XCTAssertFalse(loaded.value)
        await latch.open()
        do { _ = try await purchase.value; XCTFail("fixture has no product") }
        catch CashSDKError.productNotFound { }
        XCTAssertTrue(loaded.value)
        let ready = try await sdk.waitUntilReady()
        XCTAssertEqual(ready.userId, "A")
        try await sdk.logoutAndWait()
    }

    func testRestoreWaitsAndReportsProviderFailure() async throws {
        let sdk = sdk()
        let latch = ReadinessLatch()
        sdk.identityQueue.enqueue { await latch.wait() }
        sdk.identify(userId: "A", userToken: token("A"))
        let synced = Locked(false)
        sdk.storeKit.syncHandler = { synced.value = true; throw CashSDKError.invalidResponse }
        let restore = Task { try await sdk.restore() }
        XCTAssertFalse(synced.value)
        await latch.open()
        do { _ = try await restore.value; XCTFail("provider error must not look like restore success") }
        catch CashSDKError.restoreVerificationFailed { }
        XCTAssertTrue(synced.value)
        try await sdk.logoutAndWait()
    }

    func testCapturedClientKeepsOriginalPairAcrossAccountSwitch() async throws {
        let sdk = sdk()
        let aToken = token("A")
        _ = try await sdk.identifyAndWait(userId: "A", userToken: aToken)
        let captured = try XCTUnwrap(sdk.apiClient())
        _ = try await sdk.identifyAndWait(userId: "B", userToken: token("B"))
        ReadinessProtocol.requests.value = []
        let response = try await captured.fetchEntitlements()
        XCTAssertEqual(response?.userId, "A")
        // The entitlements read, not whatever else went out since (a telemetry flush, say).
        let request = try XCTUnwrap(ReadinessProtocol.requests.value.last { $0.url?.path == "/v1/entitlements" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CashSDK-User-Id"), "A")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CashSDK-User-Token"), aToken)
        let ready = try await sdk.waitUntilReady()
        XCTAssertEqual(ready.userId, "B")
        try await sdk.logoutAndWait()
    }

    func testMissingExpiredAndMismatchedTokensRejectBeforeStoreKit() async throws {
        let sdk = sdk()
        let reachedStore = Locked(false)
        sdk.storeKit.productsLoader = { _ in reachedStore.value = true; return [] }
        for invalid in [nil, token("A", expires: 1), token("B"), "malformed"] as [String?] {
            sdk.identify(userId: "A", userToken: invalid)
            do { _ = try await sdk.purchase("bet.midgame.yearly"); XCTFail("invalid identity") }
            catch { XCTAssertFalse(reachedStore.value) }
        }
        try await sdk.logoutAndWait()
    }

    func testLateRefreshCannotOverwriteAToBToA() async throws {
        let sdk = sdk()
        _ = try await sdk.identifyAndWait(userId: "A", userToken: token("A"))
        let latch = ReadinessLatch()
        let requested = expectation(description: "refresh started")
        let refresh = Task { try await sdk.refreshUserToken { owner in requested.fulfill(); await latch.wait(); return token(owner) } }
        await fulfillment(of: [requested], timeout: 2)
        _ = try await sdk.identifyAndWait(userId: "B", userToken: token("B"))
        let current = try await sdk.identifyAndWait(userId: "A", userToken: token("A"))
        await latch.open()
        do { _ = try await refresh.value; XCTFail("old refresh must fail") }
        catch CashSDKError.identityChanged { }
        let ready = try await sdk.waitUntilReady()
        XCTAssertEqual(ready, current)
        try await sdk.logoutAndWait()
    }

    func testFailedRefreshRevokesReadinessAndLogoutClearsAccess() async throws {
        let sdk = sdk()
        _ = try await sdk.identifyAndWait(userId: "A", userToken: token("A"))
        do { _ = try await sdk.refreshUserToken { _ in throw CashSDKError.identityTokenExpired }; XCTFail() }
        catch CashSDKError.identityTokenExpired { }
        do { _ = try await sdk.waitUntilReady(); XCTFail() }
        catch CashSDKError.identityTokenExpired { }
        try await sdk.logoutAndWait()
        XCTAssertTrue(sdk.entitlements.isEmpty)
        do { _ = try await sdk.waitUntilReady(); XCTFail() }
        catch CashSDKError.notIdentified { }
    }

    func testRestartRequiresHostAuthenticationAndObserverCannotOwnTransactions() async throws {
        let sdk = sdk(observer: true)
        do { _ = try await sdk.waitUntilReady(); XCTFail() }
        catch CashSDKError.notIdentified { }
        _ = try await sdk.identifyAndWait(userId: "A", userToken: token("A"))
        do { _ = try await sdk.purchase("bet.midgame.weekly"); XCTFail() }
        catch CashSDKError.observerMode { }
        do { try await sdk.restore(); XCTFail() }
        catch CashSDKError.observerMode { }
        do { _ = try await sdk.spendConsumable("coins", units: 1, idempotencyKey: "fixture"); XCTFail() }
        catch CashSDKError.observerMode { }
        try await sdk.logoutAndWait()
    }

    func testPublishedSnapshotCarriesCurrentIdentityRevision() async throws {
        let sdk = sdk()
        let ready = try await sdk.identifyAndWait(userId: "A", userToken: token("A"))
        _ = try await sdk.refreshEntitlements()
        XCTAssertEqual(sdk.entitlements.userId, "A")
        XCTAssertEqual(sdk.entitlements.identityRevision, ready.revision)
        sdk.configure(with: CashSDKConfiguration(publishableKey: "csk_pk_other"))
        XCTAssertTrue(sdk.entitlements.isEmpty)
        do { _ = try await sdk.waitUntilReady(); XCTFail() }
        catch CashSDKError.notIdentified { }
        try await sdk.logoutAndWait()
    }

    func testExpiredCachedAccessCannotGrantPro() {
        let snapshot = Entitlements(entitlements: [Entitlement(identifier: "pro", name: "Pro", rank: 1, expiresAt: "2000-01-01T00:00:00Z")], tier: 1, tierIdentifier: "pro", userId: "A", version: 2)
        XCTAssertFalse(snapshot.isActive("pro"))
        XCTAssertTrue(snapshot.activeIdentifiers.isEmpty)
        XCTAssertEqual(snapshot.removingExpiredAccess().tier, 0)
        XCTAssertEqual(snapshot.gatingSnapshot().userId, "A")
        let legacy = Entitlements(entitlements: [Entitlement(identifier: "pro", name: "Pro")], tier: 1, tierIdentifier: "pro")
        XCTAssertEqual(legacy.removingExpiredAccess().tier, 1, "older snapshots without ranks keep the server tier")
    }
}
