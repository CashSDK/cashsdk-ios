import Foundation

// MARK: - Purchase result

/// The outcome of ``CashSDK/purchase(_:)``.
public enum PurchaseResult: Sendable {
    /// Purchase verified and applied; carries the fresh entitlement snapshot. When
    /// `transferredFromAnotherAccount` is `true` on it, the server moved this purchase to the
    /// signed-in account from another account in this app (restore policy `transfer`). Tell the
    /// user, since the other account no longer has it.
    case success(Entitlements)
    /// Deferred (Ask-to-Buy / SCA). No grant yet; resolution arrives via the updates stream.
    case pending
    /// The user dismissed the purchase sheet.
    case userCancelled
    /// Xcode's local StoreKit fixture completed. No server verification or access grant.
    case localStoreKit
}

// MARK: - Restore result

/// What ``CashSDK/restoreDetailed()`` (and ``CashSDK/restore()``) found. Counts are of store
/// transactions reported during the restore.
public struct RestoreResult: Sendable, Equatable {
    /// How the restore ended, for choosing what to tell the user.
    public enum Outcome: Sendable, Equatable {
        /// The server confirmed at least one purchase for the signed-in account.
        case restored
        /// The App Store holds nothing for this Apple ID that CashSDK could report.
        case nothingToRestore
        /// Every purchase found stays with another account in this app under the app's restore
        /// policy. The user should sign in to that account.
        case ownedByAnotherAccount
    }

    /// Purchases the server confirmed for the signed-in account.
    public let restoredCount: Int
    /// Purchases on this Apple ID that stay with another account in this app.
    public let ownedByAnotherAccountCount: Int
    /// Purchases this restore moved to the signed-in account from another account in this app
    /// (restore policy `transfer`). Included in ``restoredCount``.
    public let transferredCount: Int
    /// Access after the restore, re-read from the server.
    public let entitlements: Entitlements

    public init(restoredCount: Int, ownedByAnotherAccountCount: Int, transferredCount: Int, entitlements: Entitlements) {
        self.restoredCount = restoredCount
        self.ownedByAnotherAccountCount = ownedByAnotherAccountCount
        self.transferredCount = transferredCount
        self.entitlements = entitlements
    }

    public var outcome: Outcome {
        if restoredCount > 0 { return .restored }
        if ownedByAnotherAccountCount > 0 { return .ownedByAnotherAccount }
        return .nothingToRestore
    }

    /// `true` when at least one purchase moved here from another account. Tell the user.
    public var transferredFromAnotherAccount: Bool { transferredCount > 0 }
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

/// Why a transaction is being reported, sent as `X-CashSDK-Claim` on every verify.
///
/// The server lets only `purchase` and `restore` move a purchase between app accounts, and
/// only under the app's restore policy. `sync` never changes ownership; it may still attribute
/// a purchase that nobody owns yet.
enum VerifyClaim: String, Sendable {
    /// Right after the user bought in this app (including a promoted purchase).
    case purchase
    /// The user asked to restore purchases.
    case restore
    /// Anything automatic: `Transaction.updates`, unfinished-transaction drains, identify and
    /// foreground backstops, re-reports of current entitlements.
    case sync
}

/// `POST /v1/consumables:spend` request body.
struct SpendRequest: Encodable {
    let productIdentifier: String
    let units: Int
    let idempotencyKey: String
    let note: String?
}
