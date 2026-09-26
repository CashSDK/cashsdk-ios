import Foundation
import StoreKit
import XCTest
@testable import CashSDK

/// Every thrown StoreKit error used to become `.network`, so the paywall told people "payment
/// may have completed" for refusals that happen before any charge, including App Store error
/// 3532 (this Apple ID already has the subscription). An unknown purchase result read as a
/// cancellation.
final class StoreErrorMappingTests: XCTestCase {

    func testRefusalsBeforeAnyChargeAreTyped() {
        XCTAssertEqual(StoreKitManager.classify(StoreKitError.userCancelled), .cancelled)
        XCTAssertEqual(StoreKitManager.classify(StoreKitError.notAvailableInStorefront), .unavailable)
        XCTAssertEqual(StoreKitManager.classify(Product.PurchaseError.purchaseNotAllowed), .notAllowed)
        XCTAssertEqual(StoreKitManager.classify(Product.PurchaseError.productUnavailable), .unavailable)
        XCTAssertEqual(StoreKitManager.classify(NSError(domain: SKErrorDomain, code: SKError.Code.paymentNotAllowed.rawValue)), .notAllowed)
        XCTAssertEqual(StoreKitManager.classify(NSError(domain: SKErrorDomain, code: SKError.Code.paymentCancelled.rawValue)), .cancelled)

        guard case CashSDKError.purchaseCancelled = StoreKitManager.purchaseError(StoreKitError.userCancelled, productId: "p") else {
            return XCTFail("a cancellation thrown by StoreKit is still a cancellation")
        }
        guard case CashSDKError.purchaseNotAllowed = StoreKitManager.purchaseError(Product.PurchaseError.purchaseNotAllowed, productId: "p") else {
            return XCTFail("restricted devices get their own error")
        }
        guard case CashSDKError.productUnavailable(let id) = StoreKitManager.purchaseError(StoreKitError.notAvailableInStorefront, productId: "p") else {
            return XCTFail("storefront refusals get their own error")
        }
        XCTAssertEqual(id, "p")
    }

    func testAlreadySubscribedIsFoundAnywhereInTheErrorChain() {
        let serverError = NSError(domain: "ASDServerErrorDomain", code: 3532, userInfo: [NSLocalizedFailureReasonErrorKey: "You're currently subscribed to this."])
        let shapes: [Error] = [
            StoreKitError.systemError(serverError),
            NSError(domain: SKErrorDomain, code: SKError.Code.unknown.rawValue, userInfo: [NSUnderlyingErrorKey: serverError]),
            NSError(domain: "AMSErrorDomain", code: 305, userInfo: ["AMSServerErrorCode": 3532]),
            NSError(domain: "AMSErrorDomain", code: 305, userInfo: ["AMSServerErrorCode": "3532"]),
        ]
        for error in shapes {
            XCTAssertEqual(StoreKitManager.classify(error), .alreadySubscribed, "\(error)")
            guard case CashSDKError.alreadySubscribed(let id) = StoreKitManager.purchaseError(error, productId: "app.pro.yearly") else {
                return XCTFail("3532 must not read as a network error: \(error)")
            }
            XCTAssertEqual(id, "app.pro.yearly")
        }
    }

    func testFailuresThatMayFollowAChargeStayCautious() {
        XCTAssertEqual(StoreKitManager.classify(StoreKitError.networkError(URLError(.notConnectedToInternet))), .network)
        XCTAssertEqual(StoreKitManager.classify(StoreKitError.systemError(URLError(.timedOut))), .network)
        XCTAssertEqual(StoreKitManager.classify(StoreKitError.unknown), .other)
        XCTAssertEqual(StoreKitManager.classify(StoreKitError.systemError(NSError(domain: "Other", code: 1))), .other)
        XCTAssertEqual(StoreKitManager.classify(Product.PurchaseError.invalidQuantity), .other)
        guard case CashSDKError.storeKitFailed(let underlying) = StoreKitManager.purchaseError(StoreKitError.unknown, productId: "p") else {
            return XCTFail("an unclassified StoreKit failure is not a network error")
        }
        XCTAssertNotNil(underlying)
    }

    func testSyncErrorsDistinguishCancellation() {
        guard case CashSDKError.purchaseCancelled = StoreKitManager.syncError(StoreKitError.userCancelled) else {
            return XCTFail("cancelling the App Store sign-in is not a failed restore")
        }
        guard case CashSDKError.network = StoreKitManager.syncError(StoreKitError.networkError(URLError(.timedOut))) else {
            return XCTFail("offline sync is a network error")
        }
        guard case CashSDKError.storeKitFailed = StoreKitManager.syncError(StoreKitError.unknown) else {
            return XCTFail("anything else is a StoreKit failure")
        }
    }

    // MARK: - Through purchase()

    func testCancellationThrownByStoreKitReturnsUserCancelled() async throws {
        let server = StubServer()
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        sdk.storeKit.purchaseHandler = { productId, _ in
            throw StoreKitManager.purchaseError(StoreKitError.userCancelled, productId: productId)
        }
        let result = try await sdk.purchase("app.pro.monthly")
        guard case .userCancelled = result else { return XCTFail("expected .userCancelled, got \(result)") }
        XCTAssertTrue(server.verifies.isEmpty)
    }

    func testRefusalsReachTheHostTypedWithoutAVerify() async throws {
        let server = StubServer()
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let already = NSError(domain: "ASDServerErrorDomain", code: 3532)
        sdk.storeKit.purchaseHandler = { productId, _ in
            throw StoreKitManager.purchaseError(StoreKitError.systemError(already), productId: productId)
        }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("the App Store refused")
        } catch CashSDKError.alreadySubscribed(let productId) {
            XCTAssertEqual(productId, "app.pro.monthly")
        }
        sdk.storeKit.purchaseHandler = { productId, _ in
            throw StoreKitManager.purchaseError(Product.PurchaseError.purchaseNotAllowed, productId: productId)
        }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("the App Store refused")
        } catch CashSDKError.purchaseNotAllowed {}
        XCTAssertTrue(server.verifies.isEmpty)
    }

    // MARK: - Paywall wording

    func testPaywallExplainsRefusalsWithoutClaimingAPossibleCharge() throws {
        let cases: [(Error, String)] = [
            (CashSDKError.alreadySubscribed(productId: "p"), "Restore purchases"),
            (CashSDKError.purchaseNotAllowed, "Screen Time"),
            (CashSDKError.productUnavailable(productId: "p"), "not available"),
            (CashSDKError.productNotFound("p"), "not available"),
            (CashSDKError.identityTokenExpired, "sign in again"),
        ]
        for (error, expected) in cases {
            let feedback = try XCTUnwrap(PaywallFeedback.failure(error, restoring: false))
            XCTAssertTrue(feedback.message.contains(expected), "\(error): \(feedback.message)")
            XCTAssertFalse(feedback.message.contains("Payment may have completed"), "\(error) happens before any charge")
        }
    }

    func testPaywallStaysCautiousWhenAChargeIsPossible() throws {
        let charged = try XCTUnwrap(PaywallFeedback.failure(
            CashSDKError.chargedButUnverified(transactionId: "1", underlying: CashSDKError.invalidResponse), restoring: false))
        XCTAssertTrue(charged.message.contains("Payment may have completed"))
        for error in [CashSDKError.network(underlying: URLError(.timedOut)), CashSDKError.storeKitFailed(underlying: nil)] {
            let feedback = try XCTUnwrap(PaywallFeedback.failure(error, restoring: false))
            XCTAssertTrue(feedback.message.contains("access will update on its own"), "\(error): \(feedback.message)")
            XCTAssertFalse(feedback.message.contains("not charged"))
        }
    }

    func testUserFacingTextNeverShowsTheProductId() throws {
        let error = CashSDKError.productUnavailable(productId: "com.example.internal.sku")
        let text = try XCTUnwrap(error.errorDescription)
        XCTAssertFalse(text.contains("com.example.internal.sku"))
        guard case .productUnavailable(let id) = error else { return XCTFail() }
        XCTAssertEqual(id, "com.example.internal.sku", "the payload keeps it for the host and the log")
    }

    func testCancellationShowsNothing() {
        XCTAssertNil(PaywallFeedback.failure(CashSDKError.purchaseCancelled, restoring: false))
        XCTAssertNil(PaywallFeedback.failure(CashSDKError.purchaseCancelled, restoring: true))
        XCTAssertNil(PaywallFeedback.failure(CashSDKError.restoreVerificationFailed(underlying: CashSDKError.purchaseCancelled), restoring: true))
    }
}
