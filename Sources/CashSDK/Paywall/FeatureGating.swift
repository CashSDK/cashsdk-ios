import Foundation

/// How a presented paywall ended.
public enum PaywallDismissOutcome: Sendable, Equatable {
    case purchased
    case restored
    case cancelled
    case error
}

/// Why a paywall was NOT shown for a `register` call.
public enum PaywallSkipReason: Sendable, Equatable {
    /// The user already holds the required entitlement.
    case alreadySubscribed
    /// The resolver put this user in the experiment holdout.
    case holdout
    /// No campaign/paywall is configured for the placement.
    case noPaywall
    /// The resolver failed (offline, 5xx, malformed config).
    case resolverError
}

/// The result of a `register` call — mirrors what a dry run would report.
public enum PaywallPresentationResult: Sendable, Equatable {
    case presented(outcome: PaywallDismissOutcome)
    case skipped(PaywallSkipReason)
}

/// Optional lifecycle callbacks for a `register` call. Every closure is optional;
/// exactly one terminal callback (`onDismiss`, `onSkip`, or `onError`) fires.
public struct PaywallPresentationHandler: Sendable {
    public var onPresent: (@Sendable @MainActor () -> Void)?
    public var onDismiss: (@Sendable @MainActor (PaywallDismissOutcome) -> Void)?
    public var onSkip: (@Sendable @MainActor (PaywallSkipReason) -> Void)?
    public var onError: (@Sendable @MainActor (Error) -> Void)?

    public init(
        onPresent: (@Sendable @MainActor () -> Void)? = nil,
        onDismiss: (@Sendable @MainActor (PaywallDismissOutcome) -> Void)? = nil,
        onSkip: (@Sendable @MainActor (PaywallSkipReason) -> Void)? = nil,
        onError: (@Sendable @MainActor (Error) -> Void)? = nil
    ) {
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.onSkip = onSkip
        self.onError = onError
    }
}

/// Server-side gating mode from the paywall config's `feature_gating`.
enum FeatureGating: String {
    /// Run the feature only when the user actually holds an entitlement.
    case gated
    /// Run the feature when the paywall is dismissed, regardless of purchase.
    case nonGated = "non_gated"

    init(configValue: String?) {
        // Default to non-gated: a misconfigured paywall must never permanently
        // lock a user out of their own app.
        self = FeatureGating(rawValue: configValue ?? "") ?? .nonGated
    }
}
