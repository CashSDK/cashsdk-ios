import Foundation
import XCTest
@testable import CashSDK

private final class IdentityProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var delayedHandler: ((IdentityProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let delayedHandler = Self.delayedHandler { delayedHandler(self); return }
        guard let handler = Self.handler else { return }
        let (status, headers, data) = handler(request)
        respond(status: status, headers: headers, data: data)
    }
    func respond(status: Int, headers: [String: String], data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIClientIdentityTests: XCTestCase {
    func testInFlightResponseCannotSurviveLogoutAndSameAccountSignIn() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); IdentityProtocol.delayedHandler = nil }
        let api = APIClient(configuration: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: URL(string: "https://fixture.invalid")!), session: session)
        await api.setIdentity(userId: "A", userToken: "token-A")
        let started = expectation(description: "request started")
        var pending: IdentityProtocol?
        IdentityProtocol.delayedHandler = { request in pending = request; started.fulfill() }
        let request = Task { try await api.fetchEntitlements() }
        await fulfillment(of: [started], timeout: 2)
        await api.setIdentity(userId: nil, userToken: nil)
        await api.setIdentity(userId: "A", userToken: "token-A")
        pending?.respond(status: 200, headers: ["ETag": "stale-A"], data: Data(#"{"entitlements":[],"tier":0,"consumables":[]}"#.utf8))
        do {
            _ = try await request.value
            XCTFail("an old session must not deliver a snapshot to a new session")
        } catch CashSDKError.notIdentified {
            // Expected: the caller can fetch again using the new session.
        }
        let etag = await api.entitlementsETag()
        XCTAssertNil(etag, "a discarded response must not poison the ETag cache")
    }

    func testRequestsBypassURLCacheAndReplaceIdentityTogether() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); IdentityProtocol.handler = nil }
        let api = APIClient(configuration: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: URL(string: "https://fixture.invalid")!), session: session)
        await api.setIdentity(userId: "A", userToken: "token-A")
        IdentityProtocol.handler = { request in
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CashSDK-User-Id"), "A")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CashSDK-User-Token"), "token-A")
            return (200, ["ETag": "A-snapshot"], Data(#"{"entitlements":[],"tier":0,"consumables":[]}"#.utf8))
        }
        _ = try await api.fetchEntitlements()
        await api.setIdentity(userId: "B", userToken: "token-B")
        IdentityProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CashSDK-User-Id"), "B")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CashSDK-User-Token"), "token-B")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"), "B cannot revalidate A's snapshot")
            return (200, [:], Data(#"{"entitlements":[],"tier":0,"consumables":[]}"#.utf8))
        }
        _ = try await api.fetchEntitlements()
    }

    func testAutomaticRecoveryDoesNotTransferSharedStorePurchases() {
        let token = AppAccountToken.appAccountToken(for: "A")
        XCTAssertTrue(CashSDK.canAutomaticallySyncPurchase(userId: "A", accountToken: token))
        XCTAssertFalse(CashSDK.canAutomaticallySyncPurchase(userId: "B", accountToken: token))
        XCTAssertFalse(CashSDK.canAutomaticallySyncPurchase(userId: nil, accountToken: token))
        XCTAssertFalse(CashSDK.canAutomaticallySyncPurchase(userId: "A", accountToken: UUID()))
        // No token (offer code, promoted purchase, family-shared copy): reported with claim
        // `sync`, which the server uses only to credit a purchase nobody owns yet, never to
        // move one. Without this it waited for a manual restore.
        XCTAssertTrue(CashSDK.canAutomaticallySyncPurchase(userId: "A", accountToken: nil))
        XCTAssertFalse(CashSDK.canAutomaticallySyncPurchase(userId: nil, accountToken: nil))
    }
}
