import Foundation

// MARK: - Configuration

/// Immutable configuration captured at `CashSDK.configure(...)` time.
///
/// The publishable key (`csk_pk_…`) is safe to embed in a shipped app: it can only call the
/// device API (`05-API.md` §2). All device requests send it as
/// `Authorization: Bearer <publishableKey>`.
///
/// There is ONE publishable key per app and it serves both store environments. That is
/// deliberate: TestFlight distributes the exact binary you submit to the App Store, and
/// TestFlight purchases run in Apple's sandbox while App Store purchases run in production.
/// A key pinned to one environment would lock out every user of the other, and no build
/// configuration can avoid it, so ship the same key everywhere.
///
/// Sandbox and production purchases stay separate anyway, and by a stronger mechanism than a
/// key prefix: every purchase is recorded under the environment named in the store's OWN
/// signed transaction, and the SDK pins its reads to whichever environment the purchase
/// resolved into.
public struct CashSDKConfiguration: Sendable, Equatable {
    /// The app's publishable key, `csk_pk_…`. Copy it from Dashboard → your app →
    /// Developers → API Keys.
    public let publishableKey: String

    /// The REST base URL. Defaults to ``defaultAPIBase``; override for local/staging.
    public let apiBase: URL

    /// Store environment override (`"Sandbox"` or `"Production"`), sent as
    /// `X-CashSDK-Environment`.
    ///
    /// **Leave this `nil`.** It is the right answer for every shipping build, including the
    /// one you send to TestFlight: the SDK learns the environment from the store itself, via
    /// `Transaction.environment` on iOS 16+ and via the server's verify response on iOS 15,
    /// and one binary then works correctly in both.
    ///
    /// Set it only to pin a build that must read one environment before it has made any
    /// purchase at all, such as a QA harness that reads Sandbox from launch. A pinned value
    /// always wins over what the store reports, so pinning the wrong one is a build that
    /// reads an empty entitlement list and looks broken.
    ///
    /// If you are holding a `csk_pk_test_…` or `csk_pk_live_…` from before publishable keys
    /// were unified, that key still clamps to its own environment and a disagreeing value
    /// here is a `400 environment_mismatch`. Roll it in the dashboard to get a key that
    /// works in both.
    public let environment: String?
    /// Passive mode never starts a StoreKit listener, purchases, restores or finishes a transaction.
    public let observerMode: Bool

    public init(
        publishableKey: String,
        apiBase: URL = CashSDKConfiguration.defaultAPIBase,
        environment: String? = nil,
        observerMode: Bool = false
    ) {
        self.publishableKey = publishableKey
        self.apiBase = apiBase
        self.environment = environment
        self.observerMode = observerMode
    }

    /// Production base URL (`https://api.cashsdk.com`). Resolved without a force-unwrap.
    public static let defaultAPIBase: URL = {
        guard let url = URL(string: "https://api.cashsdk.com") else {
            preconditionFailure("CashSDK: hard-coded default API base URL is invalid")
        }
        return url
    }()
}

// MARK: - Errors

/// The SDK's typed error surface (mirrors `08-IOS-SDK.md` §6).
///
/// `.purchaseCancelled` is a normal user action, not a failure to surface as an alert.
public enum CashSDKError: Error {
    /// `configure(publishableKey:)` was never called.
    case notConfigured
    /// An operation that requires an identified user was called before `identify(userId:)`.
    case notIdentified
    case identityTokenRequired
    case identityTokenInvalid
    case identityTokenExpired
    case identityChanged
    case observerMode
    /// StoreKit succeeded; verification did not. Do not retry by buying again.
    case chargedButUnverified(transactionId: String, underlying: Error)
    /// Verification is durable, but the server has not confirmed access for this product.
    case verifiedWithoutAccess(transactionId: String)
    case restoreVerificationFailed(underlying: Error)
    /// StoreKit returned no `Product` for the requested identifier.
    case productNotFound(String)
    /// The user cancelled the App Store purchase sheet. `purchase(_:)` reports that as
    /// ``PurchaseResult/userCancelled``; `restore()` throws this when the user cancels the App
    /// Store sign-in it may ask for.
    case purchaseCancelled
    /// The App Store declined before charging: this Apple ID already has an active subscription
    /// to the product, usually bought while signed in to another account in this app (App Store
    /// error 3532). Offer Restore Purchases, or ask the user to sign in to the account that
    /// subscribed. Buying again cannot help.
    case alreadySubscribed(productId: String)
    /// The App Store declined before charging: purchases are turned off for this device or
    /// Apple ID (Screen Time, parental controls, device management).
    case purchaseNotAllowed
    /// The App Store declined before charging: the product cannot be bought right now (not sold
    /// in this storefront, removed from sale, or not yet approved).
    case productUnavailable(productId: String)
    /// StoreKit ended the purchase without a transaction, a cancellation, or one of the refusals
    /// above. A charge is unlikely but not ruled out: if one happened, the transaction reaches
    /// `Transaction.updates` and the SDK verifies it without another purchase. `underlying` is
    /// StoreKit's error, or nil when StoreKit returned a result this SDK does not recognize.
    case storeKitFailed(underlying: Error?)
    /// Ask-to-Buy / SCA: the purchase is deferred. Resolution arrives via `Transaction.updates`.
    case purchasePending
    /// StoreKit could not cryptographically verify the transaction. Never grant on this.
    case unverifiedTransaction(underlying: Error?)
    /// The server accepted the transaction (`200`) but credited it to NO user — it arrived with
    /// no `appAccountToken` and no trusted user token (a promoted App Store purchase, or one
    /// made before `identify(...)`). The transaction is deliberately left UNFINISHED so StoreKit
    /// redelivers it; call `identify(userId:userToken:)` and it will be reported and credited.
    case purchaseNotAttributed
    /// The server's restore policy keeps the purchase with another app account.
    case purchaseBelongsToAnotherAccount
    /// A purchase or explicit restore is already running.
    case purchaseInProgress
    /// A transport-level failure (offline, timeout, DNS…), talking to the CashSDK API or to the
    /// App Store. Reads still fall back to cache.
    case network(underlying: Error)
    /// A structured non-2xx response from the API (`05-API.md` §3 error envelope).
    case server(status: Int, code: String?, message: String?)
    /// The response was not the shape the SDK expected.
    case invalidResponse
}

extension CashSDKError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "CashSDK is not configured. Call CashSDK.configure(publishableKey:) at launch."
        case .notIdentified:
            return "CashSDK has no identified user. Call CashSDK.shared.identify(userId:) first."
        case .identityTokenRequired: return "A signed user token is required before purchasing."
        case .identityTokenInvalid: return "The identity token does not match this account or is invalid."
        case .identityTokenExpired: return "Your session needs to be refreshed before purchasing."
        case .identityChanged: return "The signed-in account changed during this operation."
        case .observerMode: return "Purchases and restores are disabled in passive observer mode."
        case .chargedButUnverified: return "Your payment needs verification. It will be retried without another charge."
        case .verifiedWithoutAccess: return "The payment was verified, but access has not been confirmed."
        case .restoreVerificationFailed: return "Some purchases could not be verified. Please retry restoring."
        case .productNotFound(let id):
            return "No StoreKit product was found for identifier \"\(id)\"."
        case .purchaseCancelled:
            return "The purchase was cancelled."
        case .alreadySubscribed:
            return "This Apple ID already has this subscription, possibly under another account in this app. Restore purchases, or sign in to the account that subscribed."
        case .purchaseNotAllowed:
            return "Purchases are not allowed on this device or Apple ID."
        case .productUnavailable:
            // No product id here: this text can reach users. The id stays in the payload and the log.
            return "This product is not available for purchase right now."
        case .storeKitFailed:
            return "The App Store did not complete the purchase."
        case .purchasePending:
            return "The purchase is pending approval (Ask-to-Buy / SCA)."
        case .unverifiedTransaction:
            return "The transaction failed StoreKit signature verification."
        case .purchaseNotAttributed:
            return "The purchase could not be attributed to a user. Call CashSDK.shared.identify(userId:userToken:). The transaction is kept and will be reported automatically."
        case .purchaseBelongsToAnotherAccount:
            return "This purchase belongs to another app account. Sign in to the account that owns it."
        case .purchaseInProgress:
            return "A purchase or restore is already in progress."
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .server(let status, let code, let message):
            return "Server error \(status)\(code.map { " (\($0))" } ?? "")\(message.map { ": \($0)" } ?? "")."
        case .invalidResponse:
            return "The server response could not be decoded."
        }
    }
}

// MARK: - Locked

/// A minimal mutex-guarded box for state that must be read synchronously from any
/// thread (e.g. the `CashSDK.entitlements` snapshot). Actors are used for the async
/// subsystems; this covers the few values that need lock-free *reads* at any call site.
final class Locked<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) { self._value = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }

    /// Mutate the value while holding the lock and return a result computed from it.
    @discardableResult
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&_value)
    }
}

extension CashSDK {
    /// The platform this build reports to CashSDK in events and coupon calls: `macos` for a
    /// native macOS app and for Mac Catalyst, `ios` for iPhone and iPad. Both are Apple
    /// StoreKit platforms; the server redeems a Mac app's offer codes through Apple's path.
    static var devicePlatform: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return "macos"
        #else
        return "ios"
        #endif
    }
}
