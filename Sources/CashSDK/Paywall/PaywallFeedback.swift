import Foundation

struct PaywallFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static let pending = PaywallFeedback(title: "Purchase pending", message: "Your purchase is waiting for approval. Access will update when it is confirmed; you do not need to buy again.")
    static let nothingToRestore = PaywallFeedback(title: "Restore complete", message: "No active purchases were found for this app account. Check that you are signed in to the app and App Store accounts used to purchase.")

    static func failure(_ error: Error, restoring: Bool) -> PaywallFeedback {
        let message: String
        switch error {
        case CashSDKError.purchaseBelongsToAnotherAccount:
            message = "This purchase belongs to another app account. Sign in to the account that owns it, then restore purchases."
        case CashSDKError.notIdentified, CashSDKError.purchaseNotAttributed:
            message = "Please sign in again, then restore purchases. If payment completed, do not buy again."
        case CashSDKError.purchaseInProgress:
            message = "A purchase or restore is already running. Wait for it to finish."
        default:
            message = restoring
                ? "We could not complete the restore. Check your connection and try restoring again."
                : "We could not confirm your purchase. Payment may have completed. Check your purchases or restore before buying again."
        }
        return PaywallFeedback(title: restoring ? "Restore not completed" : "Purchase not confirmed", message: message)
    }
}
