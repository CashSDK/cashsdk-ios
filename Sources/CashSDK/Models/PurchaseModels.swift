import Foundation

// MARK: - Purchase result

/// The outcome of ``CashSDK/purchase(_:)``.
public enum PurchaseResult: Sendable {
    /// Purchase verified and applied; carries the fresh entitlement snapshot.
    case success(Entitlements)
    /// Deferred (Ask-to-Buy / SCA). No grant yet; resolution arrives via the updates stream.
    case pending
    /// The user dismissed the purchase sheet.
    case userCancelled
}

// MARK: - Consumable spend

/// `POST /v1/consumables:spend` response.
public struct ConsumableSpendResult: Decodable, Sendable {
    /// The balance AFTER the spend.
    public let balance: Int
    /// `false` when this exact `idempotencyKey` had already been applied — the balance
    /// is authoritative either way, and the caller must NOT retry as a new spend.
    public let applied: Bool
}

// MARK: - Wire DTOs (internal)

/// `POST /v1/transactions:verify` request body.
struct VerifyRequest: Encodable {
    let signedTransaction: String
}

/// `POST /v1/consumables:spend` request body.
struct SpendRequest: Encodable {
    let productIdentifier: String
    let units: Int
    let idempotencyKey: String
    let note: String?
}
