import Foundation
import XCTest
@testable import CashSDKCommerce

private extension NSLock {
    /// NSLocking.withLock needs macOS 13; the package supports macOS 12.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// The checkout routes of the API: one checkout per customer and idempotency key.
private final class FakeAPI: @unchecked Sendable {
    private let lock = NSLock()
    var customerId = "alice"
    var environment = "sandbox"
    var owner: String?
    var initialStatus = "requires_action"
    var statuses: [String: String] = [:]
    var keys: [String: String] = [:]
    var posts: [String] = []
    var gets: [String] = []
    var deletes = 0
    var other: ((URLRequest) -> (Int, [String: String], String)?)?
    var refuse: ((String) -> (Int, [String: String], String)?)?
    var afterPost: ((String) -> Void)?
    var onPost: (() -> Void)?

    func set(_ id: String, _ status: String) { lock.locked { statuses[id] = status } }

    func checkout(_ id: String) -> String {
        let status = lock.locked { statuses[id] } ?? "pending"
        let payment = status == "complete" ? "\"paid\"" : "null"
        let action = status == "requires_action" ? #"{"type":"redirect","url":"https://checkout.stripe.com/c/pay/\#(id)"}"# : "null"
        return """
        {"id":"\(id)","provider":"stripe","environment":"sandbox","customerId":"\(owner ?? customerId)","mode":"subscription","productIdentifier":"price_monthly","status":"\(status)","paymentStatus":\(payment),"accessStatus":"check_entitlements","action":\(action),"expiresAt":null}
        """
    }

    func handle(_ request: URLRequest) -> (Int, [String: String], String) {
        if let answer = other?(request) { return answer }
        let path = request.url!.path
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/web/customer"):
            return (200, [:], #"{"customerId":"\#(customerId)","environment":"\#(environment)"}"#)
        case ("DELETE", "/v1/web/sessions/current"):
            lock.locked { deletes += 1 }
            return (200, [:], #"{"revoked":true}"#)
        case ("POST", "/v1/web/checkouts"):
            let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
            onPost?()
            lock.locked { posts.append(key) }
            if let refusal = refuse?(key) { return refusal }
            let id: String = lock.locked {
                if let id = keys["\(customerId):\(key)"] { return id }
                let id = "wco_\(keys.count + 1)"
                keys["\(customerId):\(key)"] = id
                statuses[id] = initialStatus
                return id
            }
            let body = checkout(id)
            afterPost?(id)
            return (201, [:], body)
        default:
            if path.hasPrefix("/v1/web/checkouts/") {
                let id = String(path.dropFirst("/v1/web/checkouts/".count))
                lock.locked { gets.append(id) }
                guard lock.locked({ statuses[id] }) != nil else {
                    return (404, [:], #"{"error":{"code":"checkout_not_found","message":"Checkout not found"}}"#)
                }
                return (200, [:], checkout(id))
            }
            return (500, [:], "{}")
        }
    }
}

private final class FakeProtocol: URLProtocol, @unchecked Sendable {
    static var api = FakeAPI()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = Self.api.handle(request)
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class MemoryStore: CommercePurchaseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failWrites = false
    var all: [String: String] { lock.locked { values } }
    func value(forKey key: String) -> String? { lock.locked { values[key] } }
    func set(_ value: String, forKey key: String) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        lock.locked { values[key] = value }
    }
    func remove(_ key: String) { _ = lock.locked { values.removeValue(forKey: key) } }
    func attempts() -> [[String: String]] {
        all.values.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.locked { count } }
    func next() -> Int { lock.locked { count += 1; return count } }
}

final class CommercePurchaseTests: XCTestCase {
    private let success = URL(string: "https://merchant.example/done")!
    private let cancel = URL(string: "https://merchant.example/plans")!
    private var store = MemoryStore()
    private var api: FakeAPI { FakeProtocol.api }

    override func setUp() {
        FakeProtocol.api = FakeAPI()
        store = MemoryStore()
    }

    private func client(customer: String = "alice", timeout: TimeInterval = 2,
                        provider: CashSDKCommerceClient.SessionProvider? = nil) throws -> CashSDKCommerceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeProtocol.self]
        return try CashSDKCommerceClient(
            publishableKey: "csk_pk_example", environment: .sandbox, customerId: customer,
            origin: "https://merchant.example", apiURL: URL(string: "https://api.example")!, timeout: timeout,
            configuration: configuration, purchaseStore: store,
            getSessionToken: provider ?? { CommerceSessionToken(token: "csk_ws_" + String(repeating: "x", count: 43)) })
    }
    private func code(_ work: () async throws -> Void) async -> String {
        do { try await work(); return "resolved" }
        catch let error as CommerceError { return error.code }
        catch { return String(describing: error) }
    }

    // MARK: Purchase helper

    func testPurchaseSavesItsKeyBeforeSendingAndItsCheckoutBeforeReturning() async throws {
        let c = try client()
        var seen: [[String: String]] = []
        let store = self.store
        api.onPost = { seen = store.attempts() }
        let checkout = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(checkout.status, .requiresAction)
        XCTAssertEqual(try checkout.redirectURL()?.absoluteString, "https://checkout.stripe.com/c/pay/wco_1")
        XCTAssertEqual(api.posts.count, 1)
        XCTAssertEqual(seen, [["key": api.posts[0]]], "the key was saved before it was sent")
        XCTAssertEqual(store.attempts(), [["key": api.posts[0], "id": "wco_1"]])
        XCTAssertTrue(store.all.keys.first!.contains("alice") && store.all.keys.first!.contains("pkg_monthly"))
        // Back from the browser without paying: the same checkout, no second one.
        let again = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(again.id, "wco_1")
        XCTAssertEqual(api.posts.count, 1)
        XCTAssertEqual(api.gets, ["wco_1"])
    }

    func testAnAttemptThatIsOverMakesRoomForTheNextPurchase() async throws {
        let c = try client()
        let first = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        api.set(first.id, "complete")
        let done = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(done.status, .complete)
        XCTAssertEqual(api.posts.count, 1, "a finished purchase never starts another by itself")
        XCTAssertTrue(store.all.isEmpty)
        let second = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(second.id, "wco_2")
        XCTAssertNotEqual(api.posts[1], api.posts[0], "the second purchase of a plan has its own key")
        // Expired or failed: nothing was charged, so the same call starts a new attempt.
        api.set("wco_2", "expired")
        let third = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(third.id, "wco_3")
        api.set("wco_3", "failed")
        let fourth = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(fourth.id, "wco_4")
        api.set("wco_4", "needs_review")
        let review = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(review.status, .needsReview)
        XCTAssertTrue(store.all.isEmpty)
        let fifth = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(fifth.id, "wco_5")
    }

    func testPendingIsAskedForAgainWithTheSameKey() async throws {
        let c = try client()
        api.initialStatus = "pending"
        let api = self.api
        api.afterPost = { id in if api.posts.count == 1 { api.set(id, "requires_action") } }
        let checkout = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(checkout.status, .requiresAction)
        XCTAssertEqual(api.posts.count, 2)
        XCTAssertEqual(api.posts[0], api.posts[1])
        XCTAssertEqual(store.attempts(), [["key": api.posts[0], "id": "wco_1"]])
    }

    func testRefusalsBecauseTheCustomerHasItEndTheAttemptAndABusyPlanKeepsIt() async throws {
        let c = try client()
        for refusal in ["already_subscribed", "already_owned", "already_purchased"] {
            api.refuse = { _ in (409, [:], #"{"error":{"code":"\#(refusal)","message":"No","retryable":false}}"#) }
            let failure = await code { _ = try await c.purchase("pkg_monthly", successURL: self.success, cancelURL: self.cancel) }
            XCTAssertEqual(failure, refusal)
            XCTAssertTrue(store.all.isEmpty, refusal)
        }
        XCTAssertEqual(Set(api.posts).count, 3)
        api.refuse = { _ in (503, ["Retry-After": "2"], #"{"error":{"code":"checkout_in_progress","message":"Busy","retryable":true}}"#) }
        do { _ = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel); XCTFail("busy") }
        catch let error as CommerceError {
            XCTAssertEqual(error.code, "checkout_in_progress")
            XCTAssertTrue(error.retryable)
            XCTAssertEqual(error.retryAfter, 2)
        }
        let kept = try XCTUnwrap(store.attempts().first?["key"])
        api.refuse = { _ in (0, [:], "") }
        let offline = await code { _ = try await c.purchase("pkg_monthly", successURL: self.success, cancelURL: self.cancel) }
        XCTAssertEqual(offline, "network_error")
        api.refuse = nil
        _ = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(Array(api.posts.suffix(3)), [kept, kept, kept], "a retry after an uncertain failure is the same purchase")
    }

    func testEachPackageHasItsOwnAttempt() async throws {
        let c = try client()
        api.refuse = { _ in self.api.posts.count == 1 ? (409, [:], #"{"error":{"code":"catalog_price_mismatch","message":"No"}}"#) : nil }
        let refused = await code { _ = try await c.purchase("pkg_monthly", successURL: self.success, cancelURL: self.cancel) }
        XCTAssertEqual(refused, "catalog_price_mismatch")
        let yearly = try await c.purchase("pkg_yearly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(yearly.status, .requiresAction, "a refused plan never blocks another one")
        XCTAssertNotEqual(api.posts[1], api.posts[0])
        _ = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        XCTAssertEqual(api.posts[2], api.posts[0], "the refused plan retries its own key")
        XCTAssertEqual(store.all.count, 2)
    }

    func testAStoreThatCannotSaveStopsThePurchaseBeforeAnythingIsSent() async throws {
        let c = try client()
        store.failWrites = true
        let failure = await code { _ = try await c.purchase("pkg_monthly", successURL: self.success, cancelURL: self.cancel) }
        XCTAssertEqual(failure, "storage_unavailable")
        XCTAssertTrue(api.posts.isEmpty)
    }

    func testGetPurchaseAndWaitForPurchaseClearTheAttemptOnceItIsOver() async throws {
        let c = try client()
        let none = try await c.getPurchase("pkg_monthly")
        XCTAssertNil(none)
        let started = try await c.purchase("pkg_monthly", successURL: success, cancelURL: cancel)
        let read = try await c.getPurchase("pkg_monthly")
        XCTAssertEqual(read?.status, .requiresAction)
        XCTAssertEqual(store.all.count, 1)
        let api = self.api
        Task { try await Task.sleep(nanoseconds: 300_000_000); api.set(started.id, "complete") }
        let done = try await c.waitForPurchase("pkg_monthly", timeout: 5)
        XCTAssertEqual(done?.status, .complete)
        XCTAssertTrue(store.all.isEmpty, "a finished purchase is forgotten")
        let gone = try await c.getPurchase("pkg_monthly")
        XCTAssertNil(gone)
    }

    func testPurchaseChecksItsInput() async throws {
        let c = try client()
        let empty = await code { _ = try await c.purchase("", successURL: self.success, cancelURL: self.cancel) }
        XCTAssertEqual(empty, "invalid_package")
        let elsewhere = await code { _ = try await c.purchase("pkg", successURL: URL(string: "https://evil.example/done")!, cancelURL: self.cancel) }
        XCTAssertEqual(elsewhere, "invalid_return_url")
        let input = CommerceCheckoutInput(packageId: "", successURL: success, cancelURL: cancel)
        let checkout = await code { _ = try await c.checkout(input, idempotencyKey: "stable_attempt_1234") }
        XCTAssertEqual(checkout, "invalid_package", "an empty package is not reported as a bad idempotency key")
        XCTAssertTrue(api.posts.isEmpty)
    }

    // MARK: Server contract

    func testACheckoutForAnotherCustomerIsNeverShownAndSignsOut() async throws {
        let c = try client()
        api.owner = "bob"
        let failure = await code { _ = try await c.purchase("pkg_monthly", successURL: self.success, cancelURL: self.cancel) }
        XCTAssertEqual(failure, "identity_changed")
        let after = await code { _ = try await c.getCustomer() }
        XCTAssertEqual(after, "signed_out")
    }

    func testAnUnknownCheckoutStatusReadsAsPendingAndIsWaitedOn() async throws {
        let c = try client()
        let reads = Counter()
        api.other = { request in
            guard request.url!.path == "/v1/web/checkouts/wco_9" else { return nil }
            let unknown = reads.next() < 3
            let status = unknown ? "processing_at_bank" : "complete"
            let payment = unknown ? "null" : "\"paid\""
            let action = unknown ? #"{"type":"redirect","url":"https://checkout.stripe.com/c/pay/x"}"# : "null"
            return (200, [:], #"{"id":"wco_9","provider":"stripe","environment":"sandbox","status":"\#(status)","paymentStatus":\#(payment),"accessStatus":"check_entitlements","action":\#(action),"expiresAt":null}"#)
        }
        let first = try await c.getCheckout("wco_9")
        XCTAssertEqual(first.status, .pending)
        XCTAssertNil(try first.redirectURL(), "nothing to open for a status this version does not know")
        XCTAssertFalse(first.settled)
        let done = try await c.waitForCheckout("wco_9", timeout: 10)
        XCTAssertEqual(done.status, .complete)
        XCTAssertTrue(done.settled)
    }

    func testEnvironmentMismatchIsNamedAndDoesNotSignOut() async throws {
        let c = try client()
        api.environment = "production"
        let failure = await code { _ = try await c.getCustomer() }
        XCTAssertEqual(failure, "environment_mismatch")
        api.environment = "sandbox"
        let customer = try await c.getCustomer()
        XCTAssertEqual(customer.customerId, "alice")
    }

    func testARefusedPublishableKeyNeverAsksForANewSession() async throws {
        for status in [401, 403] {
            let sessions = Counter()
            let c = try client(provider: {
                _ = sessions.next()
                return CommerceSessionToken(token: "csk_ws_" + String(repeating: "x", count: 43))
            })
            let requests = Counter()
            api.other = { _ in
                _ = requests.next()
                return (status, [:], #"{"error":{"code":"invalid_publishable_key","message":"Unknown key","retryable":false}}"#)
            }
            let failure = await code { _ = try await c.getCustomer() }
            XCTAssertEqual(failure, "invalid_publishable_key")
            XCTAssertEqual(sessions.value, 1, "\(status)")
            XCTAssertEqual(requests.value, 1, "\(status)")
        }
    }

    func testSessionLifetimeFollowsThisClock() throws {
        let now = Date()
        let ten = CashSDKCommerceClient.sessionExpiry(CommerceSessionToken(token: "t", expiresAt: "2000-01-01T00:00:00Z", expiresInSeconds: 600), receivedAt: now)
        XCTAssertEqual(ten, now.addingTimeInterval(600), "the relative lifetime wins over an absolute one")
        let behind = CashSDKCommerceClient.sessionExpiry(CommerceSessionToken(token: "t", expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))), receivedAt: now)
        XCTAssertEqual(behind, now.addingTimeInterval(60), "an expiry already past on this clock is used for a minute")
        let ahead = CashSDKCommerceClient.sessionExpiry(CommerceSessionToken(token: "t", expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(7200))), receivedAt: now)
        XCTAssertEqual(ahead, now.addingTimeInterval(600), "and never reused past the longest session")
        XCTAssertEqual(CashSDKCommerceClient.sessionExpiry(CommerceSessionToken(token: "t"), receivedAt: now), .distantFuture)
        XCTAssertNil(CashSDKCommerceClient.sessionExpiry(CommerceSessionToken(token: "t", expiresInSeconds: 0), receivedAt: now))
        XCTAssertNil(CashSDKCommerceClient.sessionExpiry(CommerceSessionToken(token: "t", expiresAt: "soon"), receivedAt: now))
    }

    func testASessionThatLooksExpiredOnThisClockStillWorks() async throws {
        let sessions = Counter()
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-900))
        let c = try client(provider: {
            _ = sessions.next()
            return CommerceSessionToken(token: "csk_ws_" + String(repeating: "x", count: 43), expiresAt: past)
        })
        _ = try await c.getCustomer()
        _ = try await c.getCustomer()
        XCTAssertEqual(sessions.value, 1, "used, and reused for a while, instead of refused")
    }

    func testAProxyErrorPageIsClassifiedByItsStatus() async throws {
        let c = try client()
        for (status, retryable) in [(502, true), (429, true), (404, false)] {
            api.other = { _ in (status, ["Content-Type": "text/html", "Retry-After": "Wed, 21 Oct 2099 07:28:00 GMT"], "<html>Bad gateway</html>") }
            do { _ = try await c.getCustomer(); XCTFail("refused") }
            catch let error as CommerceError {
                XCTAssertEqual(error.code, "http_\(status)")
                XCTAssertEqual(error.retryable, retryable)
                XCTAssertGreaterThan(error.retryAfter ?? 0, 1_000_000, "an HTTP date is read too")
            }
        }
    }

    // MARK: Waits and sign-out

    func testAWaitRetriesTransientFailuresUntilItsDeadline() async throws {
        let c = try client()
        let reads = Counter()
        api.other = { request in
            guard request.url!.path == "/v1/web/checkouts/wco_7" else { return nil }
            switch reads.next() {
            case 1: return (503, [:], #"{"error":{"code":"provider_request_failed","message":"Down"}}"#)
            case 2: return (429, ["Retry-After": "0"], "<html>Too many</html>")
            case 3: return (0, [:], "")
            default: return (200, [:], #"{"id":"wco_7","provider":"stripe","environment":"sandbox","status":"complete","paymentStatus":"paid","accessStatus":"check_entitlements","action":null,"expiresAt":null}"#)
            }
        }
        let started = Date()
        let done = try await c.waitForCheckout("wco_7", timeout: 20)
        XCTAssertTrue(done.settled)
        XCTAssertEqual(reads.value, 4, "a 503, a 429 page and a lost connection did not end the wait")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3, "at least a second between reads")
        // A refusal a retry cannot fix ends it at once.
        api.other = { _ in (404, [:], #"{"error":{"code":"checkout_not_found","message":"Not found"}}"#) }
        let missing = await code { _ = try await c.waitForCheckout("wco_7", timeout: 20) }
        XCTAssertEqual(missing, "checkout_not_found")
        // Down for the whole wait: the last failure, once the time is up.
        api.other = { _ in (503, [:], "{}") }
        let down = await code { _ = try await c.waitForEntitlement("pro", timeout: 1.5) }
        XCTAssertEqual(down, "http_503")
        for interval in [0.1, 0.5, 6] {
            let invalid = await code { _ = try await c.waitForCheckout("wco_7", timeout: 1, interval: interval) }
            XCTAssertEqual(invalid, "invalid_configuration")
        }
    }

    func testSignOutDuringAWaitEndsItAndARevocationFailureIsACommerceError() async throws {
        let c = try client()
        api.other = { request in
            request.url!.path == "/v1/web/customer" ? nil
                : request.httpMethod == "DELETE" ? (0, [:], "")
                : (200, [:], #"{"id":"wco_8","provider":"stripe","environment":"sandbox","status":"requires_action","paymentStatus":null,"accessStatus":"check_entitlements","action":{"type":"redirect","url":"https://pay.merchant.example/c/pay/wco_8"},"expiresAt":null}"#)
        }
        _ = try await c.getCustomer()
        let waiting = Task { try await c.waitForCheckout("wco_8", timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        do { try await c.logout(); XCTFail("revocation needs the network") }
        catch let error as CommerceError { XCTAssertEqual(error.code, "network_error") }
        catch { XCTFail("not a CommerceError: \(error)") }
        let ended = await code { _ = try await waiting.value }
        XCTAssertEqual(ended, "identity_changed")
        let access = await c.isActive("pro")
        XCTAssertFalse(access)
    }

    func testStripePagesOnACustomDomainAreAccepted() throws {
        XCTAssertEqual(try stripePageURL("https://pay.merchant.example/c/pay/cs_1#frag", page: .checkout).host, "pay.merchant.example")
        XCTAssertEqual(try stripePageURL("https://billing.merchant.example/p/session/x", page: .portal).host, "billing.merchant.example")
        XCTAssertEqual(try stripePageURL("https://CHECKOUT.stripe.com/anything", page: .checkout).host?.lowercased(), "checkout.stripe.com")
        for (url, page) in [
            ("https://pay.merchant.example/pay/cs_1", StripePage.checkout),
            ("https://pay.merchant.example/c/pay/../../steal", .checkout),
            ("http://pay.merchant.example/c/pay/cs_1", .checkout),
            ("https://pay.merchant.example:8443/c/pay/cs_1", .checkout),
            ("https://user:pass@pay.merchant.example/c/pay/cs_1", .checkout),
            ("https://127.0.0.1/c/pay/cs_1", .checkout),
            ("https://[::1]/c/pay/cs_1", .checkout),
            ("https://localhost/c/pay/cs_1", .checkout),
            ("https://billing.merchant.example/c/pay/x", .portal),
            ("https://checkout.stripe.com/c/pay/x", .portal),
        ] {
            XCTAssertThrowsError(try stripePageURL(url, page: page), url)
        }
    }
}
