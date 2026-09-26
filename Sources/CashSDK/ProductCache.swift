import Foundation

/// The `Product`s StoreKit last returned, for the seconds between a paywall rendering and the
/// customer tapping Buy.
///
/// `purchase(_:)` cannot open the payment sheet without a `Product`, and it used to ask StoreKit
/// for it again on every tap even though the paywall had just fetched the same product to show
/// its price. StoreKit usually answers that from its own on-device cache, but not always: a cold
/// process, a storefront change or a cache StoreKit decided to drop all mean a network round trip
/// between the tap and the sheet, and a customer reads that as the app being broken.
///
/// Short on purpose. Products can be pulled from sale or repriced, and the TTL bounds how long a
/// stale one is offered; a purchase against one fails at the sheet with `productUnavailable`,
/// which is the same answer a fresh lookup would have given a moment later. Generic over the
/// value so the rules are testable without StoreKit, which cannot construct a `Product` in a test.
final class ProductCache<Value>: @unchecked Sendable {
    /// How long a cached product may be used for. Mirrors the Android SDK.
    static var ttl: TimeInterval { 5 * 60 }

    private struct Entry {
        let value: Value
        let storedAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: () -> TimeInterval

    /// `clock` should be monotonic. The default is process uptime, so a device clock that moves
    /// cannot lengthen an entry's life.
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// The cached value for `id`, or nil when absent or older than ``ttl``.
    func get(_ id: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id] else { return nil }
        let age = clock() - entry.storedAt
        // A clock that ran backwards makes `age` negative: treat that as stale rather than trust
        // an entry we cannot date.
        if age < 0 || age > Self.ttl {
            entries[id] = nil
            return nil
        }
        return entry.value
    }

    /// Every id present and fresh, in the order asked for; nil if any is missing, so a caller
    /// never gets a partial answer it might mistake for "these are all the products".
    func get(all ids: [String]) -> [Value]? {
        var out: [Value] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let value = get(id) else { return nil }
            out.append(value)
        }
        return out
    }

    func put(_ id: String, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = Entry(value: value, storedAt: clock())
    }

    /// Forget one product: it was refused at the sheet, or its price is being re-read.
    func invalidate(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = nil
    }

    /// Forget everything: the storefront changed, so every price and availability may have.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
