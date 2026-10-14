import Foundation
import StoreKit

/// A verified StoreKit transaction reduced to what reporting needs.
///
/// `StoreKitManager` builds it from a real `Transaction`. Tests build it directly: StoreKit has
/// no public way to create a `Transaction`, and without this seam the purchase, restore and
/// recovery paths could only be exercised on a device.
struct StoreTransaction: Sendable {
    let id: String
    let productId: String
    /// The signed JWS sent to `transactions:verify` (it lives on the `VerificationResult`, not
    /// the decoded `Transaction`).
    let jws: String
    let appAccountToken: UUID?
    /// When the App Store charged for it, by Apple's clock.
    let purchaseDate: Date
    /// The first transaction of this purchase's chain; equal to `id` for a new purchase.
    let originalId: String
    /// Whether the subscription renewed on its own rather than the customer buying: from
    /// `Transaction.reason` (iOS 17+, macOS 14+), else from the signed payload's
    /// `transactionReason`. Nil when neither says.
    let renewal: Bool?
    /// `"Sandbox"` / `"Production"` from `Transaction.environment` (iOS 16+); nil when unknown.
    let environment: String?
    /// False for Xcode's local StoreKit environment. Apple does not sign those transactions,
    /// so there is nothing the server could verify.
    let isServerVerifiable: Bool
    /// `Transaction.finish()`. Call it only after the server has recorded the purchase.
    let finish: @Sendable () async -> Void
    /// The signed payload's `offerType`: 1 introductory, 2 promotional, 3 offer code. Nil when
    /// the transaction used no offer.
    var offerType: Int? = nil
    /// The signed payload's `offerIdentifier`: for an offer code, the offer's reference name
    /// (`cashsdk-cpn-<couponId>-<productIdentifier>` for a CashSDK coupon).
    var offerIdentifier: String? = nil

    /// `offerType` 3: the purchase redeemed an App Store offer code.
    var isOfferCode: Bool { offerType == Self.offerCodeType }

    static let offerCodeType = 3
}

extension StoreTransaction {
    init(_ transaction: Transaction, jws: String) {
        self.init(
            id: String(transaction.id),
            productId: transaction.productID,
            jws: jws,
            appAccountToken: transaction.appAccountToken,
            purchaseDate: transaction.purchaseDate,
            originalId: String(transaction.originalID),
            renewal: Self.isRenewal(transaction, jws: jws),
            environment: StoreKitManager.environmentName(transaction),
            isServerVerifiable: StoreKitManager.isServerVerifiable(transaction),
            finish: { await transaction.finish() },
            offerType: (Self.signedClaim(jws, "offerType") as? NSNumber)?.intValue,
            offerIdentifier: Self.signedClaim(jws, "offerIdentifier") as? String
        )
    }

    private static func isRenewal(_ transaction: Transaction, jws: String) -> Bool? {
        if #available(iOS 17.0, macOS 14.0, *) {
            return transaction.reason == .renewal
        }
        return signedTransactionReason(jws).map { $0 == "RENEWAL" }
    }

    /// `transactionReason` from the JWS payload (`PURCHASE` or `RENEWAL`), which Apple signs
    /// server side whatever the device's OS version. StoreKit already verified the signature;
    /// this only reads a field. Nil when the payload does not carry it.
    static func signedTransactionReason(_ jws: String) -> String? {
        signedClaim(jws, "transactionReason") as? String
    }

    /// One field of the JWS payload, read the same way: StoreKit already checked the signature.
    /// Offer fields are read here rather than from `Transaction.offerType`, so the answer is the
    /// same on every OS version.
    static func signedClaim(_ jws: String, _ name: String) -> Any? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims[name]
    }
}

/// The result of driving StoreKit's purchase flow to completion.
enum StorePurchaseOutcome: Sendable {
    /// A cryptographically verified transaction, still unfinished.
    case verified(StoreTransaction)
    /// Deferred (Ask-to-Buy / SCA). Resolution will arrive on `Transaction.updates`.
    case pending
    /// The user dismissed the App Store sheet.
    case userCancelled
}

/// A product ready for the payment sheet. Wraps StoreKit's `Product`, which tests cannot
/// create; with `StoreKitManager.purchaseHandler` set it carries only the id.
struct PurchasableProduct: Sendable {
    let id: String
    fileprivate let storeProduct: Product?
}

/// How StoreKit failed before handing back a transaction. Every case except `.network` and
/// `.other` is known to happen before any charge.
enum StoreFailure: Equatable {
    case cancelled
    /// App Store error 3532: this Apple ID already has the subscription.
    case alreadySubscribed
    case notAllowed
    case unavailable
    case network
    case other
}

/// The StoreKit 2 engine: product loading, the purchase flow, the lifetime
/// `Transaction.updates` listener, promoted-purchase intents, and current-entitlement
/// enumeration for restore / launch backstop. This is intentionally UI-free: it hands verified
/// JWS strings back to `CashSDK`, which reports them to `transactions:verify`.
final class StoreKitManager: @unchecked Sendable {
    private var updatesTask: Task<Void, Never>?
    private var intentsTask: Task<Void, Never>?
    // Internal seams for deterministic tests; no replacement transaction owner.
    var productsLoader: (@Sendable ([String]) async throws -> [Product])?
    /// What StoreKit last said about each product, for the seconds between a paywall rendering
    /// and the tap. See `ProductCache`.
    let productCache = ProductCache<Product>()
    var syncHandler: (@Sendable () async throws -> Void)?
    /// Replaces product lookup and the payment sheet together.
    var purchaseHandler: (@Sendable (_ productId: String, _ appAccountToken: UUID?) async throws -> StorePurchaseOutcome)?
    /// With `purchaseHandler`, the product lookup before the sheet.
    var purchaseLookupHandler: (@Sendable (_ productId: String) async throws -> Void)?
    var currentEntitlementsLoader: (@Sendable () async -> [StoreTransaction])?
    var unfinishedLoader: (@Sendable () async -> [StoreTransaction])?
    var introEligibilityHandler: (@Sendable (_ productId: String) async throws -> Bool)?

    /// Start the `Transaction.updates` listener (FR-2.5). Every incoming verified transaction,
    /// renewal, revocation, Ask-to-Buy resolution, is delivered to `handler`. Unverified ones
    /// are dropped: nothing is ever granted on them.
    func startListening(handler: @escaping @Sendable (StoreTransaction) async -> Void) {
        updatesTask?.cancel()
        updatesTask = Task.detached {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await handler(StoreTransaction(transaction, jws: update.jwsRepresentation))
            }
        }
    }

    /// Listen for promoted In-App Purchases the customer started on the App Store
    /// (`PurchaseIntent`, iOS 16.4+). `handler` receives the product id; the caller runs it
    /// through its normal purchase flow. Earlier systems deliver such a purchase as a transaction
    /// without an app account token, which the updates listener reports.
    func startListeningForPurchaseIntents(handler: @escaping @Sendable (String) -> Void) {
        #if os(iOS) || os(macOS)
        guard #available(iOS 16.4, macOS 14.4, *) else { return }
        intentsTask?.cancel()
        intentsTask = Task.detached {
            for await intent in PurchaseIntent.intents {
                handler(intent.product.id)
            }
        }
        #endif
    }

    func stopListening() {
        updatesTask?.cancel()
        updatesTask = nil
        intentsTask?.cancel()
        intentsTask = nil
    }

    /// Fetch `Product`s for the given identifiers (StoreKit provides localized prices).
    ///
    /// `fresh` forces the round trip: a paywall showing prices wants StoreKit's current answer,
    /// and it primes the cache that the Buy tap then reads. Without it, every id has to be
    /// cached and fresh for the cache to answer; a partial hit still goes to StoreKit, so the
    /// caller never receives fewer products than it asked for because some were cached.
    func products(for ids: [String], fresh: Bool = false) async throws -> [Product] {
        if !fresh, let cached = productCache.get(all: ids) { return cached }
        let loaded: [Product]
        if let productsLoader {
            loaded = try await productsLoader(ids)
        } else {
            do {
                loaded = try await Product.products(for: ids)
            } catch {
                throw CashSDKError.network(underlying: error)
            }
        }
        for product in loaded { productCache.put(product.id, product) }
        return loaded
    }

    /// Put a `Product` the app loaded itself where ``purchasableProduct(_:)`` will find it.
    func remember(_ product: Product) {
        productCache.put(product.id, product)
    }

    /// Look a product up for ``purchase(_:appAccountToken:)``.
    func purchasableProduct(_ productId: String) async throws -> PurchasableProduct {
        if purchaseHandler != nil {
            // Tests: stands in for the App Store lookup, which can fail (offline, no product) or
            // take its time.
            try await purchaseLookupHandler?(productId)
            return PurchasableProduct(id: productId, storeProduct: nil)
        }
        guard let product = try await products(for: [productId]).first else {
            throw CashSDKError.productNotFound(productId)
        }
        return PurchasableProduct(id: product.id, storeProduct: product)
    }

    /// Run the purchase flow. Presents the App Store sheet, so it hops to the main actor.
    /// The verified transaction is returned *unfinished*: the caller finishes it after the
    /// server has recorded it, per `08-IOS-SDK.md` §3.
    ///
    /// A thrown StoreKit error is mapped by ``purchaseError(_:productId:)``. A cancellation that
    /// StoreKit reports as an error throws ``CashSDKError/purchaseCancelled``.
    @MainActor
    func purchase(_ product: PurchasableProduct, appAccountToken: UUID?) async throws -> StorePurchaseOutcome {
        if let purchaseHandler { return try await purchaseHandler(product.id, appAccountToken) }
        guard let storeProduct = product.storeProduct else { throw CashSDKError.productNotFound(product.id) }
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken {
            options.insert(.appAccountToken(appAccountToken))
        }

        let result: Product.PurchaseResult
        do {
            result = try await storeProduct.purchase(options: options)
        } catch {
            let mapped = Self.purchaseError(error, productId: product.id)
            if case .productUnavailable = mapped {
                // The id goes to the log for the developer, never into the user-facing message.
                CashSDKLog.warning("The App Store will not sell \(product.id) right now: it is not sold in this storefront, removed from sale, or not yet approved.")
            }
            throw mapped
        }

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                return .verified(StoreTransaction(transaction, jws: verification.jwsRepresentation))
            case .unverified(let transaction, let error):
                // Never grant on an unverified transaction.
                throw CashSDKError.chargedButUnverified(transactionId: String(transaction.id), underlying: CashSDKError.unverifiedTransaction(underlying: error))
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            // A result this SDK does not know. It must not read as a cancellation: if StoreKit
            // did charge, the transaction reaches `Transaction.updates` and is verified there.
            throw CashSDKError.storeKitFailed(underlying: nil)
        }
    }

    /// All currently-entitled, verified transactions paired with their signed JWS, used
    /// for restore and the launch-time backstop (report anything the server hasn't
    /// confirmed).
    func currentEntitlements(reportError: (@Sendable (Error) -> Void)? = nil) async -> [StoreTransaction] {
        if let currentEntitlementsLoader { return await currentEntitlementsLoader() }
        var entries: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                entries.append(StoreTransaction(transaction, jws: result.jwsRepresentation))
            } else {
                reportError?(CashSDKError.unverifiedTransaction(underlying: nil))
            }
        }
        return entries
    }

    /// Every verified transaction StoreKit still holds unfinished: a purchase whose verify
    /// failed, or one that arrived before identify. Consumables only come back this way, since
    /// they are excluded from `currentEntitlements`.
    func unfinishedTransactions(reportError: (@Sendable (Error) -> Void)? = nil) async -> [StoreTransaction] {
        if let unfinishedLoader { return await unfinishedLoader() }
        var entries: [StoreTransaction] = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                entries.append(StoreTransaction(transaction, jws: result.jwsRepresentation))
            } else {
                reportError?(CashSDKError.unverifiedTransaction(underlying: nil))
            }
        }
        return entries
    }

    /// Ask StoreKit to sync with the App Store (the restore path). May prompt for the
    /// App Store password; cancelling that prompt throws ``CashSDKError/purchaseCancelled``.
    func sync() async throws {
        if let syncHandler { try await syncHandler(); return }
        do {
            try await AppStore.sync()
        } catch {
            throw Self.syncError(error)
        }
    }

    // MARK: - Introductory offers

    /// Whether this Apple ID can still get `productId`'s introductory offer.
    func isEligibleForIntroOffer(productId: String) async throws -> Bool {
        if let introEligibilityHandler { return try await introEligibilityHandler(productId) }
        guard let product = try await products(for: [productId]).first(where: { $0.id == productId }) else {
            throw CashSDKError.productNotFound(productId)
        }
        return await Self.isEligibleForIntroOffer(product)
    }

    /// The ids among `products` whose introductory offer this Apple ID can still get.
    func introOfferEligibleIds(_ products: [Product]) async -> Set<String> {
        var eligible: Set<String> = []
        for product in products where !eligible.contains(product.id) {
            if await Self.isEligibleForIntroOffer(product) { eligible.insert(product.id) }
        }
        return eligible
    }

    /// False when the product has no introductory offer (which includes anything but an
    /// auto-renewable subscription), and once this Apple ID has used an introductory offer in
    /// the product's subscription group. Apple applies the offer per group, not per product.
    static func isEligibleForIntroOffer(_ product: Product) async -> Bool {
        guard let subscription = product.subscription, subscription.introductoryOffer != nil else { return false }
        return await subscription.isEligibleForIntroOffer
    }

    // MARK: - Error mapping

    /// The SDK error for a StoreKit purchase failure. Only ``CashSDKError/network(underlying:)``
    /// and ``CashSDKError/storeKitFailed(underlying:)`` leave a charge possible.
    static func purchaseError(_ error: Error, productId: String) -> CashSDKError {
        switch classify(error) {
        case .cancelled: return .purchaseCancelled
        case .alreadySubscribed: return .alreadySubscribed(productId: productId)
        case .notAllowed: return .purchaseNotAllowed
        case .unavailable: return .productUnavailable(productId: productId)
        case .network: return .network(underlying: error)
        case .other: return .storeKitFailed(underlying: error)
        }
    }

    /// The SDK error for a failed `AppStore.sync()`.
    static func syncError(_ error: Error) -> CashSDKError {
        switch classify(error) {
        case .cancelled: return .purchaseCancelled
        case .network: return .network(underlying: error)
        default: return .storeKitFailed(underlying: error)
        }
    }

    /// Sort a StoreKit error into what the user can do about it.
    ///
    /// "Already subscribed" has no StoreKit 2 case of its own. It surfaces as App Store server
    /// error 3532 somewhere in the error chain (`ASDServerErrorDomain`, or `AMSServerErrorCode` in
    /// the user info), usually inside `StoreKitError.systemError` or `.unknown`, so the whole chain
    /// is searched for it first.
    static func classify(_ error: Error) -> StoreFailure {
        let chain = errorChain(error)
        if chain.contains(where: isAlreadySubscribed) { return .alreadySubscribed }
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled: return .cancelled
            case .networkError: return .network
            case .notAvailableInStorefront: return .unavailable
            case .systemError: break // Classified from the wrapped error below.
            default: return .other // .unknown, .notEntitled, .unsupported and later cases.
            }
        }
        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .purchaseNotAllowed: return .notAllowed
            case .productUnavailable: return .unavailable
            // Invalid quantity and the offer errors (the SDK passes no offers), plus later cases.
            default: return .other
            }
        }
        for nsError in chain {
            if nsError.domain == NSURLErrorDomain { return .network }
            guard nsError.domain == SKErrorDomain else { continue }
            switch SKError.Code(rawValue: nsError.code) {
            case .paymentCancelled?: return .cancelled
            case .paymentNotAllowed?: return .notAllowed
            case .storeProductNotAvailable?: return .unavailable
            case .cloudServiceNetworkConnectionFailed?: return .network
            default: continue
            }
        }
        return .other
    }

    /// `error`, then each error it wraps (`StoreKitError.systemError`, `NSUnderlyingErrorKey`).
    private static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var next: Error? = error
        while let current = next, chain.count < 8 {
            if let storeKitError = current as? StoreKitError, case .systemError(let wrapped) = storeKitError {
                next = wrapped
                continue
            }
            let nsError = current as NSError
            chain.append(nsError)
            next = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return chain
    }

    private static func isAlreadySubscribed(_ error: NSError) -> Bool {
        if error.domain == "ASDServerErrorDomain", error.code == 3532 { return true }
        switch error.userInfo["AMSServerErrorCode"] {
        case let code as Int: return code == 3532
        case let code as String: return code == "3532"
        default: return false
        }
    }

    // MARK: - Environment

    /// `"Sandbox"` / `"Production"`, the spelling the API compares against.
    static func environmentName(_ transaction: Transaction) -> String? {
        if #available(iOS 16.0, macOS 13.0, *) {
            switch transaction.environment {
            case .sandbox: return "Sandbox"
            case .production: return "Production"
            default: return nil // .xcode and anything Apple adds later
            }
        }
        return nil
    }

    /// Skip server verification for the non-verifiable Xcode/local StoreKit environment
    /// (`08-IOS-SDK.md` §3); local entitlements still drive the UI.
    ///
    /// The iOS-15 fallback matters: `Transaction.environment` is iOS 16+, and returning `true`
    /// unconditionally meant every Xcode StoreKit-test transaction on an iOS 15 device/simulator
    /// was sent to the server, rejected, never finished, and redelivered by `Transaction.updates`
    /// forever, an infinite verify loop through the whole test session.
    static func isServerVerifiable(_ transaction: Transaction) -> Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            return transaction.environment != .xcode
        }
        return !isXcodeEnvironmentLegacy(transaction)
    }

    /// iOS-15 spelling of `Transaction.environment`. Marked deprecated so its use of the
    /// deprecated property doesn't warn at every call site.
    @available(iOS, deprecated: 16.0, message: "Fallback for iOS 15, which has no Transaction.environment")
    private static func isXcodeEnvironmentLegacy(_ transaction: Transaction) -> Bool {
        #if os(iOS)
        return transaction.environmentStringRepresentation.caseInsensitiveCompare("xcode") == .orderedSame
        #else
        return false
        #endif
    }
}
