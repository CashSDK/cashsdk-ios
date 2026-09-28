import XCTest
@testable import CashSDK

/// The learned store environment must survive a relaunch.
///
/// Consumables are excluded from StoreKit's `currentEntitlements`, so a tester whose only
/// purchases are coin packs re-reports nothing on the next launch and the SDK would forget it
/// is in Sandbox. Balances are per environment server-side, so that forgetting reads back as
/// "my coins are gone" after every relaunch. `CashSDK.shared` is a singleton, so these tests
/// drive `configure` directly and read the internal accessor rather than the API client.
final class EnvironmentPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: CashSDK.observedEnvironmentKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: CashSDK.observedEnvironmentKey)
        super.tearDown()
    }

    func testARememberedEnvironmentIsRestoredOnConfigure() {
        UserDefaults.standard.set("Sandbox", forKey: CashSDK.observedEnvironmentKey)
        CashSDK.configure(publishableKey: "csk_pk_testEnvPersist0000000001")
        XCTAssertEqual(
            CashSDK.shared.effectiveStoreEnvironment,
            "Sandbox",
            "a relaunch must start in the environment the previous run learned"
        )
    }

    func testAPinnedEnvironmentBeatsWhatWasRemembered() {
        UserDefaults.standard.set("Sandbox", forKey: CashSDK.observedEnvironmentKey)
        CashSDK.configure(publishableKey: "csk_pk_testEnvPersist0000000002", environment: "Production")
        XCTAssertEqual(
            CashSDK.shared.effectiveStoreEnvironment,
            "Production",
            "a host that pinned the environment asked to be explicit; the pin always wins"
        )
    }

    func testGarbageOnDiskIsIgnored() {
        UserDefaults.standard.set("Staging", forKey: CashSDK.observedEnvironmentKey)
        CashSDK.configure(publishableKey: "csk_pk_testEnvPersist0000000003")
        XCTAssertNil(
            CashSDK.shared.effectiveStoreEnvironment,
            "only the two values the API compares against may be restored"
        )
    }
}
