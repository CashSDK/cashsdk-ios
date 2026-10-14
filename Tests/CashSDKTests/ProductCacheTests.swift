import Foundation
import XCTest
@testable import CashSDK

/// A paywall renders, the customer reads it, then taps Buy. `purchase(_:)` used to ask StoreKit
/// for the same `Product` again on that tap. StoreKit usually answers from its own cache, but a
/// cold process or a dropped cache means a network round trip between the tap and the sheet.
///
/// The cache is generic because a `Product` cannot be constructed in a test; the rules are what
/// matter, and they are the same rules the Android SDK's cache follows.
final class ProductCacheTests: XCTestCase {
    private var now: TimeInterval = 0
    private func cache() -> ProductCache<String> { ProductCache<String>(clock: { self.now }) }

    func testAStoredEntryComesBack() {
        let cache = cache()
        XCTAssertNil(cache.get("pro"))
        cache.put("pro", "details")
        XCTAssertEqual(cache.get("pro"), "details")
        XCTAssertEqual(cache.count, 1)
    }

    func testAnEntryIsUsableUpToItsTtlAndNotAfter() {
        let cache = cache()
        cache.put("pro", "details")
        now = ProductCache<String>.ttl
        XCTAssertEqual(cache.get("pro"), "details", "still inside the window")
        now = ProductCache<String>.ttl + 1
        XCTAssertNil(cache.get("pro"), "past the window")
        XCTAssertEqual(cache.count, 0, "and the expired entry is dropped, not left to grow")
    }

    /// A device clock that moved backwards must not make an entry look newer than it is.
    func testAnEntryFromTheFutureIsTreatedAsStale() {
        let cache = cache()
        now = 10_000
        cache.put("pro", "details")
        now = 0
        XCTAssertNil(cache.get("pro"))
    }

    /// The paywall asks for several products at once. A partial hit must not come back as a
    /// shorter list the caller could mistake for the whole catalog.
    func testAPartialHitIsAMiss() {
        let cache = cache()
        cache.put("pro", "a")
        XCTAssertNil(cache.get(all: ["pro", "plus"]))
        cache.put("plus", "b")
        XCTAssertEqual(cache.get(all: ["pro", "plus"]), ["a", "b"])
        XCTAssertEqual(cache.get(all: ["plus", "pro"]), ["b", "a"], "in the order asked for")
    }

    func testInvalidatingTouchesOneProduct() {
        let cache = cache()
        cache.put("pro", "a")
        cache.put("plus", "b")
        cache.invalidate("pro")
        XCTAssertNil(cache.get("pro"))
        XCTAssertEqual(cache.get("plus"), "b")
        cache.invalidate("missing")
    }

    func testClearingForgetsEverything() {
        let cache = cache()
        cache.put("pro", "a")
        cache.put("plus", "b")
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.get("pro"))
    }

    /// The manager's loader is the only thing that fills the cache, so an empty answer (no such
    /// product, or the store offline) leaves nothing behind and the next call asks again.
    func testAnEmptyAnswerDoesNotPoisonTheCache() async throws {
        let manager = StoreKitManager()
        let calls = Locked(0)
        manager.productsLoader = { _ in calls.withValue { $0 += 1 }; return [] }
        _ = try await manager.products(for: ["missing"])
        _ = try await manager.products(for: ["missing"])
        XCTAssertEqual(calls.value, 2, "nothing was cached, so both calls reached the loader")
        XCTAssertEqual(manager.productCache.count, 0)
    }

    /// `fresh` is what the paywall passes: it always reaches the store, even when everything
    /// asked for is cached, because the customer is about to read those prices.
    func testFreshAlwaysReachesTheStore() async throws {
        let manager = StoreKitManager()
        let calls = Locked(0)
        manager.productsLoader = { _ in calls.withValue { $0 += 1 }; return [] }
        _ = try await manager.products(for: ["pro"], fresh: true)
        _ = try await manager.products(for: ["pro"], fresh: true)
        XCTAssertEqual(calls.value, 2)
    }

    /// The public `CashSDK.products(for:)` is the same lookup the Buy tap reads, so an app that
    /// loads its plans through it (rather than `Product.products(for:)` directly) has the
    /// `Product` cached for `purchase(_:)`. It needs no `configure`: StoreKit is local.
    func testThePublicProductLookupGoesThroughTheSharedCache() async throws {
        let sdk = CashSDK(session: StubServer().session(), automaticRecovery: false, store: temporaryStore(), purchaseLog: temporaryPurchaseLog(), eventQueue: temporaryEventQueue())
        let asked = Locked<[[String]]>([])
        sdk.storeKit.productsLoader = { ids in asked.withValue { $0.append(ids) }; return [] }
        let products = try await sdk.products(for: ["pro", "plus"])
        XCTAssertEqual(products.count, 0, "the store knew neither id, so neither comes back")
        _ = try await sdk.products(for: ["pro", "plus"], fresh: true)
        XCTAssertEqual(asked.value, [["pro", "plus"], ["pro", "plus"]])
    }
}
