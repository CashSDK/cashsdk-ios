import Foundation
import XCTest
@testable import CashSDK

/// A `429` used to be retried after 0.5s and 1s whatever the server asked for, which spends
/// the retries inside the rate-limit window. The server's `Retry-After` is now honoured, with
/// jitter, when it is short; a long one leaves the transaction for a later recovery pass.
final class RetryAfterTests: XCTestCase {

    func testRetryAfterHeaderParsing() throws {
        let now = Date()
        XCTAssertEqual(APIClient.retryAfter("7", now: now), 7)
        XCTAssertEqual(APIClient.retryAfter(" 0 ", now: now), 0)
        XCTAssertEqual(APIClient.retryAfter("-3", now: now), 0)
        XCTAssertNil(APIClient.retryAfter(nil, now: now))
        XCTAssertNil(APIClient.retryAfter("soon", now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = try XCTUnwrap(APIClient.retryAfter(formatter.string(from: now.addingTimeInterval(90)), now: now))
        XCTAssertEqual(future, 90, accuracy: 1)
        XCTAssertEqual(APIClient.retryAfter(formatter.string(from: now.addingTimeInterval(-90)), now: now), 0)
    }

    func testThrottledDelayNeverUndercutsRetryAfterAndStaysBounded() {
        XCTAssertEqual(CashSDK.throttledDelay(retryAfter: 10, backoff: 0.5, random: 0), 10)
        XCTAssertEqual(CashSDK.throttledDelay(retryAfter: 10, backoff: 0.5, random: 1), 11)
        XCTAssertEqual(CashSDK.throttledDelay(retryAfter: 0, backoff: 0.5, random: 1)!, 0.1, accuracy: 0.0001)
        XCTAssertEqual(CashSDK.throttledDelay(retryAfter: 30, backoff: 0.5, random: 1), 30, "at most 30s in flight")
        XCTAssertNil(CashSDK.throttledDelay(retryAfter: 31, backoff: 0.5, random: 0), "longer waits are left to a later pass")
        XCTAssertEqual(CashSDK.throttledDelay(retryAfter: nil, backoff: 2, random: 1), 3, "no header: jittered backoff")
    }

    func testRetryingWaitsOutAShortRetryAfter() async throws {
        let attempts = Locked(0)
        let slept = Locked<[TimeInterval]>([])
        let announced = Locked<[TimeInterval]>([])
        let value = try await CashSDK.retrying(
            random: { 0.5 },
            sleep: { seconds in slept.withValue { $0.append(seconds) } },
            onRetryAfter: { seconds in announced.withValue { $0.append(seconds) } }
        ) { () -> String in
            let attempt = attempts.withValue { $0 += 1; return $0 }
            if attempt == 1 {
                throw APIClient.Throttled(error: .server(status: 429, code: "rate_limited", message: nil), retryAfter: 4)
            }
            return "verified"
        }
        XCTAssertEqual(value, "verified")
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(announced.value, [4])
        XCTAssertEqual(slept.value.count, 1)
        XCTAssertGreaterThanOrEqual(slept.value[0], 4)
        XCTAssertLessThanOrEqual(slept.value[0], 30)
    }

    func testRetryingGivesUpAtOnceOnALongRetryAfter() async {
        let attempts = Locked(0)
        let slept = Locked<[TimeInterval]>([])
        do {
            _ = try await CashSDK.retrying(sleep: { seconds in slept.withValue { $0.append(seconds) } }) { () -> String in
                attempts.withValue { $0 += 1 }
                throw APIClient.Throttled(error: .server(status: 429, code: "rate_limited", message: nil), retryAfter: 120)
            }
            XCTFail("throttled")
        } catch CashSDKError.server(let status, let code, _) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(code, "rate_limited")
        } catch {
            XCTFail("the internal throttle wrapper must not escape: \(error)")
        }
        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(slept.value.isEmpty)
    }

    func testVerifyCarriesRetryAfterOnThrottle() async throws {
        let server = StubServer { _ in
            StubServer.Response(status: 429, headers: ["Retry-After": "12"],
                                body: json(["error": ["code": "rate_limited", "message": "too many requests"]]))
        }
        let api = APIClient(configuration: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: server.baseURL), session: server.session())
        do {
            _ = try await api.verify(signedTransaction: "jws", claim: .sync)
            XCTFail("throttled")
        } catch let throttled as APIClient.Throttled {
            XCTAssertEqual(throttled.retryAfter, 12)
            guard case .server(429, "rate_limited"?, _) = throttled.error else { return XCTFail("\(throttled.error)") }
        }
    }

    func testPurchaseWaitsOutAShortRetryAfter() async throws {
        let finishes = FinishLog()
        let calls = Locked(0)
        let server = StubServer { request in
            guard request.path == "/v1/transactions:verify" else { return StubServer.Response(status: 202) }
            let call = calls.withValue { $0 += 1; return $0 }
            return call == 1 ? StubServer.Response(status: 429, headers: ["Retry-After": "3"]) : Fixture.verified(user: "A")
        }
        let sdk = makeSDK(server)
        let slept = Locked<[TimeInterval]>([])
        sdk.retrySleep.value = { seconds in slept.withValue { $0.append(seconds) } }
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        sdk.storeKit.purchaseHandler = { _, token in .verified(fixtureTransaction("bought", token: token, finishes: finishes)) }

        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(server.verifies.count, 2)
        XCTAssertEqual(slept.value.count, 1)
        XCTAssertGreaterThanOrEqual(slept.value[0], 3)
        XCTAssertEqual(finishes.finished, ["bought"])
    }

    func testLongRetryAfterLeavesThePurchaseForALaterPass() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify"
                ? StubServer.Response(status: 429, headers: ["Retry-After": "120"])
                : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let bought = fixtureTransaction("bought", token: AppAccountToken.appAccountToken(for: "A"), finishes: finishes)
        sdk.storeKit.purchaseHandler = { _, _ in .verified(bought) }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("throttled")
        } catch CashSDKError.chargedButUnverified {}
        XCTAssertEqual(server.verifies.count, 1, "no in-flight wait for two minutes")

        // Automatic recovery respects the pause instead of spending requests inside it.
        sdk.storeKit.currentEntitlementsLoader = { [] }
        sdk.storeKit.unfinishedLoader = { [bought] }
        await sdk.launchBackstop()
        await sdk.handleUpdatedTransaction(bought)
        XCTAssertEqual(server.verifies.count, 1)
        XCTAssertTrue(finishes.finished.isEmpty, "still unfinished, still recoverable")
    }
}

/// A verify that meets a network which accepts the connection and then goes quiet must give up
/// in seconds, not minutes. `URLSession.shared` waits 60 seconds per request and 7 days for the
/// resource, and with three retry attempts that is a three-minute spinner after the money was
/// taken. Android has always used 15s/20s.
final class RequestTimeoutTests: XCTestCase {

    func testTheDefaultSessionIsNotTheSharedOne() {
        XCTAssertFalse(APIClient.defaultSession() === URLSession.shared)
    }

    func testTheDefaultSessionBoundsARequestAndTheWholeResource() {
        let configuration = APIClient.defaultSession().configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, APIClient.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, APIClient.resourceTimeout)
        XCTAssertEqual(APIClient.requestTimeout, 15)
        XCTAssertEqual(APIClient.resourceTimeout, 60)
    }

    /// Three attempts at the request timeout is the worst case a caller can wait, and it has to
    /// stay well under the minute a person will give a payment before assuming it failed.
    func testTheWorstCaseVerifyStaysUnderAMinute() {
        XCTAssertLessThan(APIClient.requestTimeout * 3, 60)
    }

    func testAVerifyIsNeverAnsweredFromTheUrlCache() {
        let configuration = APIClient.defaultSession().configuration
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
    }
}
