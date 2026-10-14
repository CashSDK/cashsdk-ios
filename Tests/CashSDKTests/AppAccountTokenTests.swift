import XCTest
@testable import CashSDK

/// Golden vectors for the canonical `appAccountToken`. These MUST match the server
/// (`apps/api test/app-account-token.test.ts`) and the Android SDK
/// (`AppAccountTokenTest.kt`) byte-for-byte, or a purchase's token won't match the AppUser row
/// and attribution silently misses.
final class AppAccountTokenTests: XCTestCase {

    private func hex(_ userId: String) -> String {
        AppAccountToken.appAccountToken(for: userId)?.uuidString.lowercased() ?? "nil"
    }

    func testCanonicalShape() {
        XCTAssertNotNil(hex("1").range(of: #"^00000000-0000-4000-8000-[0-9a-f]{12}$"#, options: .regularExpression))
    }

    func testNumericIdsEmbedTheId() {
        XCTAssertEqual(hex("1"), "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(hex("123"), "00000000-0000-4000-8000-00000000007b")
        XCTAssertEqual(hex("1000000"), "00000000-0000-4000-8000-0000000f4240")
        XCTAssertEqual(hex("42"), "00000000-0000-4000-8000-00000000002a")
    }

    func testOpaqueIdsUseFNV() {
        XCTAssertEqual(hex("user_abc"), "00000000-0000-4000-8000-e33fe1b269b9")
        XCTAssertEqual(hex("u_9f3a"), "00000000-0000-4000-8000-1af6ca2ab142")
        XCTAssertEqual(hex("anon-xyz"), "00000000-0000-4000-8000-1a0e23dd7369")
    }

    func testLeadingSignFallsToFNV() {
        XCTAssertEqual(hex("+123"), "00000000-0000-4000-8000-69c0cff2262e")
        XCTAssertEqual(hex("+15551234567"), "00000000-0000-4000-8000-129949cbd436")
        XCTAssertEqual(hex("-5"), "00000000-0000-4000-8000-0f07b497d7f7")
    }

    /// DOCUMENTED CONSTRAINT, not a bug to "fix" here — see ``AppAccountToken``.
    ///
    /// The numeric branch embeds the VALUE of the id, so `"7"`, `"07"` and `"007"` all derive the
    /// same token, identically on the server, on iOS and on Android. A backend that emits
    /// zero-padded ids therefore merges two users' purchases. Correcting it on one platform would
    /// break the byte-parity the whole scheme rests on; the fix belongs in the integrator's id.
    func testZeroPaddedNumericIdsCollide() {
        XCTAssertEqual(hex("7"), hex("007"))
        XCTAssertEqual(hex("42"), hex("0000042"))
        // A non-digit prefix forces the FNV branch, which IS sensitive to leading zeros.
        XCTAssertNotEqual(hex("u7"), hex("u007"))
    }
}
