import Foundation
import StoreKit
import XCTest
@testable import CashSDK

/// A purchase whose first `purchase` verify did not land, and every Ask-to-Buy or SCA purchase,
/// came back through recovery with claim `sync`. `sync` never moves a purchase between accounts,
/// so under restore policy `transfer` a returning customer's resubscribe, on a chain an old
/// account owns, was never credited and never finished. Recovery now reports the purchases this
/// device started for the signed-in user as `purchase`, and everything else as `sync`.
final class PurchaseClaimTests: XCTestCase {
    private let tokenA = AppAccountToken.appAccountToken(for: "A")!
    private let tokenB = AppAccountToken.appAccountToken(for: "B")!

    private func claims(_ server: StubServer) -> [String?] {
        server.verifies.map { $0.header("X-CashSDK-Claim") }
    }

    func testFailedFirstVerifyIsReportedAgainAsAPurchase() async throws {
        let finishes = FinishLog()
        let online = Locked(false)
        let server = StubServer { request in
            guard request.path == "/v1/transactions:verify" else { return StubServer.Response(status: 202) }
            return online.value ? Fixture.verified(user: "A") : StubServer.Response(status: 503)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let bought = fixtureTransaction("bought", token: tokenA, finishes: finishes)
        sdk.storeKit.purchaseHandler = { _, _ in .verified(bought) }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("the verify did not land")
        } catch CashSDKError.chargedButUnverified {}
        XCTAssertEqual(claims(server), ["purchase", "purchase", "purchase"])
        XCTAssertTrue(finishes.finished.isEmpty)

        // The recovery pass (launch, foreground, or the scheduled retry) reports it again.
        online.value = true
        sdk.storeKit.currentEntitlementsLoader = { [] }
        sdk.storeKit.unfinishedLoader = { [bought] }
        await sdk.launchBackstop()
        XCTAssertEqual(claims(server).last, "purchase", "recovery of the buyer's own purchase must not drop to sync")
        XCTAssertEqual(finishes.finished, ["bought"])

        // Credited, so the record is gone: a redelivery is an ordinary automatic report.
        await sdk.handleUpdatedTransaction(bought)
        XCTAssertEqual(claims(server).last, "sync")
    }

    func testAskToBuyApprovalThroughTheListenerIsAPurchase() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        sdk.storeKit.purchaseHandler = { _, _ in .pending }
        let result = try await sdk.purchase("app.pro.monthly")
        guard case .pending = result else { return XCTFail("\(result)") }

        // A parent approves; StoreKit delivers the transaction through `Transaction.updates`.
        await sdk.handleUpdatedTransaction(fixtureTransaction("approved", token: tokenA, finishes: finishes))
        XCTAssertEqual(claims(server), ["purchase"])
        XCTAssertEqual(finishes.finished, ["approved"])

        // Its renewal a month later is automatic.
        await sdk.handleUpdatedTransaction(fixtureTransaction("renewal", token: tokenA, finishes: finishes,
                                                             purchaseDate: Date().addingTimeInterval(30 * 86400)))
        XCTAssertEqual(claims(server), ["purchase", "sync"])
    }

    func testRenewalsAndOtherTransactionsStaySync() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            guard request.path == "/v1/transactions:verify" else { return StubServer.Response(status: 202) }
            return Fixture.verified(user: request.header("X-CashSDK-User-Id") ?? "")
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        sdk.storeKit.purchaseHandler = { _, _ in .pending }
        _ = try await sdk.purchase("app.pro.monthly")

        // None of these is the pending purchase.
        let older = Date().addingTimeInterval(-3600)
        await sdk.handleUpdatedTransaction(fixtureTransaction("offer-code", token: nil, finishes: finishes))
        await sdk.handleUpdatedTransaction(fixtureTransaction("other-plan", token: tokenA, finishes: finishes, productId: "app.pro.yearly"))
        await sdk.handleUpdatedTransaction(fixtureTransaction("earlier", token: tokenA, finishes: finishes, purchaseDate: older))
        XCTAssertEqual(claims(server), ["sync", "sync", "sync"])

        // The approval still is.
        await sdk.handleUpdatedTransaction(fixtureTransaction("approved", token: tokenA, finishes: finishes))
        XCTAssertEqual(claims(server).last, "purchase")

        // Another user's transaction, with A's pending purchase for the same product on record.
        _ = try await sdk.purchase("app.pro.monthly")
        _ = try await sdk.identifyAndWait(userId: "B", userToken: fixtureToken("B"))
        await sdk.handleUpdatedTransaction(fixtureTransaction("b-bought", token: tokenB, finishes: finishes))
        XCTAssertEqual(claims(server).last, "sync")
    }

    func testUserSwitchDoesNotReuseTheRecord() async throws {
        let finishes = FinishLog()
        let online = Locked(false)
        let server = StubServer { request in
            guard request.path == "/v1/transactions:verify" else { return StubServer.Response(status: 202) }
            guard online.value else { return StubServer.Response(status: 503) }
            let user = request.header("X-CashSDK-User-Id") ?? ""
            return user == "A" ? Fixture.verified(user: "A") : Fixture.ownedByAnotherAccount
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        // A transaction every account on this device may report: it carries no token.
        let shared = fixtureTransaction("shared", token: nil, finishes: finishes)
        sdk.storeKit.purchaseHandler = { _, _ in .verified(shared) }
        do { _ = try await sdk.purchase("app.pro.monthly"); XCTFail("offline") }
        catch CashSDKError.chargedButUnverified {}

        online.value = true
        _ = try await sdk.identifyAndWait(userId: "B", userToken: fixtureToken("B"))
        await sdk.handleUpdatedTransaction(shared)
        XCTAssertEqual(claims(server).last, "sync", "B did not buy it here, so B cannot claim it")
        XCTAssertTrue(finishes.finished.isEmpty)

        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        await sdk.handleUpdatedTransaction(shared)
        XCTAssertEqual(claims(server).last, "purchase", "A's record survives B's session")
        XCTAssertEqual(finishes.finished, ["shared"])
    }

    func testRefusalBeforeChargeForgetsTheAttempt() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        sdk.storeKit.purchaseHandler = { productId, _ in
            throw StoreKitManager.purchaseError(StoreKitError.systemError(NSError(domain: "ASDServerErrorDomain", code: 3532)), productId: productId)
        }
        do { _ = try await sdk.purchase("app.pro.monthly"); XCTFail("refused") }
        catch CashSDKError.alreadySubscribed {}
        sdk.storeKit.purchaseHandler = { _, _ in .userCancelled }
        _ = try await sdk.purchase("app.pro.monthly")

        // A later purchase of the product made on another device is not this device's attempt.
        await sdk.handleUpdatedTransaction(fixtureTransaction("elsewhere", token: tokenA, finishes: finishes))
        XCTAssertEqual(claims(server), ["sync"])
    }

    // MARK: - What recovery relies on

    func testAttemptIsOnRecordBeforeTheSheetOpens() async throws {
        let file = temporaryFile("purchases")
        let sdk = makeSDK(StubServer(), purchaseLog: PurchaseLog(fileURL: file))
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let seenWithSheetOpen = Locked<VerifyClaim?>(nil)
        sdk.storeKit.purchaseHandler = { _, token in
            // The app is killed with the sheet open and the charge goes through: the next launch
            // only has the file.
            let relaunched = PurchaseLog(fileURL: file)
            let charged = fixtureTransaction("charged", token: token, finishes: FinishLog())
            seenWithSheetOpen.value = await relaunched.claim(for: charged, userId: "A")
            return .userCancelled
        }
        _ = try await sdk.purchase("app.pro.monthly")
        XCTAssertEqual(seenWithSheetOpen.value, .purchase, "the attempt has to be on disk before the sheet opens")
    }

    func testFailureThatMayFollowAChargeKeepsTheAttempt() async throws {
        let failures: [CashSDKError] = [.network(underlying: URLError(.networkConnectionLost)), .storeKitFailed(underlying: nil)]
        for failure in failures {
            let finishes = FinishLog()
            let server = StubServer { request in
                request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
            }
            let sdk = makeSDK(server)
            _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
            sdk.storeKit.purchaseHandler = { _, _ in throw failure }
            do { _ = try await sdk.purchase("app.pro.monthly"); XCTFail("\(failure)") } catch {}
            // The App Store charged after all, and the transaction arrives through the listener.
            await sdk.handleUpdatedTransaction(fixtureTransaction("late", token: tokenA, finishes: finishes))
            XCTAssertEqual(claims(server), ["purchase"], "\(failure)")
            XCTAssertEqual(finishes.finished, ["late"])
        }
    }

    func testCreditInThePurchaseClearsTheRecord() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let bought = fixtureTransaction("bought", token: tokenA, finishes: finishes)
        sdk.storeKit.purchaseHandler = { _, _ in .verified(bought) }
        _ = try await sdk.purchase("app.pro.monthly")
        // StoreKit delivers it again (a second device, a relaunch): nothing is left to claim.
        await sdk.handleUpdatedTransaction(bought)
        XCTAssertEqual(claims(server), ["purchase", "sync"])
    }

    func testCreditThroughTheListenerClearsTheRecord() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        sdk.storeKit.purchaseHandler = { _, _ in .pending }
        _ = try await sdk.purchase("app.pro.monthly")
        let approved = fixtureTransaction("approved", token: tokenA, finishes: finishes)
        await sdk.handleUpdatedTransaction(approved)
        await sdk.handleUpdatedTransaction(approved)
        XCTAssertEqual(claims(server), ["purchase", "sync"])
    }

    func testRenewalAfterLeftoverAttemptsStaysSync() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        // A tap that failed on the network and one left pending (a declined Ask to Buy, say)
        // both leave their attempt behind.
        sdk.storeKit.purchaseHandler = { _, _ in throw CashSDKError.network(underlying: URLError(.networkConnectionLost)) }
        _ = try? await sdk.purchase("app.pro.monthly")
        sdk.storeKit.purchaseHandler = { _, _ in .pending }
        _ = try await sdk.purchase("app.pro.monthly")

        // A weekly (or sandbox) renewal of the product, on a chain another account may hold
        // after a `transfer` restore. A `purchase` claim would take it back.
        let renewal = fixtureTransaction("renewal", token: tokenA, finishes: finishes,
                                         purchaseDate: Date().addingTimeInterval(60), originalId: "chain", renewal: true)
        await sdk.handleUpdatedTransaction(renewal)
        XCTAssertEqual(claims(server), ["sync"])
    }
}
