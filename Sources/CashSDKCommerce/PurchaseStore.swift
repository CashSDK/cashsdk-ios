import Foundation

/// Where `purchase` keeps its attempts: one idempotency key, and once known the checkout id,
/// per customer and package. A value is a short JSON string with no credentials in it.
public protocol CommercePurchaseStore: Sendable {
    func value(forKey key: String) -> String?
    /// Throw when the value could not be kept: nothing is then sent.
    func set(_ value: String, forKey key: String) throws
    func remove(_ key: String)
}

/// The default store: UserDefaults, so an attempt survives a relaunch of the app.
public struct UserDefaultsPurchaseStore: CommercePurchaseStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func value(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String, forKey key: String) throws { defaults.set(value, forKey: key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: key) }
}

/// One purchase attempt as it is stored.
struct PurchaseAttempt: Codable, Equatable {
    let key: String
    var id: String?

    /// Nil for a value that is not one of ours.
    init?(stored: String?) {
        guard let data = stored?.data(using: .utf8),
              let value = try? JSONDecoder().decode(PurchaseAttempt.self, from: data),
              value.key.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil,
              value.id.map({ $0.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil }) ?? true
        else { return nil }
        self = value
    }
    init(key: String, id: String? = nil) {
        self.key = key
        self.id = id
    }
    var stored: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

/// Refusals that end an attempt: the customer already has the plan or the product, or a
/// payment for it already went through. A new attempt needs a new key.
let finalPurchaseRefusals: Set<String> = ["already_subscribed", "already_owned", "already_purchased"]
