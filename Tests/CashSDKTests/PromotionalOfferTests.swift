import Foundation
import StoreKit
import XCTest
@testable import CashSDK

/// Promotional offers (2.4.0). The merchant's server signs the offer for the purchase's app
/// account token; the SDK passes it to the payment sheet beside that token and treats the App
/// Store's refusals of an offer as refusals before any charge.
final class PromotionalOfferTests: XCTestCase {
    private let tokenA = AppAccountToken.appAccountToken(for: "A")!

    private let offer = PromotionalOfferSignature(
        offerId: "plus_monthly_50off_retention",
        keyId: "ABCDE12345",
        nonce: UUID(uuidString: "6F3C7C2E-8E7A-4C0B-9C5B-1B2B3C4D5E6F")!,
        signature: Data([0x30, 0x45, 0x02, 0x20]),
        timestamp: 1_791_990_000_000
    )

    private func claims(_ server: StubServer) -> [String?] {
        server.verifies.map { $0.header("X-CashSDK-Claim") }
    }

    func testOfferReachesTheSheetBesideTheBuyersToken() async throws {
        let finishes = FinishLog()
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let seenOffer = Locked<PromotionalOfferSignature?>(nil)
        let seenToken = Locked<UUID?>(nil)
        sdk.storeKit.promotionalOfferRecorder = { seenOffer.value = $0 }
        sdk.storeKit.purchaseHandler = { _, token in
            seenToken.value = token
            return .verified(fixtureTransaction("discounted", token: token, finishes: finishes))
        }

        let result = try await sdk.purchase("app.pro.monthly", promotionalOffer: offer)

        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(seenOffer.value, offer)
        XCTAssertEqual(seenToken.value, tokenA, "Apple checks the signature against this token")
        XCTAssertEqual(claims(server), ["purchase"])
        XCTAssertEqual(finishes.finished, ["discounted"])
    }

    func testOrdinaryPurchaseCarriesNoOffer() async throws {
        let server = StubServer { request in
            request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
        }
        let sdk = makeSDK(server)
        _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
        let calls = Locked(0)
        let seenOffer = Locked<PromotionalOfferSignature?>(offer)
        sdk.storeKit.promotionalOfferRecorder = { seenOffer.value = $0; calls.value += 1 }
        sdk.storeKit.purchaseHandler = { _, token in .verified(fixtureTransaction("plain", token: token, finishes: FinishLog())) }

        _ = try await sdk.purchase("app.pro.monthly")

        XCTAssertEqual(calls.value, 1)
        XCTAssertNil(seenOffer.value)
    }

    func testOfferRejectionIsARefusalBeforeAnyCharge() async throws {
        let rejections: [Product.PurchaseError] = [
            .invalidOfferSignature, .invalidOfferIdentifier, .invalidOfferPrice, .missingOfferParameters, .ineligibleForOffer,
        ]
        for rejection in rejections {
            let finishes = FinishLog()
            let server = StubServer { request in
                request.path == "/v1/transactions:verify" ? Fixture.verified(user: "A") : StubServer.Response(status: 202)
            }
            let sdk = makeSDK(server)
            _ = try await sdk.identifyAndWait(userId: "A", userToken: fixtureToken("A"))
            sdk.storeKit.purchaseHandler = { productId, _ in
                throw StoreKitManager.purchaseError(rejection, productId: productId)
            }
            do {
                _ = try await sdk.purchase("app.pro.monthly", promotionalOffer: offer)
                XCTFail("\(rejection) must throw")
            } catch let error as CashSDKError {
                XCTAssertTrue(error.isPromotionalOfferRejection, "\(rejection)")
                guard case .storeKitFailed(let underlying) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(underlying as? Product.PurchaseError, rejection)
            }
            // Refused before a charge, so the attempt was dropped: a later purchase of the same
            // product on another device is not this device's purchase.
            await sdk.handleUpdatedTransaction(fixtureTransaction("elsewhere", token: tokenA, finishes: finishes))
            XCTAssertEqual(claims(server), ["sync"], "\(rejection)")
        }
    }

    func testOtherStoreKitFailuresAreNotOfferRejections() {
        XCTAssertFalse(CashSDKError.storeKitFailed(underlying: nil).isPromotionalOfferRejection)
        XCTAssertFalse(CashSDKError.storeKitFailed(underlying: Product.PurchaseError.invalidQuantity).isPromotionalOfferRejection)
        XCTAssertFalse(CashSDKError.storeKitFailed(underlying: StoreKitError.unknown).isPromotionalOfferRejection)
        XCTAssertFalse(CashSDKError.purchaseNotAllowed.isPromotionalOfferRejection)
    }

    func testObserverModeRefusesAnOfferPurchase() async throws {
        let server = StubServer()
        let sdk = makeSDK(server)
        sdk.configure(with: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: server.baseURL, environment: "Production", observerMode: true))
        do {
            _ = try await sdk.purchase("app.pro.monthly", promotionalOffer: offer)
            XCTFail("observer mode never purchases")
        } catch CashSDKError.observerMode {}
    }

    func testPublicAppAccountTokenIsTheCanonicalDerivation() {
        XCTAssertEqual(CashSDK.appAccountToken(for: "4211"), UUID(uuidString: "00000000-0000-4000-8000-000000001073"))
        XCTAssertEqual(CashSDK.appAccountToken(for: "88"), AppAccountToken.appAccountToken(for: "88"))
        XCTAssertEqual(CashSDK.appAccountToken(for: "user_7f3a"), AppAccountToken.appAccountToken(for: "user_7f3a"))
    }

    func testBase64SignatureInitializer() {
        let parsed = PromotionalOfferSignature(offerId: "o", keyId: "K", nonce: offer.nonce, base64Signature: "MEUCIA==", timestamp: 1)
        XCTAssertEqual(parsed?.signature, Data([0x30, 0x45, 0x02, 0x20]))
        XCTAssertNil(PromotionalOfferSignature(offerId: "o", keyId: "K", nonce: offer.nonce, base64Signature: "not base64!", timestamp: 1))
        XCTAssertNil(PromotionalOfferSignature(offerId: "o", keyId: "K", nonce: offer.nonce, base64Signature: "", timestamp: 1))
    }
}
