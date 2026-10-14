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

// MARK: - Promotional offer

/// An App Store promotional offer your server signed for one purchase, for
/// ``CashSDK/purchase(_:promotionalOffer:)``.
///
/// Apple only applies a promotional offer whose signature was made with one of your In-App
/// Purchase keys over, in order: the bundle id, the key id, the product id, the offer id, the
/// purchase's app account token, the nonce and the timestamp. The app account token in that
/// payload must be the one CashSDK stamps on the purchase, which is
/// ``CashSDK/appAccountToken(for:)`` of the signed-in user id, lowercased. Sign on your
/// server: the In-App Purchase key must never ship in the app.
///
/// Who may redeem an offer is your server's decision. Apple only checks the signature and that
/// the Apple ID subscribed in the product's subscription group before.
public struct PromotionalOfferSignature: Sendable, Hashable {
    /// The promotional offer's identifier, as created in App Store Connect.
    public let offerId: String
    /// The id of the In-App Purchase key that made `signature`.
    public let keyId: String
    /// The nonce in the signed payload. Apple expects it lowercased, as `UUID` sends it.
    public let nonce: UUID
    /// The signature bytes (the base64-decoded value your server produced).
    public let signature: Data
    /// When the signature was made, in milliseconds since 1970. Apple refuses one older than
    /// 24 hours, so fetch it right before the purchase.
    public let timestamp: Int

    public init(offerId: String, keyId: String, nonce: UUID, signature: Data, timestamp: Int) {
        self.offerId = offerId
        self.keyId = keyId
        self.nonce = nonce
        self.signature = signature
        self.timestamp = timestamp
    }

    /// The same, from a server response that carries the signature as base64. `nil` when
    /// `base64Signature` is not valid base64.
    public init?(offerId: String, keyId: String, nonce: UUID, base64Signature: String, timestamp: Int) {
        guard let signature = Data(base64Encoded: base64Signature), !signature.isEmpty else { return nil }
        self.init(offerId: offerId, keyId: keyId, nonce: nonce, signature: signature, timestamp: timestamp)
    }
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
