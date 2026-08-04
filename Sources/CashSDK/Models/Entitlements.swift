import Foundation

// MARK: - Entitlements

/// A single entitlement the user currently holds (server truth).
///
/// Mirrors the API snapshot element `{ identifier, name, rank, source }`.
public struct Entitlement: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier, e.g. `"plus"`.
    public let identifier: String
    /// Human-readable name, e.g. `"Plus"`.
    public let name: String
    /// Catalog rank; higher wins when computing the tier. May be absent.
    public let rank: Int?
    /// How the entitlement was granted: `"subscription"`, `"purchase"`, `"manual_grant"`.
    public let source: String?

    public var id: String { identifier }

    public init(identifier: String, name: String, rank: Int? = nil, source: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.rank = rank
        self.source = source
    }
}

/// A point-in-time snapshot of the user's access. Offline-valid: persisted to disk and
/// served synchronously from `CashSDK.entitlements`.
///
/// Shape matches `GET /v1/entitlements` and `POST /v1/transactions:verify`:
/// `{ entitlements: [...], tier: <Int>, tierIdentifier: <String?> }`.
public struct Entitlements: Codable, Sendable, Equatable {
    /// All active entitlements.
    public let entitlements: [Entitlement]
    /// The numeric rank of the highest active entitlement (`0` when none).
    public let tier: Int
    /// The identifier of the highest-ranked active entitlement, or `nil`.
    public let tierIdentifier: String?
    /// Spendable one-time-purchase balances (coin packs, credits).
    ///
    /// Optional on purpose: Swift's synthesized `Decodable` throws on a missing key
    /// rather than falling back to a default, so an entitlement snapshot cached to disk
    /// before this field existed — or a response from an older server — must still decode.
    public let consumables: [ConsumableBalance]?

    /// `true` when the receipt is real but registered to a DIFFERENT app user — a purchase
    /// restored from another Apple ID.
    ///
    /// Informational, **not** an error. The transaction was accepted and attributed to the
    /// caller; there is simply nothing for *this* user to grant, so the snapshot beside the flag
    /// is legitimately empty. Show "already used on another Apple ID" rather than leaving the
    /// user staring at an unexplained blank.
    ///
    /// Deliberately `false` under the app's `restorePolicy = "share"`: there the claimant rides
    /// the owner's receipt and the snapshot DOES carry the entitlement, so treating this as a
    /// failure would make the family-sharing flow look broken.
    ///
    /// Optional (like `consumables`) so a snapshot cached before this field existed still
    /// decodes, and `nil` before this run is stripped at persist time — it describes the
    /// transaction just verified, never the user's standing access.
    public let belongsToAnotherAccount: Bool?

    public init(
        entitlements: [Entitlement],
        tier: Int,
        tierIdentifier: String?,
        consumables: [ConsumableBalance]? = nil,
        belongsToAnotherAccount: Bool? = nil
    ) {
        self.entitlements = entitlements
        self.tier = tier
        self.tierIdentifier = tierIdentifier
        self.consumables = consumables
        self.belongsToAnotherAccount = belongsToAnotherAccount
    }

    /// The same access, with the fields that describe *one transaction* rather than standing
    /// access removed — what actually gets cached.
    ///
    /// Mirrors `Entitlements.gatingSnapshot()` in the Android SDK. Persisting
    /// `belongsToAnotherAccount` would resurrect it on the next launch's hydrated snapshot, so
    /// a single restore of somebody else's receipt would make the app claim "already used on
    /// another Apple ID" forever.
    func gatingSnapshot() -> Entitlements {
        Entitlements(
            entitlements: entitlements,
            tier: tier,
            tierIdentifier: tierIdentifier,
            consumables: consumables,
            belongsToAnotherAccount: nil
        )
    }

    /// An empty snapshot (no access).
    public static let empty = Entitlements(entitlements: [], tier: 0, tierIdentifier: nil)

    /// Spendable balances, normalised to a non-optional list.
    public var balances: [ConsumableBalance] { consumables ?? [] }

    /// Spendable balance of a consumable product (`0` when never bought).
    /// May be NEGATIVE after a refund of units the user already spent.
    public func balance(of productIdentifier: String) -> Int {
        balances.first { $0.productIdentifier == productIdentifier }?.balance ?? 0
    }

    /// `true` when the user holds no entitlements.
    public var isEmpty: Bool { entitlements.isEmpty }

    /// `true` when the user holds at least one active entitlement.
    public var hasAny: Bool { !entitlements.isEmpty }

    /// The active entitlement identifiers as a set — the shape most host apps
    /// branch on (`status.active.contains("pro")`).
    public var activeIdentifiers: Set<String> {
        Set(entitlements.map(\.identifier))
    }

    /// Whether a specific entitlement is currently active.
    public func isActive(_ identifier: String) -> Bool {
        entitlements.contains { $0.identifier == identifier }
    }
}

/// A spendable consumable balance.
public struct ConsumableBalance: Codable, Sendable, Equatable, Identifiable {
    public let productIdentifier: String
    public let balance: Int
    public var id: String { productIdentifier }

    public init(productIdentifier: String, balance: Int) {
        self.productIdentifier = productIdentifier
        self.balance = balance
    }
}
