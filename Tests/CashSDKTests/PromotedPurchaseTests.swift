import Foundation
import XCTest
@testable import CashSDK

/// A promoted In-App Purchase that met a running purchase, an offline product lookup or a
/// network error was dropped. It now waits and runs again, a bounded number of times, but only
/// when it failed before the App Store sheet: after the sheet a charge is possible, and buying
/// again could charge twice. A failed one goes back in the queue with its wait before the next
/// one starts, so failures never chase each other round the queue.
final class PromotedPurchaseTests: XCTestCase {

    private func waiting(_ sdk: CashSDK) -> [String] { sdk.waitingPromotedPurchases.map(\.productId) }

    private func identifiedSDK(_ finishes: FinishLog, sheets: Locked<[String]>, token: String = fixtureToken("A")) async throws -> (CashSDK, StubServer) {
        let server = StubServer { request in
            switch request.path {
            case "/v1/transactions:verify": return Fixture.verified(user: "A")
            case "/v1/entitlements": return Fixture.entitlements(user: "A")
            default: return StubServer.Response(status: 202)
            }
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: token)
        sdk.storeKit.purchaseHandler = { productId, token in
            sheets.withValue { $0.append(productId) }
            return .verified(fixtureTransaction(productId, token: token, finishes: finishes, productId: productId))
        }
        return (sdk, server)
    }

    func testRetryDecisions() {
        let offline = CashSDKError.network(underlying: URLError(.notConnectedToInternet))
        XCTAssertEqual(CashSDK.promotedRetry(after: CashSDKError.purchaseInProgress, reachedStore: false), .afterCurrentOperation)
        XCTAssertEqual(CashSDK.promotedRetry(after: offline, reachedStore: false), .afterNetwork)
        XCTAssertEqual(CashSDK.promotedRetry(after: CashSDKError.productNotFound("p"), reachedStore: false), .afterNetwork)
        XCTAssertEqual(CashSDK.promotedRetry(after: CashSDKError.identityTokenExpired, reachedStore: false), .afterIdentify)
        XCTAssertEqual(CashSDK.promotedRetry(after: offline, reachedStore: true), .never, "a charge is possible after the sheet")
        XCTAssertEqual(CashSDK.promotedRetry(after: CashSDKError.chargedButUnverified(transactionId: "1", underlying: offline), reachedStore: true), .never)
        XCTAssertEqual(CashSDK.promotedRetry(after: CashSDKError.alreadySubscribed(productId: "p"), reachedStore: true), .never)
    }

    func testWaitsForAPurchaseInProgress() async throws {
        let finishes = FinishLog()
        let sheets = Locked<[String]>([])
        let (sdk, _) = try await identifiedSDK(finishes, sheets: sheets)
        let latch = TestLatch()
        sdk.storeKit.purchaseHandler = { productId, token in
            sheets.withValue { $0.append(productId) }
            if productId == "app.pro.monthly" { await latch.wait() }
            return .verified(fixtureTransaction(productId, token: token, finishes: finishes, productId: productId))
        }
        let inApp = Task { try await sdk.purchase("app.pro.monthly") }
        await eventually { sheets.value == ["app.pro.monthly"] }

        sdk.receivePromotedPurchase(productId: "app.pro.yearly")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sheets.value, ["app.pro.monthly"], "one payment sheet at a time")
        XCTAssertEqual(waiting(sdk), ["app.pro.yearly"], "kept, not dropped")

        await latch.open()
        _ = try await inApp.value
        await eventually("the promoted purchase did not run when the other one ended") {
            finishes.finished.contains("app.pro.yearly")
        }
        XCTAssertEqual(sheets.value, ["app.pro.monthly", "app.pro.yearly"])
    }

    func testFailingSessionDoesNotLoopThroughTheQueue() async throws {
        struct BackendDown: Error {}
        let finishes = FinishLog()
        let sheets = Locked<[String]>([])
        // Thirty seconds left and a provider that cannot renew: every attempt fails before the sheet.
        let (sdk, _) = try await identifiedSDK(finishes, sheets: sheets, token: fixtureToken("A", expiresIn: 30))
        let renewals = Locked(0)
        sdk.userTokenProvider = { _ in renewals.withValue { $0 += 1 }; throw BackendDown() }

        sdk.receivePromotedPurchase(productId: "app.pro.monthly")
        sdk.receivePromotedPurchase(productId: "app.pro.yearly")
        await eventually { renewals.value == 2 && sdk.waitingPromotedPurchases.allSatisfy(\.waitingForIdentify) && self.waiting(sdk).count == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(renewals.value, 2, "each tried once, then held for the next identify: no lap round the queue")
        XCTAssertEqual(sdk.waitingPromotedPurchases.map(\.failures), [1, 1])

        // Each identify gives both one more try, until they are dropped.
        for round in 2...CashSDK.maxPromotedFailures {
            _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A", expiresIn: 30))
            await eventually { renewals.value == 2 * round }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(renewals.value, 2 * round)
        }
        await eventually("dropped after the last attempt") { sdk.waitingPromotedPurchases.isEmpty }
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A", expiresIn: 30))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(renewals.value, 2 * CashSDK.maxPromotedFailures)
        XCTAssertTrue(sheets.value.isEmpty)
    }

    func testOfflineRetriesAreSpacedOut() async throws {
        let finishes = FinishLog()
        let sheets = Locked<[String]>([])
        let (sdk, _) = try await identifiedSDK(finishes, sheets: sheets)
        sdk.promotedRetryBase.value = 0.6 // The first wait is 0.3 to 0.6 seconds.
        let lookups = Locked(0)
        sdk.storeKit.purchaseLookupHandler = { _ in
            lookups.withValue { $0 += 1 }
            throw CashSDKError.network(underlying: URLError(.notConnectedToInternet))
        }
        sdk.receivePromotedPurchase(productId: "app.pro.monthly")
        sdk.receivePromotedPurchase(productId: "app.pro.yearly")
        await eventually { lookups.value == 2 && self.waiting(sdk).count == 2 }
        let queued = sdk.waitingPromotedPurchases
        XCTAssertEqual(queued.map(\.failures), [1, 1])
        XCTAssertTrue(queued.allSatisfy { $0.notBefore > Date() }, "each waits before its next try")

        // A call that succeeds does not bring a retry forward.
        _ = try await sdk.refreshEntitlements()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lookups.value, 2)

        // Each is tried again once its wait is over, and dropped after the last attempt.
        await eventually("the retries never came") { lookups.value >= 4 }
        sdk.promotedRetryBase.value = 0.02
        await eventually { lookups.value == 2 * CashSDK.maxPromotedFailures && sdk.waitingPromotedPurchases.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(lookups.value, 2 * CashSDK.maxPromotedFailures)
        XCTAssertTrue(sheets.value.isEmpty)
    }

    func testRunsAgainWhenTheNetworkReturns() async throws {
        let finishes = FinishLog()
        let sheets = Locked<[String]>([])
        let (sdk, _) = try await identifiedSDK(finishes, sheets: sheets)
        sdk.promotedRetryBase.value = 0.1
        let online = Locked(false)
        sdk.storeKit.purchaseLookupHandler = { _ in
            if !online.value { throw CashSDKError.network(underlying: URLError(.notConnectedToInternet)) }
        }
        sdk.receivePromotedPurchase(productId: "app.pro.yearly")
        await eventually { self.waiting(sdk) == ["app.pro.yearly"] }
        XCTAssertTrue(sheets.value.isEmpty)

        online.value = true
        await eventually("the promoted purchase did not run when the network returned") {
            finishes.finished == ["app.pro.yearly"]
        }
        XCTAssertEqual(sheets.value, ["app.pro.yearly"])
        XCTAssertTrue(waiting(sdk).isEmpty)
    }

    func testNeverRunsAgainAfterTheSheet() async throws {
        let finishes = FinishLog()
        let sheets = Locked<[String]>([])
        let (sdk, _) = try await identifiedSDK(finishes, sheets: sheets)
        sdk.storeKit.purchaseHandler = { productId, _ in
            sheets.withValue { $0.append(productId) }
            throw CashSDKError.network(underlying: URLError(.networkConnectionLost))
        }
        sdk.receivePromotedPurchase(productId: "app.pro.yearly")
        await eventually { sheets.value == ["app.pro.yearly"] }
        _ = try await sdk.refreshEntitlements()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sheets.value, ["app.pro.yearly"], "the App Store may have charged; never buy again")
        XCTAssertTrue(waiting(sdk).isEmpty)
    }
}
