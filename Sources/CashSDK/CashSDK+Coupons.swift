import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Coupons

extension CashSDK {
    /// Check a coupon code for the signed-in user, before showing what it gives.
    ///
    /// Codes are matched without regard to case, with surrounding spaces trimmed. A code the
    /// server refuses comes back with `valid == false` and a ``CouponInvalidReason``; it is not
    /// thrown. Only products that can be redeemed on iOS are listed.
    ///
    /// Throws ``CashSDKError/notIdentified`` when no user is signed in: a coupon is always
    /// redeemed by a known account, never by a guest. A `429` or `503` is retried, honouring
    /// `Retry-After` up to 30 seconds; repeated unknown codes from one user are throttled by the
    /// server and then throw ``CashSDKError/server(status:code:message:)`` with status 429.
    public func validateCoupon(_ code: String) async throws -> CouponValidation {
        guard configuration.value != nil else { throw CashSDKError.notConfigured }
        let identity = try await couponIdentity()
        let request = CouponValidateRequest(code: Self.normalizedCouponCode(code), appUserId: identity.userId, platform: CashSDK.devicePlatform)
        return try await Self.retrying(sleep: retrySleep.value) {
            try await identity.api.validateCoupon(request)
        }
    }

    /// Redeem a coupon on one product: reserve one use for the signed-in user, then open the
    /// App Store's offer code page with the code filled in.
    ///
    /// The purchase itself happens in the App Store. Its transaction reaches the app through
    /// StoreKit's `Transaction.updates`, where the SDK verifies it as this user's purchase and
    /// publishes the new access on ``entitlementUpdates``. Wait for that with
    /// ``awaitCouponCompletion(redemptionId:timeout:)``.
    ///
    /// Calling this again for the same user and coupon returns the same reservation. An unused
    /// reservation is released by the server after 24 hours.
    ///
    /// Throws ``CouponError/rejected(_:)`` when the server refuses the code while reserving it,
    /// ``CashSDKError/notIdentified`` for a guest, ``CashSDKError/purchaseInProgress`` while a
    /// purchase or restore runs, and ``CashSDKError/observerMode`` in observer mode.
    ///
    /// - Parameter productId: the StoreKit product id, one of
    ///   ``CouponValidation/eligibleProductIds``.
    public func redeemCoupon(_ code: String, productId: String) async throws -> CouponRedemptionResult {
        // A money operation: one at a time, like purchase and restore.
        try purchaseOperationGate.begin()
        defer { endMoneyOperation() }
        guard configuration.value?.observerMode != true else { throw CashSDKError.observerMode }
        guard configuration.value != nil else { throw CashSDKError.notConfigured }
        guard currentUserId.value != nil else { throw CashSDKError.notIdentified }
        let identity = try await identityForMoneyOperation(minimumTokenLifetime: 0, fallbackTokenLifetime: 0)
        let request = CouponRedeemRequest(
            code: Self.normalizedCouponCode(code),
            appUserId: identity.userId,
            platform: CashSDK.devicePlatform,
            productIdentifier: productId
        )
        // Safe to retry: the server returns the same reservation for the same user and coupon.
        let reservation = try await Self.retrying(sleep: retrySleep.value) {
            try await identity.api.redeemCoupon(request)
        }
        guard let redemptionId = reservation.redemptionId, !redemptionId.isEmpty else {
            throw CashSDKError.invalidResponse
        }
        guard let url = Self.couponRedeemURL(reservation.ios?.redeemUrl, appleCode: reservation.ios?.appleCode) else {
            throw CouponError.redeemURLUnavailable(productId: productId)
        }
        try Task.checkCancellation()
        // Written before the App Store opens, so the transaction it produces is reported as this
        // user's purchase (claim `purchase`), even after a relaunch.
        await purchaseLog.recordAttempt(productId: productId, userId: identity.userId, couponRedemptionId: redemptionId)
        couponCompletions.expect(redemptionId: redemptionId, userId: identity.userId, productId: productId)
        recordEvent("coupon_redeem_start", product: productId)
        guard await couponURLOpener.value(url) else {
            throw CouponError.couldNotOpenAppStore(redeemURL: url)
        }
        return .openedAppStore(redemptionId: redemptionId, redeemURL: url)
    }

    /// Wait until the purchase a ``redeemCoupon(_:productId:)`` opened the App Store for has
    /// been verified for the signed-in user, or until `timeout` seconds pass.
    ///
    /// Returns ``CouponCompletion/completed(_:)`` with the access after it, or
    /// ``CouponCompletion/timedOut``. A purchase that completes after the timeout is still
    /// verified and published on ``entitlementUpdates``, so gate on entitlements as usual.
    ///
    /// Works across a relaunch. For 24 hours the SDK keeps a record of each offer code purchase
    /// it verified, per user, so a wait that starts after the purchase was already verified (the
    /// app was killed while the user was in the App Store) returns at once. An id this device
    /// opened the App Store for completes on that product's next offer code purchase; an id it
    /// knows nothing about completes on the next offer code purchase verified for the user.
    public func awaitCouponCompletion(redemptionId: String, timeout: TimeInterval = 300) async throws -> CouponCompletion {
        guard let userId = currentUserId.value else { throw CashSDKError.notIdentified }
        if !couponCompletions.isKnown(redemptionId, userId: userId) {
            await settleFromLog(redemptionId: redemptionId, userId: userId, registering: true)
            // A purchase verified while the log was read settles through the tracker if the
            // waiter was registered in time; otherwise it is in the log now.
            if !couponCompletions.isCompleted(redemptionId, userId: userId) {
                await settleFromLog(redemptionId: redemptionId, userId: userId, registering: false)
            }
        }
        let result = await couponCompletions.wait(redemptionId: redemptionId, userId: userId, timeout: timeout)
        try Task.checkCancellation()
        if case .completed(let entitlements) = result, entitlements.userId != nil, entitlements.userId != currentUserId.value {
            throw CashSDKError.identityChanged
        }
        return result
    }

    /// Settle `redemptionId` from the persisted coupon completions, or register what the log
    /// says it waits for.
    private func settleFromLog(redemptionId: String, userId: String, registering: Bool) async {
        switch await purchaseLog.couponCompletion(redemptionId: redemptionId, userId: userId) {
        case .completed(let record):
            let access = entitlements.removingExpiredAccess()
            guard couponCompletions.settle(redemptionId: redemptionId, userId: userId, entitlements: access) else { return }
            if await purchaseLog.markCouponReported(transactionId: record.transactionId, userId: userId) {
                recordEvent("coupon_redeem_success", product: record.productId)
            }
        case .pending(let productId, let startedAt):
            if registering { couponCompletions.expectIfUnknown(redemptionId: redemptionId, userId: userId, productId: productId, startedAt: startedAt) }
        case .unknown:
            if registering { couponCompletions.expectIfUnknown(redemptionId: redemptionId, userId: userId) }
        }
    }

    /// A verified transaction reached the server for `userId`. When it is a fresh offer code
    /// purchase (not a renewal, dated within the 24 hour reservation window), it is kept in the
    /// purchase log for a late waiter and the redemptions waiting on it complete.
    ///
    /// Launch recovery re-verifies current subscriptions, including one bought with an offer
    /// code long ago and still in its discounted periods. Those never complete a redemption.
    func noteCouponTransaction(_ transaction: StoreTransaction, userId: String, entitlements: Entitlements?, now: Date = Date()) async {
        guard CouponCompletionTracker.canSettle(transaction, now: now) else { return }
        let access = (entitlements ?? self.entitlements).removingExpiredAccess()
        let record = await purchaseLog.recordCouponCompletion(transaction, userId: userId, now: now)
        let settled = couponCompletions.complete(
            userId: userId,
            productId: transaction.productId,
            purchaseDate: transaction.purchaseDate,
            redemptionIds: record.redemptionIds,
            entitlements: access
        )
        // Only a purchase that settled a redemption someone was waiting for counts as one.
        guard !settled.isEmpty else { return }
        if await purchaseLog.markCouponReported(transactionId: transaction.id, userId: userId) {
            recordEvent("coupon_redeem_success", product: transaction.productId)
        }
    }

    /// The signed-in identity for a coupon call. A guest is refused before anything is sent.
    private func couponIdentity() async throws -> ReadyIdentity {
        guard currentUserId.value != nil else { throw CashSDKError.notIdentified }
        return try await identityForMoneyOperation(minimumTokenLifetime: 0, fallbackTokenLifetime: 0)
    }

    /// The code as the server matches it: trimmed and upper-cased. The server also normalizes;
    /// doing it here keeps retries and the reservation key identical.
    static func normalizedCouponCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The App Store offer code page to open, or nil when the server's URL cannot be trusted.
    ///
    /// Only an `https://apps.apple.com/redeem` URL is opened: the SDK never opens an arbitrary
    /// address it received over the network. `ctx=offercodes` is added when missing, and `code`
    /// is set to `appleCode` when the server sent one, so the page always opens with the code
    /// that belongs to this reservation.
    static func couponRedeemURL(_ redeemUrl: String?, appleCode: String?) -> URL? {
        guard let redeemUrl, var components = URLComponents(string: redeemUrl),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "apps.apple.com",
              components.path == "/redeem" else { return nil }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "ctx" }) {
            items.insert(URLQueryItem(name: "ctx", value: "offercodes"), at: 0)
        }
        if let appleCode, !appleCode.isEmpty {
            items.removeAll { $0.name == "code" }
            items.append(URLQueryItem(name: "code", value: appleCode))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              items.contains(where: { $0.name == "id" && !($0.value ?? "").isEmpty }) else { return nil }
        components.queryItems = items
        // `+` is legal in a query but reads as a space to some parsers; codes are [A-Z0-9-].
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Opens `url` in the App Store. On the main actor, as UIKit and AppKit require.
    @MainActor
    static func openInAppStore(_ url: URL) async -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        return await UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }
}

// MARK: - Completion tracking

/// Redemptions waiting for their App Store purchase to be verified, in this run of the app, per
/// user. The purchase log keeps verified coupon purchases for 24 hours, for a waiter that starts
/// later.
final class CouponCompletionTracker: @unchecked Sendable {
    /// A redemption as one user sees it. Another user on the device never shares its state.
    private struct Key: Hashable {
        let userId: String
        let redemptionId: String
    }

    private struct Pending {
        /// Nil for an id this run did not start: any offer code purchase for the user completes it.
        let productId: String?
        /// When the redemption started. A purchase dated earlier (a restore of an old offer code
        /// purchase) does not complete it.
        let startedAt: Date
    }

    private struct State {
        var pending: [Key: Pending] = [:]
        var completed: [Key: Entitlements] = [:]
        var waiters: [Key: [UUID: CheckedContinuation<CouponCompletion, Never>]] = [:]
    }

    private let state = Locked(State())

    func expect(redemptionId: String, userId: String, productId: String, now: Date = Date()) {
        let key = Key(userId: userId, redemptionId: redemptionId)
        state.withValue { state in
            state.completed[key] = nil
            state.pending[key] = Pending(productId: productId, startedAt: now)
        }
    }

    /// Wait for `redemptionId` unless this run already knows it. Without a product, any offer
    /// code purchase for the user completes it.
    func expectIfUnknown(redemptionId: String, userId: String, productId: String? = nil, startedAt: Date = .distantPast) {
        let key = Key(userId: userId, redemptionId: redemptionId)
        state.withValue { state in
            guard state.pending[key] == nil, state.completed[key] == nil else { return }
            state.pending[key] = Pending(productId: productId, startedAt: startedAt)
        }
    }

    /// Whether this run is waiting for, or has seen, `redemptionId` for `userId`.
    func isKnown(_ redemptionId: String, userId: String) -> Bool {
        let key = Key(userId: userId, redemptionId: redemptionId)
        return state.withValue { $0.pending[key] != nil || $0.completed[key] != nil }
    }

    func isCompleted(_ redemptionId: String, userId: String) -> Bool {
        let key = Key(userId: userId, redemptionId: redemptionId)
        return state.withValue { $0.completed[key] != nil }
    }

    /// Whether `transaction` may settle a redemption: an offer code purchase, not a renewal,
    /// dated within the reservation's 24 hours. Launch recovery re-verifies an old offer code
    /// subscription still in its discounted periods; that is never a new redemption.
    static func canSettle(_ transaction: StoreTransaction, now: Date) -> Bool {
        guard transaction.isOfferCode, transaction.renewal != true else { return false }
        let age = now.timeIntervalSince(transaction.purchaseDate)
        return age <= PurchaseLog.couponCompletionLifetime && age >= -PurchaseLog.clockSkewAllowance
    }

    /// Settle `redemptionId` from a purchase verified earlier. False when it was already settled.
    @discardableResult
    func settle(redemptionId: String, userId: String, entitlements: Entitlements) -> Bool {
        let key = Key(userId: userId, redemptionId: redemptionId)
        let resumed = state.withValue { state -> [CheckedContinuation<CouponCompletion, Never>]? in
            guard state.completed[key] == nil else { return nil }
            state.pending[key] = nil
            state.completed[key] = entitlements
            return Array((state.waiters.removeValue(forKey: key) ?? [:]).values)
        }
        guard let resumed else { return false }
        resumed.forEach { $0.resume(returning: .completed(entitlements)) }
        return true
    }

    /// An offer code purchase of `productId` was verified for `userId`. Settles that user's
    /// redemptions named in `redemptionIds`, and those waiting on that product since before the
    /// purchase. Returns the ids it settled.
    @discardableResult
    func complete(userId: String, productId: String, purchaseDate: Date, redemptionIds: [String] = [], entitlements: Entitlements) -> [String] {
        let (keys, resumed) = state.withValue { state -> ([Key], [CheckedContinuation<CouponCompletion, Never>]) in
            let keys = state.pending.filter { entry in
                guard entry.key.userId == userId else { return false }
                if redemptionIds.contains(entry.key.redemptionId) { return true }
                return (entry.value.productId ?? productId) == productId
                    && purchaseDate >= entry.value.startedAt.addingTimeInterval(-PurchaseLog.clockSkewAllowance)
            }.map(\.key)
            var continuations: [CheckedContinuation<CouponCompletion, Never>] = []
            for key in keys {
                state.pending[key] = nil
                state.completed[key] = entitlements
                continuations += (state.waiters.removeValue(forKey: key) ?? [:]).values
            }
            return (keys, continuations)
        }
        resumed.forEach { $0.resume(returning: .completed(entitlements)) }
        return keys.map(\.redemptionId)
    }

    func wait(redemptionId: String, userId: String, timeout: TimeInterval) async -> CouponCompletion {
        let key = Key(userId: userId, redemptionId: redemptionId)
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CouponCompletion, Never>) in
                let done = state.withValue { state -> Entitlements? in
                    if let completed = state.completed[key] { return completed }
                    state.waiters[key, default: [:]][token] = continuation
                    return nil
                }
                if let done {
                    continuation.resume(returning: .completed(done))
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    self?.resume(key, token: token, with: .timedOut)
                }
            }
        } onCancel: { [weak self] in
            self?.resume(key, token: token, with: .timedOut)
        }
    }

    private func resume(_ key: Key, token: UUID, with result: CouponCompletion) {
        let continuation = state.withValue { state in state.waiters[key]?.removeValue(forKey: token) }
        continuation?.resume(returning: result)
    }
}
