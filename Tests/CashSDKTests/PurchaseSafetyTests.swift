import XCTest
@testable import CashSDK

final class PurchaseSafetyTests: XCTestCase {
    func testSelectorDefaultUsesOnlyLoadedProducts() throws {
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(#"{"products":[{"role":"primary","id":"month"},{"role":"annual","id":"year"}],"root":{"type":"stack","children":[{"type":"product_selector","products":["primary","annual"],"default":"annual"}]}}"#.utf8))
        XCTAssertEqual(initialPaywallRole(config: config, availableRoles: ["primary", "annual"]), "annual")
        XCTAssertEqual(initialPaywallRole(config: config, availableRoles: ["primary"]), "primary")
        XCTAssertEqual(initialPaywallRole(config: config, availableRoles: []), "")
    }

    func testOverlappingOperationsAreRejectedAndGateCanBeReused() throws {
        let gate = PurchaseOperationGate()
        try gate.begin()
        XCTAssertThrowsError(try gate.begin()) { error in
            guard case CashSDKError.purchaseInProgress = error else { return XCTFail("Wrong error") }
        }
        gate.end()
        try gate.begin()
        gate.end()
    }

    func testAttributionRequiredAndOtherAccountCannotGrant() throws {
        XCTAssertThrowsError(try requirePurchaseAttribution(attributed: false, belongsToAnotherAccount: nil))
        XCTAssertThrowsError(try requirePurchaseAttribution(attributed: true, belongsToAnotherAccount: true)) { error in
            guard case CashSDKError.purchaseBelongsToAnotherAccount = error else { return XCTFail("Wrong error") }
        }
        try requirePurchaseAttribution(attributed: true, belongsToAnotherAccount: false)
        try requirePurchaseAttribution(attributed: true, belongsToAnotherAccount: nil)
    }

    func testFeedbackDoesNotExposeServerDetailsOrDenyPossibleCharge() {
        let feedback = PaywallFeedback.failure(CashSDKError.server(status: 500, code: "private", message: "sensitive receipt"), restoring: false)
        XCTAssertTrue(feedback.message.contains("Payment may have completed"))
        XCTAssertFalse(feedback.message.contains("sensitive"))
        XCTAssertFalse(feedback.title.contains("cancel"))
        XCTAssertTrue(PaywallFeedback.pending.message.contains("do not need to buy again"))
    }

    func testRestoreAndOwnershipFeedbackAreDistinct() {
        XCTAssertEqual(PaywallFeedback.failure(CashSDKError.invalidResponse, restoring: true).title, "Restore not completed")
        XCTAssertTrue(PaywallFeedback.failure(CashSDKError.purchaseBelongsToAnotherAccount, restoring: false).message.contains("another app account"))
        XCTAssertEqual(PaywallFeedback.nothingToRestore.title, "Restore complete")
    }
}
