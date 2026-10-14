import Foundation
import XCTest

/// What the SDK reports on the platform the tests run on: `macos` on a Mac host (and Mac
/// Catalyst), `ios` on iPhone and iPad. The server redeems both through Apple's offer codes.
private var expectedPlatform: String {
    #if os(macOS) || targetEnvironment(macCatalyst)
    return "macos"
    #else
    return "ios"
    #endif
}
@testable import CashSDK

/// Coupon validation and redemption against a stubbed API, in the shapes of
/// `AGENTS/COUPONS.md` (the contract the server builds against).
final class CouponTests: XCTestCase {
    private let tokenA = AppAccountToken.appAccountToken(for: "A")!
    private let redeemURL = "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SPRING"

    private static let validBody: [String: Any] = [
        "valid": true,
        "coupon": [
            "code": "SPRING", "name": "Spring sale", "kind": "amount_off", "percentOff": NSNull(),
            "amountOffMinor": 499, "currency": "USD", "duration": "P1M", "periodCount": 3,
        ],
        "products": [
            ["productIdentifier": "app.pro.monthly",
             "ios": ["appleCode": "SPRING", "redeemUrl": "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SPRING"]],
            ["productIdentifier": "app.pro.android.only", "android": ["basePlanId": "monthly", "offerId": "cpn-abc"]],
        ],
    ]

    private func body(_ request: RecordedRequest) -> [String: Any] {
        guard let data = request.body, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func couponServer(
        validate: @escaping @Sendable (RecordedRequest) -> StubServer.Response = { _ in StubServer.Response(status: 200, body: json(CouponTests.validBody)) },
        redeem: @escaping @Sendable (RecordedRequest) -> StubServer.Response = { _ in
            StubServer.Response(status: 200, body: json(["redemptionId": "red_1", "ios": ["appleCode": "SPRING", "redeemUrl": "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SPRING"]]))
        }
    ) -> StubServer {
        StubServer { request in
            switch request.path {
            case "/v1/coupons:validate": return validate(request)
            case "/v1/coupons:redeem": return redeem(request)
            case "/v1/transactions:verify": return Fixture.verified(user: "A")
            default: return StubServer.Response(status: 202)
            }
        }
    }

    private func signedIn(_ server: StubServer, opened: Locked<[URL]> = Locked([]), opens: Bool = true) async throws -> CashSDK {
        let sdk = makeSDK(server)
        sdk.couponURLOpener.value = { url in opened.withValue { $0.append(url) }; return opens }
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        return sdk
    }

    private func offerCodeTransaction(
        _ id: String,
        finishes: FinishLog,
        productId: String = "app.pro.monthly",
        token: UUID? = nil,
        purchaseDate: Date = Date(),
        renewal: Bool? = false
    ) -> StoreTransaction {
        var transaction = fixtureTransaction(id, token: token, finishes: finishes, productId: productId,
                                             purchaseDate: purchaseDate, originalId: renewal == true ? "chain-\(id)" : nil, renewal: renewal)
        transaction.offerType = StoreTransaction.offerCodeType
        transaction.offerIdentifier = "cashsdk-cpn-cpn_1-\(productId)"
        return transaction
    }

    // MARK: - Validate

    func testValidateSendsTheContractBodyAndDecodesTheCoupon() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server)
        let validation = try await sdk.validateCoupon("  spring \n")

        let sent = try XCTUnwrap(server.requests.first { $0.path == "/v1/coupons:validate" })
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(body(sent)["code"] as? String, "SPRING")
        XCTAssertEqual(body(sent)["appUserId"] as? String, "A")
        XCTAssertEqual(body(sent)["platform"] as? String, expectedPlatform)
        XCTAssertEqual(sent.header("Authorization"), "Bearer csk_pk_fixture")

        XCTAssertTrue(validation.valid)
        XCTAssertNil(validation.reason)
        let coupon = try XCTUnwrap(validation.coupon)
        XCTAssertEqual(coupon.kind, .amountOff)
        XCTAssertEqual(coupon.amountOffMinor, 499)
        XCTAssertEqual(coupon.amountOff, Decimal(string: "4.99"))
        XCTAssertEqual(coupon.duration, "P1M")
        XCTAssertEqual(coupon.periodCount, 3)
        XCTAssertNil(coupon.percentOff)
        // Only products with an iOS offer can be redeemed here.
        XCTAssertEqual(validation.eligibleProductIds, ["app.pro.monthly"])
        XCTAssertEqual(validation.products.first?.appleCode, "SPRING")
        XCTAssertEqual(validation.products.first?.redeemURL?.absoluteString, redeemURL)
    }

    func testEveryReasonCodeDecodes() async throws {
        let wire = [
            "not_found": CouponInvalidReason.notFound, "not_started": .notStarted, "expired": .expired,
            "disabled": .disabled, "exhausted": .exhausted, "already_redeemed": .alreadyRedeemed,
            "not_eligible": .notEligible, "not_available_on_platform": .notAvailableOnPlatform,
            "not_ready": .notReady, "base_plan_required": .basePlanRequired,
            "brand_new_reason": .unknown("brand_new_reason"),
        ]
        XCTAssertEqual(Set(CouponInvalidReason.known), Set(wire.values.filter { if case .unknown = $0 { return false }; return true }))
        XCTAssertEqual(CouponInvalidReason.known.count, 10)
        for (value, expected) in wire {
            let server = couponServer(validate: { _ in StubServer.Response(status: 200, body: json(["valid": false, "reason": value])) })
            let sdk = try await signedIn(server)
            let validation = try await sdk.validateCoupon("SPRING")
            XCTAssertFalse(validation.valid, value)
            XCTAssertEqual(validation.reason, expected, value)
            XCTAssertEqual(validation.reason?.rawValue, value)
            XCTAssertNil(validation.coupon)
            XCTAssertTrue(validation.products.isEmpty)
            XCTAssertFalse(CouponError.rejected(expected).localizedDescription.isEmpty)
        }
    }

    func testARefusalSentAsAnErrorStatusIsStillARefusal() async throws {
        let server = couponServer(validate: { _ in StubServer.Response(status: 404, body: json(["error": ["code": "coupon_not_found", "message": "no such code"]])) })
        let sdk = try await signedIn(server)
        let validation = try await sdk.validateCoupon("NOPE")
        XCTAssertEqual(validation.reason, .notFound)

        // Any other error stays a server error.
        server.respond { _ in StubServer.Response(status: 400, body: json(["error": "invalid_body"])) }
        do {
            _ = try await sdk.validateCoupon("NOPE")
            XCTFail("a 400 without a coupon reason is an error")
        } catch CashSDKError.server(let status, let code, _) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, "invalid_body")
        }
    }

    func testThrottledValidateWaitsOutRetryAfterThenGivesUp() async throws {
        let attempts = Locked(0)
        let server = couponServer(validate: { _ in
            attempts.withValue { $0 += 1 }
            return StubServer.Response(status: 429, headers: ["Retry-After": "2"], body: json(["error": ["code": "rate_limited"]]))
        })
        let sdk = try await signedIn(server)
        let slept = Locked<[TimeInterval]>([])
        sdk.retrySleep.value = { seconds in slept.withValue { $0.append(seconds) } }
        do {
            _ = try await sdk.validateCoupon("SPRING")
            XCTFail("throttled every time")
        } catch CashSDKError.server(let status, let code, _) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(code, "rate_limited")
        }
        XCTAssertEqual(attempts.value, 3)
        XCTAssertTrue(slept.value.allSatisfy { $0 >= 2 }, "never sooner than Retry-After: \(slept.value)")
    }

    // MARK: - Guests

    func testGuestsAreRefusedBeforeAnythingIsSent() async throws {
        let server = couponServer()
        let sdk = makeSDK(server)
        do {
            _ = try await sdk.validateCoupon("SPRING")
            XCTFail("a guest cannot validate")
        } catch CashSDKError.notIdentified {}
        do {
            _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
            XCTFail("a guest cannot redeem")
        } catch CashSDKError.notIdentified {}
        do {
            _ = try await sdk.awaitCouponCompletion(redemptionId: "red_1", timeout: 0)
            XCTFail("a guest has nothing to wait for")
        } catch CashSDKError.notIdentified {}
        XCTAssertTrue(server.requests.filter { $0.path.hasPrefix("/v1/coupons") }.isEmpty)

        // Signed out after signing in: refused again.
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        try await sdk.logoutAndWait()
        do {
            _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
            XCTFail("signed out")
        } catch CashSDKError.notIdentified {}
    }

    // MARK: - Redeem

    func testRedeemReservesOpensTheAppStoreAndCompletesOnTheOfferCodePurchase() async throws {
        let opened = Locked<[URL]>([])
        let server = couponServer()
        let sdk = try await signedIn(server, opened: opened)

        let result = try await sdk.redeemCoupon("spring", productId: "app.pro.monthly")
        XCTAssertEqual(result, .openedAppStore(redemptionId: "red_1", redeemURL: URL(string: redeemURL)!))
        XCTAssertEqual(result.redemptionId, "red_1")
        XCTAssertEqual(opened.value, [URL(string: redeemURL)!])

        let sent = try XCTUnwrap(server.requests.first { $0.path == "/v1/coupons:redeem" })
        XCTAssertEqual(body(sent)["code"] as? String, "SPRING")
        XCTAssertEqual(body(sent)["appUserId"] as? String, "A")
        XCTAssertEqual(body(sent)["platform"] as? String, expectedPlatform)
        XCTAssertEqual(body(sent)["productIdentifier"] as? String, "app.pro.monthly")

        // The App Store purchase arrives through `Transaction.updates` with no app account token.
        let waiting = Task { try await sdk.awaitCouponCompletion(redemptionId: "red_1", timeout: 5) }
        let finishes = FinishLog()
        await sdk.handleUpdatedTransaction(offerCodeTransaction("coupon-tx", finishes: finishes))
        XCTAssertEqual(server.verifies.map { $0.header("X-CashSDK-Claim") }, ["purchase"], "verified as the user's purchase")
        XCTAssertEqual(finishes.finished, ["coupon-tx"])

        let completion = try await waiting.value
        guard case .completed(let entitlements) = completion else { return XCTFail("\(completion)") }
        XCTAssertTrue(entitlements.isActive("pro"))
        // A late waiter sees the completion too.
        let again = try await sdk.awaitCouponCompletion(redemptionId: "red_1", timeout: 0)
        XCTAssertEqual(again, completion)
    }

    func testRedeemIsIdempotentAndSafeToRetry() async throws {
        let calls = Locked(0)
        let server = couponServer(redeem: { _ in
            let call = calls.withValue { $0 += 1; return $0 }
            // The first attempt meets a deploy blip; the retry and a second tap get the same reservation.
            if call == 1 { return StubServer.Response(status: 503, headers: ["Retry-After": "1"]) }
            return StubServer.Response(status: 200, body: json(["redemptionId": "red_same", "ios": ["appleCode": "SPRING", "redeemUrl": "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SPRING"]]))
        })
        let opened = Locked<[URL]>([])
        let sdk = try await signedIn(server, opened: opened)
        let first = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
        let second = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
        XCTAssertEqual(first.redemptionId, "red_same")
        XCTAssertEqual(second.redemptionId, "red_same")
        XCTAssertEqual(calls.value, 3)
        let bodies = server.requests.filter { $0.path == "/v1/coupons:redeem" }.map { body($0) as NSDictionary }
        XCTAssertEqual(Set(bodies).count, 1, "every attempt sends the same request")
        XCTAssertEqual(opened.value.count, 2)
    }

    func testRedeemRefusalsAreTypedForEveryReason() async throws {
        for reason in CouponInvalidReason.known {
            // In the body of a 200.
            let inBody = couponServer(redeem: { _ in StubServer.Response(status: 200, body: json(["valid": false, "reason": reason.rawValue])) })
            let opened = Locked<[URL]>([])
            let sdk = try await signedIn(inBody, opened: opened)
            do {
                _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
                XCTFail("\(reason) refused")
            } catch let error as CouponError {
                XCTAssertEqual(error, .rejected(reason))
            }
            // As an error status, in either envelope.
            inBody.respond { _ in StubServer.Response(status: 409, body: json(["error": ["code": "coupon_\(reason.rawValue)"]])) }
            do {
                _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
                XCTFail("\(reason) refused")
            } catch let error as CouponError {
                XCTAssertEqual(error, .rejected(reason))
            }
            inBody.respond { _ in StubServer.Response(status: 422, body: json(["error": reason.rawValue])) }
            do {
                _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
                XCTFail("\(reason) refused")
            } catch let error as CouponError {
                XCTAssertEqual(error, .rejected(reason))
            }
            XCTAssertTrue(opened.value.isEmpty, "a refused code never opens the App Store")
        }
    }

    func testRedeemIsAMoneyOperation() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server)
        try sdk.purchaseOperationGate.begin()
        do {
            _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
            XCTFail("a purchase is running")
        } catch CashSDKError.purchaseInProgress {}
        sdk.endMoneyOperation()
        XCTAssertTrue(server.requests.filter { $0.path == "/v1/coupons:redeem" }.isEmpty)
        _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
        XCTAssertFalse(sdk.purchaseOperationGate.isBusy, "the gate is released after the App Store opens")
    }

    func testRedeemInObserverModeIsRefused() async throws {
        let server = couponServer()
        let sdk = CashSDK(session: server.session(), automaticRecovery: false, store: temporaryStore(),
                          purchaseLog: temporaryPurchaseLog(), eventQueue: temporaryEventQueue())
        sdk.configure(with: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: server.baseURL, environment: "Production", observerMode: true))
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        do {
            _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
            XCTFail("observer mode")
        } catch CashSDKError.observerMode {}
    }

    func testAnUntrustedOrMissingRedeemURLIsRefused() async throws {
        for ios in [["appleCode": "SPRING"], ["appleCode": "SPRING", "redeemUrl": "https://evil.example/redeem?id=1&code=SPRING"]] {
            let server = couponServer(redeem: { _ in StubServer.Response(status: 200, body: json(["redemptionId": "red_1", "ios": ios])) })
            let opened = Locked<[URL]>([])
            let sdk = try await signedIn(server, opened: opened)
            do {
                _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
                XCTFail("nothing trustworthy to open")
            } catch let error as CouponError {
                XCTAssertEqual(error, .redeemURLUnavailable(productId: "app.pro.monthly"))
            }
            XCTAssertTrue(opened.value.isEmpty)
        }
    }

    func testAnAppStoreThatDoesNotOpenIsReported() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server, opens: false)
        do {
            _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
            XCTFail("the system refused to open the URL")
        } catch let error as CouponError {
            XCTAssertEqual(error, .couldNotOpenAppStore(redeemURL: URL(string: redeemURL)!))
        }
    }

    // MARK: - Completion

    func testCompletionTimesOutWhenNothingArrives() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server)
        _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
        let completion = try await sdk.awaitCouponCompletion(redemptionId: "red_1", timeout: 0.05)
        XCTAssertEqual(completion, .timedOut)
    }

    func testOnlyAnOffercodePurchaseOfThatProductCompletesIt() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server)
        _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
        let finishes = FinishLog()
        // An ordinary purchase of the product, and an offer code purchase of another product.
        await sdk.handleUpdatedTransaction(fixtureTransaction("plain", token: tokenA, finishes: finishes))
        await sdk.handleUpdatedTransaction(offerCodeTransaction("other", finishes: finishes, productId: "app.pro.yearly"))
        // An old offer code purchase that a restore reports.
        var old = offerCodeTransaction("old", finishes: finishes)
        old = StoreTransaction(id: old.id, productId: old.productId, jws: old.jws, appAccountToken: nil,
                               purchaseDate: Date().addingTimeInterval(-86400), originalId: old.originalId, renewal: false,
                               environment: nil, isServerVerifiable: true, finish: old.finish, offerType: 3, offerIdentifier: nil)
        await sdk.handleUpdatedTransaction(old)
        let completion = try await sdk.awaitCouponCompletion(redemptionId: "red_1", timeout: 0.05)
        XCTAssertEqual(completion, .timedOut)
        XCTAssertEqual(server.verifies.map { $0.header("X-CashSDK-Claim") }, ["sync", "sync", "sync"])
    }

    func testTheCouponPurchaseIsClaimedAfterARelaunch() async throws {
        // The app is killed while the user is in the App Store. The next launch's recovery pass
        // still reports the offer code purchase as this user's purchase.
        let log = temporaryPurchaseLog()
        let server = couponServer()
        let first = makeSDK(server, purchaseLog: log)
        first.couponURLOpener.value = { _ in true }
        _ = try await first.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        _ = try await first.redeemCoupon("SPRING", productId: "app.pro.monthly")

        let relaunched = makeSDK(server, purchaseLog: log)
        _ = try await relaunched.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let finishes = FinishLog()
        let bought = offerCodeTransaction("coupon-tx", finishes: finishes)
        relaunched.storeKit.currentEntitlementsLoader = { [bought] }
        relaunched.storeKit.unfinishedLoader = { [bought] }
        let waiting = Task { try await relaunched.awaitCouponCompletion(redemptionId: "red_1", timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await relaunched.launchBackstop()
        XCTAssertEqual(server.verifies.last?.header("X-CashSDK-Claim"), "purchase")
        XCTAssertEqual(finishes.finished, ["coupon-tx"])
        guard case .completed = try await waiting.value else { return XCTFail("an id from an earlier run completes on the next offer code purchase") }
    }

    // MARK: - Completion across a relaunch

    func testAWaiterStartedAfterTheVerifiedPurchaseSettlesAtOnce() async throws {
        // The app was killed while the user was in the App Store. The next launch's recovery
        // verifies the purchase before the app gets round to waiting for it.
        let log = temporaryPurchaseLog()
        let server = couponServer()
        let first = makeSDK(server, purchaseLog: log)
        first.couponURLOpener.value = { _ in true }
        _ = try await first.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        _ = try await first.redeemCoupon("SPRING", productId: "app.pro.monthly")

        let relaunched = makeSDK(server, purchaseLog: log)
        _ = try await relaunched.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let bought = offerCodeTransaction("coupon-tx", finishes: FinishLog())
        relaunched.storeKit.currentEntitlementsLoader = { [bought] }
        relaunched.storeKit.unfinishedLoader = { [bought] }
        await relaunched.launchBackstop()
        XCTAssertEqual(server.verifies.last?.header("X-CashSDK-Claim"), "purchase")

        let completion = try await relaunched.awaitCouponCompletion(redemptionId: "red_1", timeout: 0.05)
        guard case .completed(let entitlements) = completion else { return XCTFail("the purchase was verified before the wait: \(completion)") }
        XCTAssertTrue(entitlements.isActive("pro"))

        // And again after a second relaunch: the record is on disk, not only in memory.
        let third = makeSDK(server, purchaseLog: log)
        _ = try await third.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        guard case .completed = try await third.awaitCouponCompletion(redemptionId: "red_1", timeout: 0.05) else {
            return XCTFail("the verified purchase is kept for 24 hours")
        }
        // Another user on the same device sees nothing of it.
        _ = try await third.identifyAndWait(userId: "B", userToken: fixtureToken("B"))
        let other = try await third.awaitCouponCompletion(redemptionId: "red_1", timeout: 0.05)
        XCTAssertEqual(other, .timedOut)
    }

    func testTheCouponLogRecordsIdsKeepsOneDayAndIsPerUser() async {
        let log = temporaryPurchaseLog()
        let finishes = FinishLog()
        let started = Date()
        await log.recordAttempt(productId: "app.pro.monthly", userId: "A", couponRedemptionId: "red_1", at: started)
        let pending = await log.couponCompletion(redemptionId: "red_1", userId: "A")
        XCTAssertEqual(pending, .pending(productId: "app.pro.monthly", startedAt: started))

        let bought = offerCodeTransaction("coupon-tx", finishes: finishes)
        _ = await log.claim(for: bought, userId: "A")
        // Bound, not yet verified: nothing settles on an unverified purchase.
        let unverified = await log.couponCompletion(redemptionId: "red_1", userId: "A")
        XCTAssertEqual(unverified, .unknown)

        let record = await log.recordCouponCompletion(bought, userId: "A")
        XCTAssertEqual(record.redemptionIds, ["red_1"])
        XCTAssertTrue(record.verified)
        guard case .completed(let found) = await log.couponCompletion(redemptionId: "red_1", userId: "A") else { return XCTFail() }
        XCTAssertEqual(found.transactionId, "coupon-tx")
        let otherId = await log.couponCompletion(redemptionId: "red_other", userId: "A")
        XCTAssertEqual(otherId, .unknown, "a record that names its redemptions settles only those")
        let otherUser = await log.couponCompletion(redemptionId: "red_1", userId: "B")
        XCTAssertEqual(otherUser, .unknown)
        let tomorrow = await log.couponCompletion(redemptionId: "red_1", userId: "A", now: Date().addingTimeInterval(24 * 3600 + 60))
        XCTAssertEqual(tomorrow, .unknown, "kept 24 hours")

        // The success event is reported once per purchase.
        let firstMark = await log.markCouponReported(transactionId: "coupon-tx", userId: "A")
        let secondMark = await log.markCouponReported(transactionId: "coupon-tx", userId: "A")
        XCTAssertEqual([firstMark, secondMark], [true, false])
    }

    func testACodeTypedIntoTheAppStoreSettlesAnUnknownWaiter() async {
        let log = temporaryPurchaseLog()
        await log.recordCouponCompletion(offerCodeTransaction("typed", finishes: FinishLog()), userId: "A")
        guard case .completed(let record) = await log.couponCompletion(redemptionId: "red_from_elsewhere", userId: "A") else {
            return XCTFail("an offer code purchase with no known redemption settles an id this device does not know")
        }
        XCTAssertTrue(record.redemptionIds.isEmpty)
    }

    // MARK: - Which transactions settle a redemption

    func testOnlyAFreshNonRenewalOfferCodePurchaseCanSettle() {
        let now = Date()
        let finishes = FinishLog()
        XCTAssertTrue(CouponCompletionTracker.canSettle(offerCodeTransaction("new", finishes: finishes, purchaseDate: now), now: now))
        XCTAssertTrue(CouponCompletionTracker.canSettle(offerCodeTransaction("iOS16", finishes: finishes, purchaseDate: now, renewal: nil), now: now))
        XCTAssertTrue(CouponCompletionTracker.canSettle(offerCodeTransaction("hours", finishes: finishes, purchaseDate: now.addingTimeInterval(-23 * 3600)), now: now))
        XCTAssertFalse(CouponCompletionTracker.canSettle(offerCodeTransaction("renewal", finishes: finishes, purchaseDate: now, renewal: true), now: now))
        XCTAssertFalse(CouponCompletionTracker.canSettle(offerCodeTransaction("old", finishes: finishes, purchaseDate: now.addingTimeInterval(-25 * 3600)), now: now))
        XCTAssertFalse(CouponCompletionTracker.canSettle(fixtureTransaction("plain", token: nil, finishes: finishes), now: now))
    }

    func testLaunchReverificationOfAnOldDiscountedSubscriptionDoesNotSettle() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server)
        let finishes = FinishLog()
        // An offer code subscription bought last week, re-verified at launch, and its renewal
        // (still on the offer's discounted periods).
        let old = offerCodeTransaction("old", finishes: finishes, purchaseDate: Date().addingTimeInterval(-7 * 86400))
        let renewal = offerCodeTransaction("renewal", finishes: finishes, purchaseDate: Date(), renewal: true)
        sdk.storeKit.currentEntitlementsLoader = { [old, renewal] }
        sdk.storeKit.unfinishedLoader = { [] }
        let waiting = Task { try await sdk.awaitCouponCompletion(redemptionId: "red_from_before", timeout: 0.3) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await sdk.launchBackstop()
        XCTAssertEqual(server.verifies.count, 2)
        let completion = try await waiting.value
        XCTAssertEqual(completion, .timedOut)
        let events = await couponEvents(sdk, server)
        XCTAssertFalse(events.contains("coupon_redeem_success"))
    }

    // MARK: - Analytics

    func testSuccessIsRecordedOnlyWhenAPendingRedemptionSettles() async throws {
        let server = couponServer()
        let sdk = try await signedIn(server)
        let finishes = FinishLog()
        // An offer code purchase with nobody waiting (no redeem in this run): no success event.
        await sdk.handleUpdatedTransaction(offerCodeTransaction("typed", finishes: finishes, productId: "app.pro.yearly"))
        var events = await couponEvents(sdk, server)
        XCTAssertEqual(events, [])

        _ = try await sdk.redeemCoupon("SPRING", productId: "app.pro.monthly")
        let bought = offerCodeTransaction("coupon-tx", finishes: finishes)
        await sdk.handleUpdatedTransaction(bought)
        // StoreKit delivers the same transaction again: still one success.
        await sdk.handleUpdatedTransaction(bought)
        guard case .completed = try await sdk.awaitCouponCompletion(redemptionId: "red_1", timeout: 0) else { return XCTFail() }
        events = await couponEvents(sdk, server)
        XCTAssertEqual(events, ["coupon_redeem_start", "coupon_redeem_success"])
    }

    /// The coupon events recorded so far, sent or still queued.
    private func couponEvents(_ sdk: CashSDK, _ server: StubServer) async -> [String] {
        await sdk.eventWriteQueue.drain()
        let sent = server.requests.filter { $0.path == "/v1/events" }.flatMap { request -> [String] in
            let events = body(request)["events"] as? [[String: Any]] ?? []
            return events.compactMap { $0["event"] as? String }
        }
        let queued = await sdk.eventQueue.take(max: 10_000).map(\.event)
        return (sent + queued).filter { $0.hasPrefix("coupon_") }
    }

    // MARK: - Purchase log

    func testACouponAttemptMatchesOnlyAnOfferCodePurchase() async {
        let log = temporaryPurchaseLog()
        let finishes = FinishLog()
        await log.recordAttempt(productId: "app.pro.monthly", userId: "A", couponRedemptionId: "red_1")
        let tokenB = AppAccountToken.appAccountToken(for: "B")!
        let plainNoToken = await log.claim(for: fixtureTransaction("plain", token: nil, finishes: finishes), userId: "A")
        let anotherAccounts = await log.claim(for: offerCodeTransaction("b", finishes: finishes, token: tokenB), userId: "A")
        var renewal = offerCodeTransaction("renewal", finishes: finishes)
        renewal = StoreTransaction(id: renewal.id, productId: renewal.productId, jws: renewal.jws, appAccountToken: nil,
                                   purchaseDate: Date(), originalId: "chain", renewal: true, environment: nil,
                                   isServerVerifiable: true, finish: renewal.finish, offerType: 3, offerIdentifier: nil)
        let renewed = await log.claim(for: renewal, userId: "A")
        let otherUser = await log.claim(for: offerCodeTransaction("x", finishes: finishes), userId: "B")
        XCTAssertEqual([plainNoToken, anotherAccounts, renewed, otherUser], [.sync, .sync, .sync, .sync])
        let redeemed = await log.claim(for: offerCodeTransaction("coupon", finishes: finishes), userId: "A")
        XCTAssertEqual(redeemed, .purchase)
    }

    func testACouponAttemptLastsAsLongAsTheReservation() async {
        let log = temporaryPurchaseLog()
        let finishes = FinishLog()
        let started = Date().addingTimeInterval(-25 * 3600)
        await log.recordAttempt(productId: "app.pro.monthly", userId: "A", couponRedemptionId: "red_1", at: started)
        let claim = await log.claim(for: offerCodeTransaction("late", finishes: finishes), userId: "A")
        XCTAssertEqual(claim, .sync, "the server released the reservation after 24 hours")
    }

    func testOfferFieldsAreReadFromTheSignedPayload() {
        let payload = try! JSONSerialization.data(withJSONObject: ["offerType": 3, "offerIdentifier": "cashsdk-cpn-cpn_1-app.pro.monthly"])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let jws = "h.\(encoded).s"
        XCTAssertEqual((StoreTransaction.signedClaim(jws, "offerType") as? NSNumber)?.intValue, 3)
        XCTAssertEqual(StoreTransaction.signedClaim(jws, "offerIdentifier") as? String, "cashsdk-cpn-cpn_1-app.pro.monthly")
        XCTAssertNil(StoreTransaction.signedClaim("not-a-jws", "offerType"))
    }

    // MARK: - URL building

    func testRedeemURLBuilding() {
        func url(_ raw: String?, _ code: String? = "SPRING") -> String? {
            CashSDK.couponRedeemURL(raw, appleCode: code)?.absoluteString
        }
        XCTAssertEqual(url(redeemURL), redeemURL)
        // The reservation's code wins over whatever the URL carried.
        XCTAssertEqual(url("https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=OTHER", "SPRING-Y"),
                       "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SPRING-Y")
        // Missing pieces are added.
        XCTAssertEqual(url("https://apps.apple.com/redeem?id=1234567890"),
                       "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SPRING")
        XCTAssertEqual(url("https://APPS.apple.com/redeem?ctx=offercodes&id=1&code=SPRING", nil),
                       "https://APPS.apple.com/redeem?ctx=offercodes&id=1&code=SPRING")
        // Anything that is not the App Store's offer code page is refused.
        XCTAssertNil(url(nil))
        XCTAssertNil(url("http://apps.apple.com/redeem?ctx=offercodes&id=1&code=SPRING"))
        XCTAssertNil(url("https://apps.apple.com.evil.example/redeem?id=1&code=SPRING"))
        XCTAssertNil(url("https://apps.apple.com/app/id1?code=SPRING"))
        XCTAssertNil(url("https://apps.apple.com/redeem?ctx=offercodes&code=SPRING"), "no app id")
        XCTAssertNil(url("https://apps.apple.com/redeem?ctx=offercodes&id=1", nil), "no code")
        XCTAssertNil(url("not a url"))
    }

    // MARK: - Money

    func testAmountOffFormatsWithTheServersMinorUnits() {
        func coupon(_ minor: Int, _ currency: String) -> Coupon {
            Coupon(code: "C", name: "C", kind: .amountOff, percentOff: nil, amountOffMinor: minor, currency: currency, duration: "P1M", periodCount: 1)
        }
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(coupon(499, "USD").formattedAmountOff(locale: us), "$4.99")
        XCTAssertEqual(coupon(500, "JPY").amountOff, Decimal(500))
        XCTAssertEqual(coupon(1500, "KWD").amountOff, Decimal(string: "1.5"))
        // ICU separates the code with a no-break space.
        XCTAssertEqual(coupon(1500, "kwd").formattedAmountOff(locale: us)?.replacingOccurrences(of: "\u{00A0}", with: " "), "KWD 1.500")
        XCTAssertEqual(coupon(500, "JPY").formattedAmountOff(locale: us), "¥500")
        let percent = Coupon(code: "C", name: "C", kind: .percentOff, percentOff: 20, amountOffMinor: nil, currency: nil, duration: "P1M", periodCount: 1)
        XCTAssertNil(percent.formattedAmountOff())
        XCTAssertNil(percent.amountOff)
        XCTAssertEqual(CouponKind(rawValue: "free_trial"), .freeTrial)
        XCTAssertEqual(CouponKind(rawValue: "bogo"), .unknown("bogo"))
    }
}
