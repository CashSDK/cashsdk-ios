import Foundation
import XCTest
@testable import CashSDK

/// Apps had no way to ask whether the Apple ID can still get a product's introductory offer,
/// so returning subscribers were shown "free trial" copy the App Store would not honour.
final class IntroOfferTests: XCTestCase {

    func testEligibilityComesFromStoreKit() async throws {
        let sdk = CashSDK(session: StubServer().session(), automaticRecovery: false, store: temporaryStore(), purchaseLog: temporaryPurchaseLog(), eventQueue: temporaryEventQueue())
        let asked = Locked<[String]>([])
        sdk.storeKit.introEligibilityHandler = { productId in
            asked.withValue { $0.append(productId) }
            return productId == "app.pro.yearly"
        }
        let yearly = try await sdk.isEligibleForIntroOffer("app.pro.yearly")
        let monthly = try await sdk.isEligibleForIntroOffer("app.pro.monthly")
        XCTAssertTrue(yearly)
        XCTAssertFalse(monthly)
        XCTAssertEqual(asked.value, ["app.pro.yearly", "app.pro.monthly"])
    }

    func testUnknownProductThrows() async {
        let sdk = CashSDK(session: StubServer().session(), automaticRecovery: false, store: temporaryStore(), purchaseLog: temporaryPurchaseLog(), eventQueue: temporaryEventQueue())
        sdk.storeKit.productsLoader = { _ in [] }
        do {
            _ = try await sdk.isEligibleForIntroOffer("app.pro.missing")
            XCTFail("no such product")
        } catch CashSDKError.productNotFound(let id) {
            XCTAssertEqual(id, "app.pro.missing")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNoProductsMeansNoTrialWording() async {
        let eligible = await StoreKitManager().introOfferEligibleIds([])
        XCTAssertTrue(eligible.isEmpty)
    }

    func testIntroOfferWording() {
        XCTAssertEqual(
            IntroOfferText.text(mode: .freeTrial, offerPrice: "$0.00", periodValue: 1, periodUnit: .week, periodCount: 1,
                                regularPrice: "$9.99", regularPeriodValue: 1, regularPeriodUnit: .month),
            "Free for 1 week, then $9.99 / month")
        XCTAssertEqual(
            IntroOfferText.text(mode: .freeTrial, offerPrice: "$0.00", periodValue: 3, periodUnit: .day, periodCount: 1,
                                regularPrice: "$49.99", regularPeriodValue: 1, regularPeriodUnit: .year),
            "Free for 3 days, then $49.99 / year")
        XCTAssertEqual(
            IntroOfferText.text(mode: .payAsYouGo, offerPrice: "$0.99", periodValue: 1, periodUnit: .month, periodCount: 3,
                                regularPrice: "$9.99", regularPeriodValue: 1, regularPeriodUnit: .month),
            "$0.99 / month for 3 months, then $9.99 / month")
        XCTAssertEqual(
            IntroOfferText.text(mode: .payUpFront, offerPrice: "$1.99", periodValue: 3, periodUnit: .month, periodCount: 1,
                                regularPrice: "$29.99", regularPeriodValue: 6, regularPeriodUnit: .month),
            "$1.99 for 3 months, then $29.99 / 6 months")
    }

    /// Every trial length and billing cadence a merchant can configure in App Store Connect,
    /// because the wording is generated, not chosen from a list: a 1-day trial on a 2-week plan
    /// has to read correctly the first time someone sets one up, with no change here.
    func testEveryTrialLengthAndCadence() {
        let cases: [(Int, IntroOfferText.Unit, Int, IntroOfferText.Unit, String)] = [
            (1, .day, 1, .week, "Free for 1 day, then $4.99 / week"),
            (3, .day, 1, .month, "Free for 3 days, then $4.99 / month"),
            (7, .day, 2, .week, "Free for 7 days, then $4.99 / 2 weeks"),
            (1, .week, 2, .week, "Free for 1 week, then $4.99 / 2 weeks"),
            (2, .week, 1, .month, "Free for 2 weeks, then $4.99 / month"),
            (1, .month, 3, .month, "Free for 1 month, then $4.99 / 3 months"),
            (2, .month, 6, .month, "Free for 2 months, then $4.99 / 6 months"),
            (1, .month, 1, .year, "Free for 1 month, then $4.99 / year"),
        ]
        for (value, unit, regularValue, regularUnit, want) in cases {
            XCTAssertEqual(
                IntroOfferText.text(mode: .freeTrial, offerPrice: "$0.00", periodValue: value, periodUnit: unit,
                                    periodCount: 1, regularPrice: "$4.99",
                                    regularPeriodValue: regularValue, regularPeriodUnit: regularUnit),
                want)
        }
    }

    /// StoreKit reports a multi-period offer as one period repeated `periodCount` times, so the
    /// length a merchant configured is the product of the two.
    func testPeriodCountMultipliesTheLength() {
        XCTAssertEqual(
            IntroOfferText.text(mode: .freeTrial, offerPrice: "$0.00", periodValue: 1, periodUnit: .week, periodCount: 2,
                                regularPrice: "$9.99", regularPeriodValue: 1, regularPeriodUnit: .month),
            "Free for 2 weeks, then $9.99 / month")
        XCTAssertEqual(
            IntroOfferText.text(mode: .payAsYouGo, offerPrice: "$0.99", periodValue: 1, periodUnit: .month, periodCount: 6,
                                regularPrice: "$9.99", regularPeriodValue: 1, regularPeriodUnit: .month),
            "$0.99 / month for 6 months, then $9.99 / month")
    }
}
