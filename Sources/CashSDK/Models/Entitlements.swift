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
    /// Authoritative access deadline; nil for perpetual access or older servers.
    public let expiresAt: String?

    public var id: String { identifier }
    public var isActive: Bool {
        guard let expiresAt else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let precise = formatter.date(from: expiresAt)
        formatter.formatOptions = [.withInternetDateTime]
        guard let deadline = precise ?? formatter.date(from: expiresAt) else { return false }
        return deadline > Date()
    }

    public init(identifier: String, name: String, rank: Int? = nil, source: String? = nil, expiresAt: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.rank = rank
        self.source = source
        self.expiresAt = expiresAt
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
    /// The transaction remains with its original app account. Verification surfaces a typed
    /// ownership conflict; callers must not interpret an empty snapshot as purchase success.
    ///
    /// Deliberately `false` under the app's `restorePolicy = "share"`: there the claimant rides
    /// the owner's receipt and the snapshot DOES carry the entitlement, so treating this as a
    /// failure would make the family-sharing flow look broken.
    ///
    /// Optional (like `consumables`) so a snapshot cached before this field existed still
    /// decodes, and `nil` before this run is stripped at persist time — it describes the
    /// transaction just verified, never the user's standing access.
    public let belongsToAnotherAccount: Bool?

    /// The store environment (`"Sandbox"` / `"Production"`) the server resolved this response
    /// in, echoed back so the SDK can pin subsequent reads to it.
    ///
    /// The publishable key carries no mode, deliberately: TestFlight ships the exact binary
    /// the App Store does, and its purchases are Sandbox while the App Store's are
    /// Production, so no compile-time key can be right for both. The environment therefore
    /// travels with the data instead.
    ///
    /// iOS normally works this out locally from `Transaction.environment`, which is iOS 16+.
    /// On iOS 15 there is no such property, so this field is the only way a device can learn
    /// it. Mirrors `Entitlements.environment` in the Android SDK, where Play Billing never
    /// tells the client at all.
    ///
    /// Optional, like `consumables`: a snapshot cached before this field existed, or a
    /// response from an older server, must still decode.
    public let environment: String?
    public let userId: String?
    public let identityRevision: UInt64?
    public let version: Int?
    public let computedAt: String?
    public let subscriptions: [SubscriptionStatus]?
    public let verificationStatus: String?
    public let purchaseOutcomeConfirmed: Bool?

    public init(
        entitlements: [Entitlement],
        tier: Int,
        tierIdentifier: String?,
        consumables: [ConsumableBalance]? = nil,
        belongsToAnotherAccount: Bool? = nil,
        environment: String? = nil,
        userId: String? = nil,
        identityRevision: UInt64? = nil,
        version: Int? = nil,
        computedAt: String? = nil,
        subscriptions: [SubscriptionStatus]? = nil,
        verificationStatus: String? = nil,
        purchaseOutcomeConfirmed: Bool? = nil
    ) {
        self.entitlements = entitlements
        self.tier = tier
        self.tierIdentifier = tierIdentifier
        self.consumables = consumables
        self.belongsToAnotherAccount = belongsToAnotherAccount
        self.environment = environment
        self.userId = userId
        self.identityRevision = identityRevision
        self.version = version
        self.computedAt = computedAt
        self.subscriptions = subscriptions
        self.verificationStatus = verificationStatus
        self.purchaseOutcomeConfirmed = purchaseOutcomeConfirmed
    }

    /// The same access, with the fields that describe *one transaction* rather than standing
    /// access removed — what actually gets cached.
    ///
    /// Mirrors `Entitlements.gatingSnapshot()` in the Android SDK. Persisting
    /// `belongsToAnotherAccount` would resurrect it on the next launch's hydrated snapshot, so
    /// a single restore of somebody else's receipt would make the app claim "already used on
    /// another Apple ID" forever. Environment remains observable inside the owner/environment
    /// scoped cache; it never overrides the environment configured by the host.
    func gatingSnapshot() -> Entitlements {
        Entitlements(
            entitlements: entitlements,
            tier: tier,
            tierIdentifier: tierIdentifier,
            consumables: consumables,
            belongsToAnotherAccount: nil,
            environment: environment,
            userId: userId,
            identityRevision: identityRevision,
            version: version,
            computedAt: computedAt,
            subscriptions: subscriptions,
            verificationStatus: verificationStatus
        )
    }

    func withIdentity(userId: String?, revision: UInt64, environment: String?) -> Entitlements {
        Entitlements(entitlements: entitlements, tier: tier, tierIdentifier: tierIdentifier,
            consumables: consumables, belongsToAnotherAccount: belongsToAnotherAccount,
            environment: self.environment ?? environment, userId: userId,
            identityRevision: revision, version: version, computedAt: computedAt,
            subscriptions: subscriptions, verificationStatus: verificationStatus,
            purchaseOutcomeConfirmed: purchaseOutcomeConfirmed)
    }

    func removingExpiredAccess() -> Entitlements {
        let active = entitlements.filter(\.isActive)
        guard active.count != entitlements.count else { return self }
        let highest = active.max { ($0.rank ?? 0) < ($1.rank ?? 0) }
        return Entitlements(entitlements: active, tier: highest?.rank ?? 0,
            tierIdentifier: highest?.identifier, consumables: consumables,
            belongsToAnotherAccount: belongsToAnotherAccount, environment: environment,
            userId: userId, identityRevision: identityRevision, version: version, computedAt: computedAt,
            subscriptions: subscriptions, verificationStatus: verificationStatus, purchaseOutcomeConfirmed: purchaseOutcomeConfirmed)
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
    public var isEmpty: Bool { !hasAny }

    /// `true` when the user holds at least one active entitlement.
    public var hasAny: Bool { entitlements.contains(where: \.isActive) }

    /// The active entitlement identifiers as a set — the shape most host apps
    /// branch on (`status.active.contains("pro")`).
    public var activeIdentifiers: Set<String> {
        Set(entitlements.filter(\.isActive).map(\.identifier))
    }

    /// Whether a specific entitlement is currently active.
    public func isActive(_ identifier: String) -> Bool {
        entitlements.contains { $0.identifier == identifier && $0.isActive }
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

/// Subscription lifecycle details, including inactive rows. A trial is distinct from a paid period.
public struct SubscriptionStatus: Codable, Sendable, Equatable {
    public let productIdentifier: String
    public let state: String
    public let environment: String
    public let expiresDate: String?
    public let graceUntil: String?
    public let autoRenew: Bool
    public let isTrial: Bool
    public let isIntro: Bool
    public let cancelReason: String?
    public let trialStart: String?
    public let trialEnd: String?
    public let originalTransactionId: String?
    public let revoked: Bool
}
