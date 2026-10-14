import Foundation
import XCTest
@testable import CashSDK

/// A token that expired while the App Store sheet was open made the verify 401 after the charge,
/// which surfaced as `chargedButUnverified`. With a `userTokenProvider`, a purchase renews any
/// token with less than five minutes left, and a token the server rejects is renewed and the
/// verify retried. Without one, a token with at least a minute left is still accepted, as hosts
/// on `1.2.0-rc.1` rely on.
final class TokenRenewalTests: XCTestCase {

    private func purchasingSDK(_ server: StubServer, token: String, finishes: FinishLog) async throws -> (CashSDK, IdentityReadiness) {
        let sdk = makeSDK(server)
        let ready = try await sdk.identifyAndWait(userId: "A", userToken: token)
        sdk.storeKit.purchaseHandler = { _, accountToken in
            .verified(fixtureTransaction("bought", token: accountToken, finishes: finishes))
        }
        return (sdk, ready)
    }

    func testMinimumLifetimeIsCheckedLocally() throws {
        let shortLived = fixtureToken("A", expiresIn: 120)
        XCTAssertNoThrow(try validateIdentityToken(shortLived, userId: "A"))
        XCTAssertThrowsError(try validateIdentityToken(shortLived, userId: "A", minimumLifetime: CashSDK.minimumTokenLifetimeForPurchase)) { error in
            guard case CashSDKError.identityTokenExpired = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try validateIdentityToken(fixtureToken("A"), userId: "A", minimumLifetime: CashSDK.minimumTokenLifetimeForPurchase))
    }

    func testWithoutAProviderATokenUnderAMinuteStopsThePurchaseBeforeTheSheet() async throws {
        let finishes = FinishLog()
        let sheets = Locked(0)
        let server = StubServer()
        let (sdk, _) = try await purchasingSDK(server, token: fixtureToken("A", expiresIn: 30), finishes: finishes)
        sdk.storeKit.purchaseHandler = { _, _ in sheets.withValue { $0 += 1 }; return .userCancelled }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("thirty seconds cannot outlast a payment sheet")
        } catch CashSDKError.identityTokenExpired {}
        XCTAssertEqual(sheets.value, 0, "no App Store sheet, so no charge")
        let feedback = try XCTUnwrap(PaywallFeedback.failure(CashSDKError.identityTokenExpired, restoring: false))
        XCTAssertFalse(feedback.message.contains("Payment may have completed"))
    }

    func testWithoutAProviderAPurchaseGoesAheadWithAMinuteLeft() async throws {
        // A host that reuses a token while it has more than a minute left, and sets no provider.
        let finishes = FinishLog()
        let token = fixtureToken("A", expiresIn: 120)
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let (sdk, _) = try await purchasingSDK(server, token: token, finishes: finishes)
        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(server.verifies.first?.header("X-CashSDK-User-Token"), token)
        XCTAssertEqual(finishes.finished, ["bought"])
    }

    func testProvidedTokenNeverRunsThePurchaseAsAnotherAccount() async throws {
        let finishes = FinishLog()
        let sheets = Locked(0)
        let sdk = makeSDK(StubServer())
        sdk.storeKit.purchaseHandler = { _, _ in sheets.withValue { $0 += 1 }; return .userCancelled }
        sdk.identify(userId: "A", userToken: fixtureToken("A", expiresIn: -60))
        // B signs in while A's replacement token is being fetched.
        sdk.userTokenProvider = { [weak sdk] _ in
            sdk?.identify(userId: "B", userToken: fixtureToken("B"))
            return fixtureToken("A")
        }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("A's purchase must not run as B")
        } catch CashSDKError.identityChanged {}
        XCTAssertEqual(sheets.value, 0)
        XCTAssertTrue(finishes.finished.isEmpty)
    }

    func testProviderFailureBeforeTheSheetIsAnExpiredToken() async throws {
        struct BackendDown: Error {}
        let finishes = FinishLog()
        let sheets = Locked(0)
        let (sdk, _) = try await purchasingSDK(StubServer(), token: fixtureToken("A", expiresIn: 30), finishes: finishes)
        sdk.storeKit.purchaseHandler = { _, _ in sheets.withValue { $0 += 1 }; return .userCancelled }
        sdk.userTokenProvider = { _ in throw BackendDown() }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("no usable token")
        } catch CashSDKError.identityTokenExpired {
            // Not the host's error: a paywall must not read it as a possible charge.
        }
        XCTAssertEqual(sheets.value, 0)
    }

    func testProviderFailureFallsBackToATokenWithAMinuteLeft() async throws {
        // The same token goes ahead without a provider; setting one must not refuse it.
        struct BackendDown: Error {}
        let finishes = FinishLog()
        let token = fixtureToken("A", expiresIn: 120)
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let (sdk, _) = try await purchasingSDK(server, token: token, finishes: finishes)
        let asked = Locked(0)
        sdk.userTokenProvider = { _ in asked.withValue { $0 += 1 }; throw BackendDown() }
        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(asked.value, 1)
        XCTAssertEqual(server.verifies.first?.header("X-CashSDK-User-Token"), token)
    }

    func testTokenFloorHoldsUntilTheSheetOpens() async throws {
        let finishes = FinishLog()
        let sheets = Locked(0)
        // Just over a minute left when the purchase starts; the product lookup then takes time.
        let (sdk, _) = try await purchasingSDK(StubServer(), token: fixtureToken("A", expiresIn: 61), finishes: finishes)
        sdk.storeKit.purchaseLookupHandler = { _ in try await Task.sleep(nanoseconds: 1_500_000_000) }
        sdk.storeKit.purchaseHandler = { _, _ in sheets.withValue { $0 += 1 }; return .userCancelled }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("under a minute left as the sheet would open")
        } catch CashSDKError.identityTokenExpired {}
        XCTAssertEqual(sheets.value, 0)
    }

    func testProviderRenewsAShortLivedTokenWithoutANewRevision() async throws {
        let finishes = FinishLog()
        let fresh = fixtureToken("A")
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let (sdk, ready) = try await purchasingSDK(server, token: fixtureToken("A", expiresIn: 120), finishes: finishes)
        let asked = Locked<[String]>([])
        sdk.userTokenProvider = { userId in asked.withValue { $0.append(userId) }; return fresh }

        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success(let access) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(asked.value, ["A"])
        XCTAssertEqual(server.verifies.first?.header("X-CashSDK-User-Token"), fresh)
        XCTAssertEqual(access.identityRevision, ready.revision, "a host comparing revisions must still accept this purchase")
        let after = try await sdk.waitUntilReady()
        XCTAssertEqual(after, ready)
    }

    func testRejectedTokenIsRenewedAndTheVerifyRetriedOnce() async throws {
        let finishes = FinishLog()
        let stale = fixtureToken("A")
        let fresh = fixtureToken("A", expiresIn: 7200)
        let server = StubServer { request in
            guard request.path == "/v1/transactions:verify" else { return StubServer.Response(status: 202) }
            if request.header("X-CashSDK-User-Token") == stale {
                return StubServer.Response(status: 401, body: json(["error": "invalid_user_token"]))
            }
            return Fixture.verified(user: "A")
        }
        let (sdk, _) = try await purchasingSDK(server, token: stale, finishes: finishes)
        let calls = Locked(0)
        sdk.userTokenProvider = { _ in calls.withValue { $0 += 1 }; return fresh }

        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(server.verifies.map { $0.header("X-CashSDK-User-Token") }, [stale, fresh])
        XCTAssertTrue(server.verifies.allSatisfy { $0.header("X-CashSDK-Claim") == "purchase" })
        XCTAssertEqual(finishes.finished, ["bought"])
    }

    func testStillRejectedAfterRenewalLeavesTheTransactionUnfinished() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify"
                ? StubServer.Response(status: 401, body: json(["error": "invalid_user_token"]))
                : StubServer.Response(status: 202)
        }
        let (sdk, _) = try await purchasingSDK(server, token: fixtureToken("A"), finishes: finishes)
        let calls = Locked(0)
        sdk.userTokenProvider = { _ in calls.withValue { $0 += 1 }; return fixtureToken("A") }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("the server never accepted a token")
        } catch CashSDKError.chargedButUnverified {}
        XCTAssertEqual(calls.value, 1, "one renewal, one retry")
        XCTAssertEqual(server.verifies.count, 2)
        XCTAssertTrue(finishes.finished.isEmpty, "recovered later, never finished without the server")
    }

    func testWithoutAProviderARejectedTokenLeavesTheTransactionUnfinished() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify"
                ? StubServer.Response(status: 401, body: json(["error": "invalid_user_token"]))
                : StubServer.Response(status: 202)
        }
        let (sdk, _) = try await purchasingSDK(server, token: fixtureToken("A"), finishes: finishes)
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("rejected")
        } catch CashSDKError.chargedButUnverified(_, let underlying) {
            XCTAssertTrue(CashSDK.isRejectedUserToken(underlying))
        }
        XCTAssertEqual(server.verifies.count, 1, "a 4xx is not retried")
        XCTAssertTrue(finishes.finished.isEmpty)
    }

    func testProviderReplacesATokenThatExpiredBeforeIdentify() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        sdk.userTokenProvider = { userId in fixtureToken(userId) }
        sdk.storeKit.purchaseHandler = { _, token in .verified(fixtureTransaction("bought", token: token, finishes: finishes)) }
        sdk.identify(userId: "A", userToken: fixtureToken("A", expiresIn: -60))
        do {
            _ = try await sdk.waitUntilReady()
            XCTFail("an expired token installs no session")
        } catch CashSDKError.identityTokenExpired {}

        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(finishes.finished, ["bought"])
    }
}
