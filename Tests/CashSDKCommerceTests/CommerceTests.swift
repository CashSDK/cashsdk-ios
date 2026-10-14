import XCTest
@testable import CashSDKCommerce
import Foundation

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) throws -> (Int, [String: String], String) = { _ in (500, [:], "{}") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class CommerceTests: XCTestCase {
    private func client(provider: @escaping CashSDKCommerceClient.SessionProvider = { CommerceSessionToken(token: "csk_ws_" + String(repeating: "x", count: 43)) }) throws -> CashSDKCommerceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return try CashSDKCommerceClient(publishableKey: "csk_pk_example", environment: .sandbox, customerId: "alice",
                                        origin: "https://merchant.example", apiURL: URL(string: "https://api.example")!, timeout: 0.2,
                                        configuration: configuration, getSessionToken: provider)
    }
    private func access(active: Bool = true, customer: String = "alice", expiry: String? = nil, revision: Int = 1) -> String {
        let expires = expiry.map { "\"\($0)\"" } ?? "null"
        return """
        {"customerId":"\(customer)","environment":"sandbox","revision":\(revision),"computedAt":"2026-10-14T10:00:00.000Z","entitlements":[{"identifier":"pro","name":"Pro","active":\(active),"rank":1,"source":"stripe","expiresAt":\(expires)}]}
        """
    }

    func testReadsUseSessionAndOriginAndExactRoutes() async throws {
        let c = try client()
        MockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer csk_pk_example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://merchant.example")
            XCTAssertTrue(request.value(forHTTPHeaderField: "X-CashSDK-Web-Session")!.hasPrefix("csk_ws_"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            switch request.url!.path {
            case "/v1/web/customer": return (200, [:], #"{"customerId":"alice","environment":"sandbox"}"#)
            case "/v1/web/offerings": return (200, [:], #"{"current":null}"#)
            case "/v1/web/subscriptions": return (200, [:], #"{"customerId":"alice","environment":"sandbox","subscriptions":[]}"#)
            case "/v1/web/sessions/current": XCTAssertEqual(request.httpMethod, "DELETE"); return (200, [:], #"{"revoked":true}"#)
            default: XCTFail("Unexpected route"); return (500, [:], "{}")
            }
        }
        _ = try await c.getCustomer()
        _ = try await c.getOfferings()
        _ = try await c.getSubscriptions()
        try await c.logout()
        do { _ = try await c.getCustomer(); XCTFail("signed out") }
        catch { XCTAssertEqual((error as? CommerceError)?.code, "signed_out") }
    }

    func testExpiryRefundAndRevisionResetRemoveLocalAccess() async throws {
        let c = try client()
        MockProtocol.handler = { _ in (200, [:], self.access(revision: 10)) }
        _ = try await c.getEntitlements()
        let granted = await c.isActive("pro")
        XCTAssertTrue(granted)
        MockProtocol.handler = { _ in (200, [:], self.access(active: false, revision: 1)) }
        _ = try await c.getEntitlements()
        let revoked = await c.isActive("pro")
        XCTAssertFalse(revoked)
        MockProtocol.handler = { _ in (200, [:], self.access(expiry: "2000-01-01T00:00:00Z")) }
        let snapshot = try await c.getEntitlements()
        XCTAssertFalse(snapshot.isActive("pro"))
    }

    func testAnotherCustomerNeverEntersCache() async throws {
        let c = try client()
        MockProtocol.handler = { _ in (200, [:], self.access()) }
        _ = try await c.getEntitlements()
        MockProtocol.handler = { _ in (200, [:], self.access(customer: "bob")) }
        do { _ = try await c.getEntitlements(); XCTFail("wrong customer") }
        catch { XCTAssertEqual((error as? CommerceError)?.code, "identity_changed") }
        let granted = await c.isActive("pro")
        XCTAssertFalse(granted)
    }

    func testCheckoutPreservesKeyAndNeverRetriesUncertainWrite() async throws {
        let c = try client()
        var calls = 0
        MockProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url!.path, "/v1/web/checkouts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable_attempt_1234")
            return (503, ["Retry-After": "3", "X-Request-Id": "request-1"], #"{"error":{"code":"checkout_uncertain","message":"Retry the same key","retryable":true}}"#)
        }
        let input = CommerceCheckoutInput(packageId: "monthly", successURL: URL(string: "https://merchant.example/done")!, cancelURL: URL(string: "https://merchant.example/cancel")!)
        do { _ = try await c.checkout(input, idempotencyKey: "stable_attempt_1234"); XCTFail("uncertain") }
        catch {
            let failure = try XCTUnwrap(error as? CommerceError)
            XCTAssertEqual(failure.code, "checkout_uncertain")
            XCTAssertEqual(failure.retryAfter, 3)
            XCTAssertEqual(failure.requestId, "request-1")
        }
        XCTAssertEqual(calls, 1)
    }

    func testRejectedSessionRefreshesOnce() async throws {
        let c = try client()
        var calls = 0
        MockProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (401, [:], "{}") : (200, [:], #"{"customerId":"alice","environment":"sandbox"}"#)
        }
        _ = try await c.getCustomer()
        XCTAssertEqual(calls, 2)
    }

    func testNoAccessAfterSignOutEvenWhenRevocationFails() async throws {
        let c = try client()
        MockProtocol.handler = { _ in (200, [:], self.access()) }
        _ = try await c.getEntitlements()
        MockProtocol.handler = { _ in (503, [:], "{}") }
        do { try await c.logout(); XCTFail("revoke should fail") } catch { }
        let granted = await c.isActive("pro")
        XCTAssertFalse(granted)
    }

    func testTokenProviderTimeoutAndLogoutDuringAuthentication() async throws {
        let c = try client(provider: {
            // Deliberately ignores cancellation.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return CommerceSessionToken(token: "csk_ws_" + String(repeating: "x", count: 43))
        })
        let started = Date()
        do { _ = try await c.getCustomer(); XCTFail("timeout") }
        catch { XCTAssertEqual((error as? CommerceError)?.code, "timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        try await c.logout()
    }

    func testLogoutDuringAuthenticationCannotRestoreAccess() async throws {
        let c = try client(provider: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return CommerceSessionToken(token: "csk_ws_" + String(repeating: "x", count: 43))
        })
        let pending = Task { try await c.getCustomer() }
        try await Task.sleep(nanoseconds: 20_000_000)
        try await c.logout()
        do { _ = try await pending.value; XCTFail("Old account returned after sign-out") } catch { }
        let access = await c.isActive("pro")
        XCTAssertFalse(access)
        do { _ = try await c.getCustomer(); XCTFail("Signed out client reauthenticated") }
        catch { XCTAssertEqual((error as? CommerceError)?.code, "signed_out") }
    }

    func testConfigurationAndRedirectValidation() throws {
        for origin in ["http://merchant.example", "https://merchant.example/", "https://user:pass@merchant.example", "file:///", "https://merchant.example/path"] {
            XCTAssertThrowsError(try CashSDKCommerceClient(publishableKey: "csk_pk_example", environment: .production, customerId: "alice", origin: origin, getSessionToken: { CommerceSessionToken(token: "") }))
        }
        for url in ["https://checkout.stripe.com.evil.example/", "https://user@checkout.stripe.com/", "javascript:alert(1)", "https://checkout.stripe.com:444/"] {
            XCTAssertThrowsError(try stripePageURL(url, page: .checkout))
        }
        XCTAssertEqual(try stripePageURL("https://checkout.stripe.com/c/pay/test", page: .checkout).host, "checkout.stripe.com")
    }
}
