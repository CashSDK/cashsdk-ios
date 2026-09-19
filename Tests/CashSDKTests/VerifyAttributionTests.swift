import XCTest
@testable import CashSDK

/// `POST /v1/transactions:verify` answers `200` whether or not it could credit the purchase to a
/// user. Treating the unattributed answer as success both wiped a good cache and let the caller
/// `finish()` the transaction — a promoted IAP (which carries no `appAccountToken`) was charged,
/// discarded, and credited to nobody.
///
/// Bodies here are copied from `apps/api` (`VerifyController.verifyTransaction`), not invented.
final class VerifyAttributionTests: XCTestCase {

    private func decode(_ json: String) throws -> (Data, Entitlements) {
        let data = Data(json.utf8)
        return (data, try JSONDecoder().decode(Entitlements.self, from: data))
    }

    func testUnattributedEmptyResponseIsDetected() throws {
        // The exact early-return when lifecycle could not resolve a user.
        let (data, decoded) = try decode(#"{"entitlements":[],"tier":0,"tierIdentifier":null}"#)
        XCTAssertFalse(APIClient.isAttributed(data, decoded: decoded))
    }

    func testAttributedEmptyResponseIsNotMistakenForUnattributed() throws {
        // A real user who simply holds nothing — the `consumables` array is always present.
        let (data, decoded) = try decode(
            #"{"entitlements":[],"tier":0,"tierIdentifier":null,"consumables":[]}"#
        )
        XCTAssertTrue(APIClient.isAttributed(data, decoded: decoded))
    }

    func testGrantedResponseIsAttributed() throws {
        let (data, decoded) = try decode(#"""
        {"entitlements":[{"identifier":"pro","name":"Pro","rank":10,"source":"subscription"}],
         "tier":10,"tierIdentifier":"pro","consumables":[{"productIdentifier":"coins","balance":50}]}
        """#)
        XCTAssertTrue(APIClient.isAttributed(data, decoded: decoded))
        XCTAssertEqual(decoded.balance(of: "coins"), 50)
    }

    func testExplicitServerSignalWins() throws {
        // Once the API returns an explicit flag (see the SDK handoff note) it is authoritative,
        // even against a body that otherwise looks fully attributed.
        let (yes, decodedYes) = try decode(
            #"{"entitlements":[],"tier":0,"tierIdentifier":null,"attributed":true}"#
        )
        XCTAssertTrue(APIClient.isAttributed(yes, decoded: decodedYes))

        let (no, decodedNo) = try decode(
            #"{"entitlements":[],"tier":0,"tierIdentifier":null,"consumables":[],"attributed":false}"#
        )
        XCTAssertFalse(APIClient.isAttributed(no, decoded: decodedNo))
    }

    func testUnparseableBodyIsAssumedAttributed() {
        // Failing open strands nothing; failing closed would reject a real purchase.
        XCTAssertTrue(APIClient.isAttributed(Data("not json".utf8), decoded: .empty))
    }

    func testNonEmptyEntitlementsWithoutConsumablesAreAttributed() throws {
        // An older server build, or a shape change: entitlements can only exist for a user.
        let (data, decoded) = try decode(#"""
        {"entitlements":[{"identifier":"pro","name":"Pro"}],"tier":1,"tierIdentifier":"pro"}
        """#)
        XCTAssertTrue(APIClient.isAttributed(data, decoded: decoded))
    }
}
