import Foundation

struct PaywallFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static let pending = PaywallFeedback(title: "Purchase pending", message: "Your purchase is waiting for approval. Access will update when it is confirmed; you do not need to buy again.")
    static let nothingToRestore = PaywallFeedback(title: "Restore complete", message: "No active purchases were found for this app account. Check that you are signed in to the app and App Store accounts used to purchase.")
    static let ownedByAnotherAccount = PaywallFeedback(title: "Purchases belong to another account", message: "The purchases on this Apple ID belong to another account in this app. Sign in to that account to use them.")

    /// What to show after a restore finished, or nil when access came back and the paywall
    /// can close.
    static func restoreFinished(_ result: RestoreResult) -> PaywallFeedback? {
        if result.entitlements.hasAny { return nil }
        return result.outcome == .ownedByAnotherAccount ? .ownedByAnotherAccount : .nothingToRestore
    }

    /// What to show after a purchase or restore threw, or nil for a cancellation, which needs
    /// no message. Only errors that come before any charge may say anything other than "payment
    /// may have completed".
    static func failure(_ error: Error, restoring: Bool) -> PaywallFeedback? {
        let title = restoring ? "Restore not completed" : "Purchase not confirmed"
        let message: String
        switch cause(of: error) {
        case CashSDKError.purchaseCancelled:
            return nil
        case CashSDKError.purchaseBelongsToAnotherAccount:
            message = "This purchase belongs to another app account. Sign in to the account that owns it, then restore purchases."
        case CashSDKError.alreadySubscribed:
            return PaywallFeedback(title: "Already subscribed", message: "Your Apple ID already has this subscription, possibly under another account in this app. Restore purchases, or sign in to the account you subscribed with.")
        case CashSDKError.purchaseNotAllowed:
            return PaywallFeedback(title: "Purchases not allowed", message: "This device or Apple ID cannot make purchases. Check Screen Time or parental controls, then try again.")
        case CashSDKError.productUnavailable, CashSDKError.productNotFound:
            return PaywallFeedback(title: "Plan unavailable", message: "This plan is not available right now. Try again later or choose another plan.")
        case CashSDKError.purchaseNotAttributed:
            message = "Please sign in again, then restore purchases. If payment completed, do not buy again."
        case CashSDKError.notIdentified, CashSDKError.identityTokenRequired, CashSDKError.identityTokenInvalid,
             CashSDKError.identityTokenExpired, CashSDKError.identityChanged:
            // Thrown before the App Store sheet opens: nothing was charged.
            message = restoring ? "Please sign in again, then restore purchases." : "Please sign in again, then try your purchase."
        case CashSDKError.purchaseInProgress:
            message = "A purchase or restore is already running. Wait for it to finish."
        case CashSDKError.network where !restoring:
            return PaywallFeedback(title: "Purchase not completed", message: "The App Store could not be reached. Check your connection and try again. If a payment went through, your access will update on its own.")
        case CashSDKError.storeKitFailed where !restoring:
            return PaywallFeedback(title: "Purchase not completed", message: "The App Store did not complete the purchase. If a payment went through, your access will update on its own. Otherwise, try again.")
        default:
            message = restoring
                ? "We could not complete the restore. Check your connection and try restoring again."
                : "We could not confirm your purchase. Payment may have completed. Check your purchases or restore before buying again."
        }
        return PaywallFeedback(title: title, message: message)
    }

    /// A restore failure arrives wrapped; its cause decides the message. An ownership conflict
    /// inside it is not a connection problem.
    private static func cause(of error: Error) -> Error {
        var current = error
        while case CashSDKError.restoreVerificationFailed(let underlying) = current {
            current = underlying
        }
        return current
    }
}
