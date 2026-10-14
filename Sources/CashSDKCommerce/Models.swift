import Foundation

public enum CommerceEnvironment: String, Codable, Sendable {
    case sandbox, production
}

/// What your backend returns from `CashSDKServer.createWebSession`. Pass `expiresInSeconds`
/// when you have it: it is counted on this Mac's clock, so a clock that is off does not matter.
/// A backend that returns only `expiresAt` still works.
public struct CommerceSessionToken: Codable, Sendable {
    public let token: String
    /// When the session ends, on the server's clock.
    public let expiresAt: String?
    /// Seconds the session is valid for, from when your backend answered.
    public let expiresInSeconds: Int?
    public init(token: String, expiresAt: String? = nil, expiresInSeconds: Int? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.expiresInSeconds = expiresInSeconds
    }
}

public struct CommerceCustomer: Codable, Sendable {
    public let customerId: String
    public let environment: CommerceEnvironment
}

public struct CommerceEntitlement: Codable, Sendable {
    public let identifier: String
    public let name: String
    public let active: Bool
    public let rank: Int?
    public let source: String
    public let expiresAt: String?
}

public struct CommerceEntitlements: Codable, Sendable {
    public let customerId: String
    public let environment: CommerceEnvironment
    public let revision: Int
    public let computedAt: String
    public let entitlements: [CommerceEntitlement]

    /// Expiry is checked on every access decision, including a previously fetched snapshot.
    public func isActive(_ identifier: String, at date: Date = Date()) -> Bool {
        entitlements.contains {
            $0.identifier == identifier && $0.active &&
                ($0.expiresAt == nil || (commerceDate($0.expiresAt!) ?? .distantPast) > date)
        }
    }
}

public struct CommerceSubscription: Codable, Sendable {
    public let productIdentifier: String
    public let displayName: String?
    public let provider: String?
    public let status: String
    public let active: Bool
    public let expiresAt: String?
    public let autoRenew: Bool
    public let trial: Bool
}

public struct CommerceSubscriptions: Codable, Sendable {
    public let customerId: String
    public let environment: CommerceEnvironment
    public let subscriptions: [CommerceSubscription]
}

public struct CommerceProduct: Codable, Sendable {
    public let identifier: String
    public let displayName: String?
    /// auto_renewable, non_consumable and so on.
    public let type: String
    public let provider: String
    /// Integer minor units. Kept as a string to avoid loss of precision.
    public let amountMinor: String?
    public let currency: String?
    public let duration: String?
}

public struct CommercePackage: Codable, Identifiable, Sendable {
    public let id: String
    public let identifier: String
    public let product: CommerceProduct
    /// This session can buy it. False once the customer has this plan's access or owns the product.
    public let purchasable: Bool
}

public struct CommerceOffering: Codable, Sendable {
    public let id: String
    public let identifier: String
    public let displayName: String?
    public let packages: [CommercePackage]
}

public struct CommerceOfferings: Codable, Sendable {
    public let current: CommerceOffering?
}

public struct CommerceCheckoutInput: Encodable, Sendable {
    public let packageId: String
    public let connectionId: String?
    public let successUrl: String
    public let cancelUrl: String
    public init(packageId: String, successURL: URL, cancelURL: URL, connectionId: String? = nil) {
        self.packageId = packageId
        self.successUrl = successURL.absoluteString
        self.cancelUrl = cancelURL.absoluteString
        self.connectionId = connectionId
    }
}

public struct CommerceCheckout: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, requiresAction = "requires_action", complete, expired, failed, needsReview = "needs_review"

        /// A status this SDK version does not know reads as pending: keep the attempt, read it again.
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: value) ?? .pending
        }
    }
    public struct Action: Codable, Sendable {
        public let type: String
        public let url: String
    }
    public let id: String
    public let provider: String
    public let environment: CommerceEnvironment
    /// The customer the checkout belongs to. Older servers leave it out.
    public let customerId: String?
    /// "subscription" for a recurring plan, "payment" for a one-time product.
    public let mode: String?
    /// The catalog product being bought.
    public let productIdentifier: String?
    public let status: Status
    public let paymentStatus: String?
    public let accessStatus: String
    public let action: Action?
    public let expiresAt: String?

    /// Payment completion alone never grants access. Read entitlements after this becomes true.
    public var settled: Bool {
        status == .expired || status == .failed || status == .needsReview ||
            (status == .complete && (paymentStatus == "paid" || paymentStatus == "no_payment_required"))
    }

    /// No payment can be taken on it any more: the next purchase is a new attempt.
    var isOver: Bool {
        status == .complete || status == .expired || status == .failed || status == .needsReview
    }

    /// Stripe Checkout on Stripe's host or the account's custom domain, while it waits for the
    /// customer. Nil when there is nothing to open, including a status this version does not know.
    public func redirectURL() throws -> URL? {
        guard let action else { return nil }
        guard action.type == "redirect" else { throw CommerceError.invalidResponse }
        guard status == .requiresAction else {
            if status == .pending { return nil }
            throw CommerceError.invalidResponse
        }
        return try stripePageURL(action.url, page: .checkout)
    }
}

public struct CommerceBillingPortal: Codable, Sendable {
    public let customerId: String
    public let environment: CommerceEnvironment
    public let provider: String
    public let url: String
    /// Stripe's customer portal on Stripe's host or the account's custom domain.
    public func redirectURL() throws -> URL { try stripePageURL(url, page: .portal) }
}

public struct CommerceError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let status: Int
    public let retryable: Bool
    public let requestId: String?
    public let retryAfter: TimeInterval?
    public var errorDescription: String? { message }

    public init(code: String, message: String, status: Int = 0, retryable: Bool = false,
                requestId: String? = nil, retryAfter: TimeInterval? = nil) {
        self.code = code; self.message = message; self.status = status
        self.retryable = retryable; self.requestId = requestId; self.retryAfter = retryAfter
    }
    static let invalidResponse = CommerceError(code: "invalid_response", message: "CashSDK returned an invalid response")
    static let identityChanged = CommerceError(code: "identity_changed", message: "Customer session changed")
}

func commerceDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

/// The two pages Stripe hosts for this SDK, with Stripe's own host and the path a custom domain uses.
enum StripePage {
    case checkout, portal
    var host: String { self == .checkout ? "checkout.stripe.com" : "billing.stripe.com" }
    var path: String { self == .checkout ? "/c/pay/" : "/p/session/" }
}

/// A page Stripe hosts, on Stripe's own host or on the account's custom domain under the same
/// path. HTTPS on the default port, no user name or password, a real domain name (not an IP
/// address, not localhost).
func stripePageURL(_ value: String, page: StripePage) throws -> URL {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https",
          url.port == nil || url.port == 443, url.user == nil, url.password == nil,
          let host = url.host?.lowercased(),
          host.range(of: #"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#,
                     options: .regularExpression) != nil else { throw CommerceError.invalidResponse }
    // The path the browser will open, with dot segments resolved and the trailing slash kept.
    let path = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    guard host == page.host || path.hasPrefix(page.path) else { throw CommerceError.invalidResponse }
    return url
}
