import Foundation

// MARK: - Validation

/// The answer of ``CashSDK/validateCoupon(_:)``.
///
/// A code the server refused is not an error: `valid` is `false` and ``reason`` says why. Show a
/// message for the reason, and let the user try another code.
public struct CouponValidation: Sendable, Equatable {
    /// Whether the signed-in user can redeem this code on this platform right now.
    public let valid: Bool
    /// Why the code cannot be redeemed. Nil when ``valid`` is `true`.
    public let reason: CouponInvalidReason?
    /// What the coupon gives. Nil when ``valid`` is `false`.
    public let coupon: Coupon?
    /// The products the coupon can be redeemed on, on this platform. Pass one of their
    /// ``CouponProduct/productId`` values to ``CashSDK/redeemCoupon(_:productId:)``.
    public let products: [CouponProduct]

    public init(valid: Bool, reason: CouponInvalidReason?, coupon: Coupon?, products: [CouponProduct]) {
        self.valid = valid
        self.reason = reason
        self.coupon = coupon
        self.products = products
    }

    /// The StoreKit product ids the coupon can be redeemed on.
    public var eligibleProductIds: [String] { products.map(\.productId) }
}

/// Why a coupon code cannot be redeemed. New server reasons arrive as ``unknown(_:)``, so an
/// older app keeps working when the server adds one.
public enum CouponInvalidReason: Sendable, Equatable, Hashable {
    /// No coupon has this code in this app.
    case notFound
    /// The coupon has a start date that is still in the future.
    case notStarted
    /// The coupon's end date has passed, or it was expired by hand.
    case expired
    /// The merchant turned the coupon off.
    case disabled
    /// Every use the coupon allows has been taken.
    case exhausted
    /// This user has already used the coupon as many times as it allows.
    case alreadyRedeemed
    /// This user cannot use it, for example a coupon for new customers only.
    case notEligible
    /// The coupon covers no product sold on this platform.
    case notAvailableOnPlatform
    /// The store offer behind the coupon is still being set up. Try again later.
    case notReady
    /// The coupon covers several plans of one product and none was chosen. Google Play only
    /// (base plans); an iOS app should not see it, but decodes it rather than as `unknown`.
    case basePlanRequired
    /// A reason this version of the SDK does not know, as the server sent it.
    case unknown(String)

    /// Map the wire value (`not_found`, `already_redeemed`, ...) to a case.
    public init(rawValue: String) {
        switch rawValue {
        case "not_found": self = .notFound
        case "not_started": self = .notStarted
        case "expired": self = .expired
        case "disabled": self = .disabled
        case "exhausted": self = .exhausted
        case "already_redeemed": self = .alreadyRedeemed
        case "not_eligible": self = .notEligible
        case "not_available_on_platform": self = .notAvailableOnPlatform
        case "not_ready": self = .notReady
        case "base_plan_required": self = .basePlanRequired
        default: self = .unknown(rawValue)
        }
    }

    /// The wire value.
    public var rawValue: String {
        switch self {
        case .notFound: return "not_found"
        case .notStarted: return "not_started"
        case .expired: return "expired"
        case .disabled: return "disabled"
        case .exhausted: return "exhausted"
        case .alreadyRedeemed: return "already_redeemed"
        case .notEligible: return "not_eligible"
        case .notAvailableOnPlatform: return "not_available_on_platform"
        case .notReady: return "not_ready"
        case .basePlanRequired: return "base_plan_required"
        case .unknown(let value): return value
        }
    }

    /// Every reason the contract names, in a stable order. `unknown` is not included.
    static let known: [CouponInvalidReason] = [
        .notFound, .notStarted, .expired, .disabled, .exhausted,
        .alreadyRedeemed, .notEligible, .notAvailableOnPlatform, .notReady, .basePlanRequired,
    ]
}

/// What kind of discount a coupon gives.
public enum CouponKind: Sendable, Equatable, Hashable {
    /// A percentage off the price, for ``Coupon/periodCount`` periods.
    case percentOff
    /// A fixed amount off the price, for ``Coupon/periodCount`` periods.
    case amountOff
    /// A free period of ``Coupon/duration``.
    case freeTrial
    /// A kind this version of the SDK does not know, as the server sent it.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "percent_off": self = .percentOff
        case "amount_off": self = .amountOff
        case "free_trial": self = .freeTrial
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .percentOff: return "percent_off"
        case .amountOff: return "amount_off"
        case .freeTrial: return "free_trial"
        case .unknown(let value): return value
        }
    }
}

/// What a coupon gives, for the copy next to the code field.
///
/// For the price the user will actually pay, trust the App Store sheet: the discounted price is
/// set per storefront and snapped to an Apple price point.
public struct Coupon: Sendable, Equatable {
    /// The code, upper-case, as the merchant created it.
    public let code: String
    /// The merchant's name for the coupon.
    public let name: String
    public let kind: CouponKind
    /// 1 to 99 for ``CouponKind/percentOff``; nil otherwise.
    public let percentOff: Int?
    /// The amount off in minor units of ``currency`` (cents for USD, yen for JPY) for
    /// ``CouponKind/amountOff``; nil otherwise. See ``formattedAmountOff(locale:)``.
    public let amountOffMinor: Int?
    /// ISO 4217 code of ``amountOffMinor``.
    public let currency: String?
    /// ISO 8601 period of one discounted period, or of the free period (`P1M`, `P1W`, `P3D`).
    public let duration: String
    /// How many discounted periods. Always 1 for a free period.
    public let periodCount: Int

    public init(
        code: String,
        name: String,
        kind: CouponKind,
        percentOff: Int?,
        amountOffMinor: Int?,
        currency: String?,
        duration: String,
        periodCount: Int
    ) {
        self.code = code
        self.name = name
        self.kind = kind
        self.percentOff = percentOff
        self.amountOffMinor = amountOffMinor
        self.currency = currency
        self.duration = duration
        self.periodCount = periodCount
    }

    /// The amount off as a decimal in major units (`499` USD minor units is `4.99`), or nil when
    /// the coupon is not an amount off.
    public var amountOff: Decimal? {
        guard let amountOffMinor, let currency else { return nil }
        return CouponMoney.majorUnits(amountOffMinor, currency: currency)
    }

    /// The amount off formatted for display (`$4.99`, `¥500`), or nil when the coupon is not an
    /// amount off.
    public func formattedAmountOff(locale: Locale = .current) -> String? {
        guard let amountOffMinor, let currency else { return nil }
        return CouponMoney.format(amountOffMinor, currency: currency, locale: locale)
    }
}

/// A product the coupon can be redeemed on.
public struct CouponProduct: Sendable, Equatable {
    /// The StoreKit product id.
    public let productId: String
    /// The App Store offer code for this product (the coupon code, or `<CODE>-<PLAN>` when the
    /// coupon covers several plans). The user never needs to type it.
    public let appleCode: String?
    /// The App Store page that redeems ``appleCode``.
    public let redeemURL: URL?

    public init(productId: String, appleCode: String?, redeemURL: URL?) {
        self.productId = productId
        self.appleCode = appleCode
        self.redeemURL = redeemURL
    }
}

// MARK: - Redemption

/// The outcome of ``CashSDK/redeemCoupon(_:productId:)``.
public enum CouponRedemptionResult: Sendable, Equatable {
    /// One use of the coupon is reserved for this user and the App Store's offer code page is
    /// open. The purchase completes there; the SDK verifies the resulting transaction as a
    /// purchase and publishes the new access on ``CashSDK/entitlementUpdates``. Wait for it with
    /// ``CashSDK/awaitCouponCompletion(redemptionId:timeout:)``.
    case openedAppStore(redemptionId: String, redeemURL: URL)

    /// The server's id for this reservation. The same user redeeming the same coupon again gets
    /// the same id.
    public var redemptionId: String {
        switch self {
        case .openedAppStore(let redemptionId, _): return redemptionId
        }
    }
}

/// What ``CashSDK/awaitCouponCompletion(redemptionId:timeout:)`` saw.
public enum CouponCompletion: Sendable, Equatable {
    /// The coupon purchase was verified for the signed-in user. Carries the access after it.
    case completed(Entitlements)
    /// Nothing arrived in time. The user may have left the App Store page without redeeming,
    /// or may still be on it. A purchase that completes later is still verified and published
    /// on ``CashSDK/entitlementUpdates``.
    case timedOut
}

/// Coupon failures that are not a refused code or one of the ``CashSDKError`` cases.
///
/// A separate type so apps that switch exhaustively over ``CashSDKError`` keep compiling. The
/// coupon calls also throw ``CashSDKError``: ``CashSDKError/notIdentified`` (no signed-in user),
/// ``CashSDKError/purchaseInProgress``, ``CashSDKError/observerMode``, the identity token errors,
/// ``CashSDKError/network(underlying:)``, ``CashSDKError/server(status:code:message:)`` and
/// ``CashSDKError/invalidResponse``.
public enum CouponError: Error, Sendable, Equatable {
    /// The server re-checked the code while reserving it and refused it. Nothing was reserved
    /// and nothing was charged.
    case rejected(CouponInvalidReason)
    /// The server returned no App Store page to open for this product, or one that is not an
    /// App Store offer code page. Nothing was charged.
    case redeemURLUnavailable(productId: String)
    /// The system did not open the App Store page. The use stays reserved for a day, so calling
    /// ``CashSDK/redeemCoupon(_:productId:)`` again returns the same reservation.
    case couldNotOpenAppStore(redeemURL: URL)
}

extension CouponError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rejected(let reason):
            return CouponInvalidReason.message(for: reason)
        case .redeemURLUnavailable:
            return "This coupon cannot be redeemed on this device right now."
        case .couldNotOpenAppStore:
            return "The App Store could not be opened to redeem this coupon."
        }
    }
}

extension CouponInvalidReason {
    /// Plain text for a refused code, safe to show to a user.
    static func message(for reason: CouponInvalidReason) -> String {
        switch reason {
        case .notFound: return "This code is not valid."
        case .notStarted: return "This code is not active yet."
        case .expired: return "This code has expired."
        case .disabled: return "This code is no longer available."
        case .exhausted: return "This code has been fully redeemed."
        case .alreadyRedeemed: return "You have already used this code."
        case .notEligible: return "Your account cannot use this code."
        case .notAvailableOnPlatform: return "This code cannot be used on this device."
        case .notReady: return "This code is not ready yet. Try again in a little while."
        case .basePlanRequired: return "Choose a plan to use this code with."
        case .unknown: return "This code cannot be used right now."
        }
    }
}

// MARK: - Money

/// Minor units to major units, with the same exponents as the server (`@cashsdk/money`), which
/// follow ISO 4217 rather than whatever the device's ICU says.
enum CouponMoney {
    private static let zeroDecimal: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF",
        "UGX", "VND", "VUV", "XAF", "XOF", "XPF",
    ]
    private static let threeDecimal: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    static func decimals(for currency: String) -> Int {
        let code = currency.uppercased()
        if zeroDecimal.contains(code) { return 0 }
        if threeDecimal.contains(code) { return 3 }
        return 2
    }

    static func majorUnits(_ minor: Int, currency: String) -> Decimal {
        Decimal(sign: minor < 0 ? .minus : .plus, exponent: -decimals(for: currency), significand: Decimal(abs(minor)))
    }

    static func format(_ minor: Int, currency: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currency.uppercased()
        let digits = decimals(for: currency)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let amount = majorUnits(minor, currency: currency) as NSDecimalNumber
        return formatter.string(from: amount) ?? "\(amount) \(currency.uppercased())"
    }
}

// MARK: - Wire DTOs (internal)

/// `POST /v1/coupons:validate` request body.
struct CouponValidateRequest: Encodable {
    let code: String
    let appUserId: String
    let platform: String
}

/// `POST /v1/coupons:redeem` request body.
struct CouponRedeemRequest: Encodable {
    let code: String
    let appUserId: String
    let platform: String
    let productIdentifier: String
}

struct CouponIOSOfferWire: Decodable, Sendable, Equatable {
    let appleCode: String?
    let redeemUrl: String?
}

struct CouponWire: Decodable, Sendable {
    let code: String
    let name: String?
    let kind: String
    let percentOff: Int?
    let amountOffMinor: Int?
    let currency: String?
    let duration: String?
    let periodCount: Int?

    var model: Coupon {
        Coupon(
            code: code,
            name: name ?? code,
            kind: CouponKind(rawValue: kind),
            percentOff: percentOff,
            amountOffMinor: amountOffMinor,
            currency: currency,
            duration: duration ?? "",
            periodCount: periodCount ?? 1
        )
    }
}

struct CouponProductWire: Decodable, Sendable {
    let productIdentifier: String
    let ios: CouponIOSOfferWire?
}

/// `POST /v1/coupons:validate` response.
struct CouponValidateResponse: Decodable, Sendable {
    let valid: Bool
    let reason: String?
    let coupon: CouponWire?
    let products: [CouponProductWire]?

    /// The public shape. Only products with an iOS offer are listed: the others cannot be
    /// redeemed here.
    var model: CouponValidation {
        guard valid else {
            return CouponValidation(valid: false, reason: CouponInvalidReason(rawValue: reason ?? "unknown"), coupon: nil, products: [])
        }
        let products = (products ?? []).compactMap { product -> CouponProduct? in
            guard let ios = product.ios else { return nil }
            return CouponProduct(
                productId: product.productIdentifier,
                appleCode: ios.appleCode,
                redeemURL: ios.redeemUrl.flatMap(URL.init(string:))
            )
        }
        return CouponValidation(valid: true, reason: nil, coupon: coupon?.model, products: products)
    }
}

/// `POST /v1/coupons:redeem` response. A server that re-validates and refuses may answer with
/// `valid: false` and a `reason` instead of a reservation.
struct CouponRedeemResponse: Decodable, Sendable {
    let redemptionId: String?
    let ios: CouponIOSOfferWire?
    let valid: Bool?
    let reason: String?
}
