import Foundation

// MARK: - Configuration

/// Immutable configuration captured at `CashSDK.configure(...)` time.
///
/// The publishable key (`csk_pk_…`) is safe to embed in a shipped app: it can only
/// call the device API (`05-API.md` §2). All device requests send it as
/// `Authorization: Bearer <publishableKey>`.
public struct CashSDKConfiguration: Sendable, Equatable {
    /// The app's publishable key, e.g. `csk_pk_…`.
    public let publishableKey: String

    /// The REST base URL. Defaults to ``defaultAPIBase``; override for local/staging.
    public let apiBase: URL

    /// Store environment override (`"Sandbox"` or `"Production"`), sent as
    /// `X-CashSDK-Environment`.
    ///
    /// Leave it `nil` (the default) and the SDK learns the environment from the first verified
    /// StoreKit transaction — which is what you want for a build that can run against either.
    /// Set it explicitly only when you need to pin it (e.g. a QA build that must always read
    /// Sandbox even before its first purchase).
    public let environment: String?

    public init(
        publishableKey: String,
        apiBase: URL = CashSDKConfiguration.defaultAPIBase,
        environment: String? = nil
    ) {
        self.publishableKey = publishableKey
        self.apiBase = apiBase
        self.environment = environment
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
    /// StoreKit returned no `Product` for the requested identifier.
    case productNotFound(String)
    /// The user cancelled the App Store purchase sheet.
    case purchaseCancelled
    /// Ask-to-Buy / SCA: the purchase is deferred. Resolution arrives via `Transaction.updates`.
    case purchasePending
    /// StoreKit could not cryptographically verify the transaction. Never grant on this.
    case unverifiedTransaction(underlying: Error?)
    /// The server accepted the transaction (`200`) but credited it to NO user — it arrived with
    /// no `appAccountToken` and no trusted user token (a promoted App Store purchase, or one
    /// made before `identify(...)`). The transaction is deliberately left UNFINISHED so StoreKit
    /// redelivers it; call `identify(userId:userToken:)` and it will be reported and credited.
    case purchaseNotAttributed
    /// A transport-level failure (offline, timeout, DNS…). Reads still fall back to cache.
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
        case .productNotFound(let id):
            return "No StoreKit product was found for identifier \"\(id)\"."
        case .purchaseCancelled:
            return "The purchase was cancelled."
        case .purchasePending:
            return "The purchase is pending approval (Ask-to-Buy / SCA)."
        case .unverifiedTransaction:
            return "The transaction failed StoreKit signature verification."
        case .purchaseNotAttributed:
            return "The purchase could not be attributed to a user. Call CashSDK.shared.identify(userId:userToken:) — the transaction is kept and will be reported automatically."
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
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&_value)
    }
}
