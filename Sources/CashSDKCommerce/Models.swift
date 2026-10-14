import Foundation

public enum CommerceEnvironment: String, Codable, Sendable {
    case sandbox, production
}

public struct CommerceSessionToken: Codable, Sendable {
    public let token: String
    public let expiresAt: String?
    public init(token: String, expiresAt: String? = nil) {
        self.token = token
        self.expiresAt = expiresAt
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
    }
    public struct Action: Codable, Sendable {
        public let type: String
        public let url: String
    }
    public let id: String
    public let provider: String
    public let environment: CommerceEnvironment
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

    public func redirectURL() throws -> URL? {
        guard let action else { return nil }
        guard action.type == "redirect", status == .requiresAction else { throw CommerceError.invalidResponse }
        return try stripeURL(action.url, host: "checkout.stripe.com")
    }
}

public struct CommerceBillingPortal: Codable, Sendable {
    public let customerId: String
    public let environment: CommerceEnvironment
    public let provider: String
    public let url: String
    public func redirectURL() throws -> URL { try stripeURL(url, host: "billing.stripe.com") }
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

func stripeURL(_ value: String, host: String) throws -> URL {
    guard let url = URL(string: value), url.scheme == "https", url.host == host,
          url.port == nil, url.user == nil, url.password == nil else { throw CommerceError.invalidResponse }
    return url
}
