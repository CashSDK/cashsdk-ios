import Foundation
import StoreKit

// MARK: - Paywalls

extension CashSDK {
    /// Resolve the paywall for a placement and present it (SwiftUI). Fire-and-forget:
    /// any failure (no campaign, offline, malformed config) degrades to "advance" — the
    /// host app is never blocked (FR-6.7).
    public func register(placement: String, params: [String: Any]? = nil) {
        Task { await self.resolveAndPresent(placement: placement, params: params) }
    }

    /// Gate a feature behind a placement's paywall.
    ///
    /// ```swift
    /// CashSDK.shared.register(placement: "start_workout") {
    ///     startWorkout()          // runs per the paywall's server-side gating
    /// }
    /// ```
    ///
    /// The dashboard decides — not the app — whether the placement is **gated**
    /// (`feature` runs only once the user actually holds an entitlement) or
    /// **non-gated** (`feature` runs on dismiss regardless, so the same call site
    /// can be a hard gate in one campaign and a soft nudge in another with no code
    /// change). If the user is already entitled the paywall is skipped and
    /// `feature` runs immediately. `feature` runs at most once, on the main actor.
    public func register(
        placement: String,
        params: [String: Any]? = nil,
        handler: PaywallPresentationHandler? = nil,
        feature: @escaping @Sendable @MainActor () -> Void
    ) {
        Task {
            await self.resolveAndPresent(
                placement: placement,
                params: params,
                handler: handler,
                feature: feature
            )
        }
    }

    /// Dry run: what *would* `register` do for this placement right now? Presents
    /// nothing and records no exposure — useful for pre-flighting UI.
    public func getPresentationResult(
        placement: String,
        params: [String: Any]? = nil
    ) async -> PaywallPresentationResult {
        if entitlements.hasAny { return .skipped(.alreadySubscribed) }
        guard let api = apiClient() else { return .skipped(.resolverError) }
        let context = params.map { JSONValue.object($0.mapValues(JSONValue.init(any:))) }
        do {
            let response = try await api.resolvePaywall(placement: placement, context: context)
            if response.holdout == true { return .skipped(.holdout) }
            guard response.paywall?.config != nil else { return .skipped(.noPaywall) }
            return .presented(outcome: .cancelled) // would present; outcome unknown
        } catch {
            return .skipped(.resolverError)
        }
    }

    private func resolveAndPresent(
        placement: String,
        params: [String: Any]?,
        handler: PaywallPresentationHandler? = nil,
        feature: (@Sendable @MainActor () -> Void)? = nil
    ) async {
        // Already entitled → never show a paywall, just run the feature.
        if feature != nil, entitlements.hasAny {
            await self.skip(.alreadySubscribed, placement: placement, handler: handler, feature: feature)
            return
        }

        guard let api = apiClient() else {
            await self.skip(.resolverError, placement: placement, handler: handler, feature: feature)
            return
        }
        let context = params.map { JSONValue.object($0.mapValues(JSONValue.init(any:))) }

        let response: PaywallResolveResponse
        do {
            response = try await api.resolvePaywall(placement: placement, context: context)
        } catch {
            recordEvent("paywall_skip", placement: placement, props: ["reason": .string("resolver_error")])
            if let handler { await MainActor.run { handler.onError?(error) } }
            await self.skip(.resolverError, placement: placement, handler: nil, feature: feature)
            return
        }

        if response.holdout == true {
            await self.skip(.holdout, placement: placement, handler: handler, feature: feature)
            return
        }

        guard let config = response.paywall?.config else {
            recordEvent("paywall_skip", placement: placement, props: ["reason": .string("no_paywall")])
            await self.skip(.noPaywall, placement: placement, handler: nil, feature: feature)
            return
        }

        // Resolve role slots to live StoreKit products so the paywall shows real prices.
        let refs = config.products ?? []
        let products = (try? await storeKit.products(for: refs.map { $0.productId })) ?? []
        var productsByRole: [String: Product] = [:]
        for ref in refs {
            if let product = products.first(where: { $0.id == ref.productId }) {
                productsByRole[ref.role] = product
            }
        }

        let gating = FeatureGating(configValue: config.featureGating)
        await PaywallPresenter.shared.present(
            config: config,
            productsByRole: productsByRole,
            placement: placement,
            variant: response.variantId,
            onFinish: { [weak self] outcome in
                handler?.onDismiss?(outcome)
                guard let feature else { return }
                // Gated: the user must actually hold an entitlement now. Non-gated:
                // run regardless of how the paywall was dismissed.
                let entitled = self?.entitlements.hasAny ?? false
                if gating == .nonGated || entitled {
                    feature()
                }
            }
        )
        if let handler { await MainActor.run { handler.onPresent?() } }
    }

    /// No paywall was shown. Fire `onSkip` and honour the feature closure — a skip
    /// must never strand the caller (an unreachable resolver can't lock a user out).
    private func skip(
        _ reason: PaywallSkipReason,
        placement: String,
        handler: PaywallPresentationHandler?,
        feature: (@Sendable @MainActor () -> Void)?
    ) async {
        await MainActor.run {
            handler?.onSkip?(reason)
            // `noPaywall` / `holdout` / `resolverError` all mean "nothing to gate on",
            // and `alreadySubscribed` means the user has paid — run the feature.
            feature?()
        }
    }
}
