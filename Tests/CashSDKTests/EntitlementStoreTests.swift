import XCTest
@testable import CashSDK

/// The disk cache is what a relaunch serves before any network call completes, so an unowned
/// or mis-owned record is a cross-user entitlement leak: on a shared device user B was served
/// user A's Pro entitlements and coin balances, indefinitely if B's refresh failed.
final class EntitlementStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cashsdk-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeStore() -> EntitlementStore {
        EntitlementStore(fileURL: fileURL)
    }

    private let pro = Entitlements(
        entitlements: [Entitlement(identifier: "pro", name: "Pro", rank: 10, source: "subscription")],
        tier: 10,
        tierIdentifier: "pro",
        consumables: [ConsumableBalance(productIdentifier: "coins", balance: 250)]
    )

    func testOwnerRoundTripsWithItsETag() async {
        let store = makeStore()
        let wrote = await store.update(pro, owner: "userA", environment: "Production", etag: "W/\"abc\"")
        XCTAssertTrue(wrote)

        let reloaded = await makeStore().load(for: "userA", environment: "Production")
        XCTAssertEqual(reloaded.entitlements, pro)
        XCTAssertEqual(reloaded.etag, "W/\"abc\"")
    }

    func testDifferentUserGetsNothing() async {
        let store = makeStore()
        await store.update(pro, owner: "userA", environment: "Production", etag: "W/\"abc\"")

        // A fresh process: `identify("userB")` has no in-memory previous user to compare against,
        // which is exactly the case that used to leak.
        let asB = await makeStore().load(for: "userB", environment: "Production")
        XCTAssertEqual(asB, .empty)
        XCTAssertNil(asB.etag, "an ETag must never outlive the snapshot it describes")
    }

    func testLoggedOutSessionGetsNothing() async {
        let store = makeStore()
        await store.update(pro, owner: "userA", environment: "Production", etag: "W/\"abc\"")

        let anonymous = await makeStore().load(for: nil, environment: "Production")
        XCTAssertEqual(anonymous, .empty)
    }

    func testMismatchedOwnerIsAlsoErasedFromDisk() async {
        let store = makeStore()
        await store.update(pro, owner: "userA", environment: "Production", etag: "W/\"abc\"")
        _ = await makeStore().load(for: "userB", environment: "Production")

        // Even user A does not get it back: the record was discarded, not just withheld.
        let asA = await makeStore().load(for: "userA", environment: "Production")
        XCTAssertEqual(asA, .empty)
    }

    func testSandboxSnapshotIsNotServedToProduction() async {
        let store = makeStore()
        await store.update(pro, owner: "userA", environment: "Sandbox", etag: "W/\"abc\"")

        let production = await makeStore().load(for: "userA", environment: "Production")
        XCTAssertEqual(production, .empty)
    }

    func testFailedWriteIsReported() async {
        // An unwritable location: the caller must learn the snapshot did not persist so it can
        // drop the ETag rather than 304 forever against a cache it doesn't have.
        let store = EntitlementStore(fileURL: URL(fileURLWithPath: "/dev/null/nope/entitlements.json"))
        let wrote = await store.update(pro, owner: "userA", environment: nil, etag: "W/\"abc\"")
        XCTAssertFalse(wrote)
    }

    func testClearRemovesEverything() async {
        let store = makeStore()
        await store.update(pro, owner: "userA", environment: nil, etag: "W/\"abc\"")
        await store.clear()

        let reloaded = await makeStore().load(for: "userA", environment: nil)
        XCTAssertEqual(reloaded, .empty)
    }
}
