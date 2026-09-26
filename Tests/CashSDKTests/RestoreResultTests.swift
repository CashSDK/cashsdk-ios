import Foundation
import StoreKit
import XCTest
@testable import CashSDK

/// `restore()` returned nothing, so "nothing to restore" looked like success, and an ownership
/// conflict arrived wrapped in `restoreVerificationFailed`, which the paywall read as a
/// connection problem.
final class RestoreResultTests: XCTestCase {
    private let tokenA = AppAccountToken.appAccountToken(for: "A")

    private func restoringSDK(_ server: StubServer, current: [StoreTransaction], unfinished: [StoreTransaction] = []) async throws -> CashSDK {
        let sdk = makeSDK(server)
        sdk.storeKit.syncHandler = {}
        sdk.storeKit.currentEntitlementsLoader = { current }
        sdk.storeKit.unfinishedLoader = { unfinished }
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        return sdk
    }

    func testRestoreCountsConfirmedTransferredAndOwnedElsewhere() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            switch request.jws {
            case "jws-mine": return Fixture.verified(user: "A")
            case "jws-moved": return Fixture.verified(user: "A", transferred: true)
            case "jws-theirs": return Fixture.ownedByAnotherAccount
            default: return request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A") : StubServer.Response(status: 202)
            }
        }
        let sdk = try await restoringSDK(server, current: [
            fixtureTransaction("mine", token: tokenA, finishes: finishes),
            fixtureTransaction("moved", token: nil, finishes: finishes),
            fixtureTransaction("theirs", token: UUID(), finishes: finishes),
        ])
        let result = try await sdk.restoreDetailed()
        XCTAssertEqual(result.restoredCount, 2)
        XCTAssertEqual(result.transferredCount, 1)
        XCTAssertTrue(result.transferredFromAnotherAccount)
        XCTAssertEqual(result.ownedByAnotherAccountCount, 1)
        XCTAssertEqual(result.outcome, .restored)
        XCTAssertTrue(result.entitlements.isActive("pro"))
        XCTAssertEqual(server.verifies.count, 3)
        XCTAssertTrue(server.verifies.allSatisfy { $0.header("X-CashSDK-Claim") == "restore" },
                      "an explicit restore is the only automatic-looking report allowed to move ownership")
        XCTAssertNil(PaywallFeedback.restoreFinished(result), "access came back, so the paywall closes")
        // `restore()` returns the same result when anything was restored.
        let plain = try await sdk.restore()
        XCTAssertEqual(plain.outcome, .restored)
    }

    func testPurchasesKeptByAnotherAccountAreAResultNotAConnectionError() async throws {
        let server = StubServer { request in
            if request.path == "/v1/transactions:verify" { return Fixture.ownedByAnotherAccount }
            return request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A", [], tier: 0) : StubServer.Response(status: 202)
        }
        let finishes = FinishLog()
        let sdk = try await restoringSDK(server, current: [], unfinished: [fixtureTransaction("theirs", token: nil, finishes: finishes)])

        let result = try await sdk.restoreDetailed()
        XCTAssertEqual(result.outcome, .ownedByAnotherAccount)
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.ownedByAnotherAccountCount, 1)
        XCTAssertTrue(finishes.finished.isEmpty, "another account's purchase is never finished here")
        let shown = try XCTUnwrap(PaywallFeedback.restoreFinished(result))
        XCTAssertTrue(shown.message.contains("another account"))

        // Existing callers of restore() still get the error they were told to inspect...
        do {
            _ = try await sdk.restore()
            XCTFail("restore() keeps throwing for the all-other-account case")
        } catch CashSDKError.restoreVerificationFailed(let underlying) {
            guard case CashSDKError.purchaseBelongsToAnotherAccount = underlying else { return XCTFail("\(underlying)") }
            // ...and the paywall unwraps it instead of blaming the connection.
            let feedback = try XCTUnwrap(PaywallFeedback.failure(CashSDKError.restoreVerificationFailed(underlying: underlying), restoring: true))
            XCTAssertTrue(feedback.message.contains("another app account"), feedback.message)
            XCTAssertFalse(feedback.message.contains("connection"))
        }
    }

    func testNothingToRestoreIsDistinguishable() async throws {
        let server = StubServer { request in
            request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A", [], tier: 0) : StubServer.Response(status: 202)
        }
        let sdk = try await restoringSDK(server, current: [])
        let result = try await sdk.restore()
        XCTAssertEqual(result.outcome, .nothingToRestore)
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertTrue(server.verifies.isEmpty)
        XCTAssertEqual(PaywallFeedback.restoreFinished(result)?.title, PaywallFeedback.nothingToRestore.title)
    }

    func testUnfinishedTransactionsAreFinishedOnlyOnceConfirmed() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            switch request.jws {
            case "jws-both", "jws-coins": return Fixture.verified(user: "A")
            case "jws-theirs": return Fixture.ownedByAnotherAccount
            default: return request.path == "/v1/entitlements" ? Fixture.entitlements(user: "A") : StubServer.Response(status: 202)
            }
        }
        let both = fixtureTransaction("both", token: tokenA, finishes: finishes)
        let sdk = try await restoringSDK(server, current: [both], unfinished: [
            both,
            fixtureTransaction("coins", token: tokenA, finishes: finishes),
            fixtureTransaction("theirs", token: UUID(), finishes: finishes),
        ])
        let result = try await sdk.restoreDetailed()
        XCTAssertEqual(Set(finishes.finished), ["both", "coins"])
        XCTAssertEqual(server.verifies.filter { $0.jws == "jws-both" }.count, 1, "reported once per pass, then finished")
        XCTAssertEqual(result.restoredCount, 2)
        XCTAssertEqual(result.ownedByAnotherAccountCount, 1)
    }

    func testRestoreThatCouldNotVerifyThrowsAndFinishesNothing() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? StubServer.Response(status: 500) : StubServer.Response(status: 202)
        }
        let sdk = try await restoringSDK(server, current: [], unfinished: [fixtureTransaction("coins", token: tokenA, finishes: finishes)])
        do {
            _ = try await sdk.restoreDetailed()
            XCTFail("a failed verify is not a completed restore")
        } catch CashSDKError.restoreVerificationFailed(let underlying) {
            guard case CashSDKError.server(500, _, _) = underlying else { return XCTFail("\(underlying)") }
        }
        XCTAssertTrue(finishes.finished.isEmpty)
        XCTAssertEqual(server.verifies.count, 3, "transient failures are retried in flight")
    }

    func testCancelledAppStoreSignInIsNotAFailure() async throws {
        let server = StubServer()
        let sdk = makeSDK(server)
        sdk.storeKit.syncHandler = { throw StoreKitManager.syncError(StoreKitError.userCancelled) }
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        do {
            _ = try await sdk.restoreDetailed()
            XCTFail("cancelled")
        } catch CashSDKError.purchaseCancelled {
            XCTAssertNil(PaywallFeedback.failure(CashSDKError.purchaseCancelled, restoring: true))
        }
    }
}
