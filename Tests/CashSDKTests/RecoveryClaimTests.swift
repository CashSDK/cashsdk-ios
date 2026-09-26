import Foundation
import XCTest
@testable import CashSDK

/// Every verify now says why it is being made (`X-CashSDK-Claim`). The server lets only
/// `purchase` and `restore` move a purchase between app accounts; `sync` (everything automatic)
/// never does, which is what makes it safe to report purchases that carry no app account token.
final class RecoveryClaimTests: XCTestCase {
    private let tokenA = AppAccountToken.appAccountToken(for: "A")
    private let tokenB = AppAccountToken.appAccountToken(for: "B")

    private func identifiedSDK(_ server: StubServer) async throws -> CashSDK {
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        return sdk
    }

    func testVerifySendsTheClaimItIsGiven() async throws {
        let server = StubServer { _ in Fixture.verified(user: "A") }
        let api = APIClient(configuration: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: server.baseURL), session: server.session())
        await api.setIdentity(userId: "A", userToken: "token-A")
        for claim in [VerifyClaim.purchase, .restore, .sync] {
            _ = try await api.verify(signedTransaction: "jws-\(claim.rawValue)", claim: claim)
        }
        XCTAssertEqual(server.verifies.map { $0.header("X-CashSDK-Claim") }, ["purchase", "restore", "sync"])
    }

    func testPurchaseReportsWithPurchaseClaimAndFinishesAfterConfirmation() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A", transferred: true) : StubServer.Response(status: 202)
        }
        let sdk = try await identifiedSDK(server)
        let stampedToken = Locked<UUID?>(nil)
        sdk.storeKit.purchaseHandler = { _, token in
            stampedToken.value = token
            return .verified(fixtureTransaction("bought", token: token, finishes: finishes))
        }
        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success(let access) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(stampedToken.value, tokenA, "the buyer's canonical token rides the purchase")
        XCTAssertEqual(server.verifies.map { $0.header("X-CashSDK-Claim") }, ["purchase"])
        XCTAssertEqual(finishes.finished, ["bought"])
        XCTAssertEqual(access.transferredFromAnotherAccount, true, "the host can tell the user the purchase moved")
    }

    func testTransferNoticeIsDeliveredOnceNotReplayed() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A", transferred: true) : StubServer.Response(status: 202)
        }
        let sdk = try await identifiedSDK(server)
        sdk.storeKit.purchaseHandler = { _, token in .verified(fixtureTransaction("moved", token: token, finishes: finishes)) }
        let result = try await sdk.purchase("app.pro.monthly")
        guard case .success(let access) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(access.transferredFromAnotherAccount, true, "the result that carried it")

        XCTAssertNil(sdk.entitlements.transferredFromAnotherAccount)
        var updates = sdk.entitlementUpdates.makeAsyncIterator()
        let first = await updates.next()
        XCTAssertNil(first?.transferredFromAnotherAccount, "a new subscriber must not be told again")
        XCTAssertTrue(first?.isActive("pro") == true)
    }

    func testFailedVerifyLeavesThePurchaseUnfinished() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? StubServer.Response(status: 503) : StubServer.Response(status: 202)
        }
        let sdk = try await identifiedSDK(server)
        sdk.storeKit.purchaseHandler = { _, token in .verified(fixtureTransaction("bought", token: token, finishes: finishes)) }
        do {
            _ = try await sdk.purchase("app.pro.monthly")
            XCTFail("unverified")
        } catch CashSDKError.chargedButUnverified(let id, _) {
            XCTAssertEqual(id, "bought")
        }
        XCTAssertTrue(finishes.finished.isEmpty, "never finished without server confirmation")
        XCTAssertEqual(server.verifies.count, 3)
    }

    func testAutomaticRecoveryReportsOwnAndTokenlessPurchasesWithSyncClaim() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            switch request.jws {
            case "jws-own", "jws-offer-code": return Fixture.verified(user: "A")
            case "jws-family": return Fixture.ownedByAnotherAccount
            default: return request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A") : StubServer.Response(status: 202)
            }
        }
        let sdk = try await identifiedSDK(server)
        sdk.storeKit.currentEntitlementsLoader = { [tokenA, tokenB] in [
            fixtureTransaction("own", token: tokenA, finishes: finishes),
            fixtureTransaction("other-user", token: tokenB, finishes: finishes),
        ] }
        sdk.storeKit.unfinishedLoader = { [
            fixtureTransaction("offer-code", token: nil, finishes: finishes),
            fixtureTransaction("family", token: nil, finishes: finishes),
        ] }
        await sdk.launchBackstop()

        XCTAssertEqual(Set(server.verifies.compactMap(\.jws)), ["jws-own", "jws-offer-code", "jws-family"],
                       "another account's token is never reported automatically")
        XCTAssertTrue(server.verifies.allSatisfy { $0.header("X-CashSDK-Claim") == "sync" })
        XCTAssertEqual(finishes.finished, ["offer-code"],
                       "a tokenless purchase is finished once the server credits it to this user, and never when someone else owns it")
    }

    func testTransactionUpdatesUseSyncClaim() async throws {
        let finishes = FinishLog()
        let owner = Locked("A")
        let server = StubServer { request in
            guard request.path == "/v1/transactions:verify" else { return StubServer.Response(status: 202) }
            return owner.value == "A" ? Fixture.verified(user: "A") : Fixture.ownedByAnotherAccount
        }
        let sdk = try await identifiedSDK(server)
        await sdk.handleUpdatedTransaction(fixtureTransaction("promoted", token: nil, finishes: finishes))
        owner.value = "someone else"
        await sdk.handleUpdatedTransaction(fixtureTransaction("shared", token: nil, finishes: finishes))
        await sdk.handleUpdatedTransaction(fixtureTransaction("foreign", token: tokenB, finishes: finishes))

        XCTAssertEqual(server.verifies.compactMap(\.jws), ["jws-promoted", "jws-shared"])
        XCTAssertTrue(server.verifies.allSatisfy { $0.header("X-CashSDK-Claim") == "sync" })
        XCTAssertEqual(finishes.finished, ["promoted"])
    }

    func testPromotedPurchaseWaitsForIdentifyAndReportsAsAPurchase() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        let started = Locked<[String]>([])
        sdk.storeKit.purchaseHandler = { productId, token in
            started.withValue { $0.append(productId) }
            return .verified(fixtureTransaction("promoted", token: token, finishes: finishes))
        }
        sdk.receivePromotedPurchase(productId: "app.pro.yearly")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(started.value.isEmpty, "nobody to attribute it to yet")

        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        await eventually("the promoted purchase never ran") { finishes.finished == ["promoted"] }
        XCTAssertEqual(started.value, ["app.pro.yearly"])
        XCTAssertEqual(server.verifies.map { $0.header("X-CashSDK-Claim") }, ["purchase"])
    }
}
