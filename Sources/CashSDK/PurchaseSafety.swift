import Foundation

/// Serialize user-initiated money operations without queuing a second purchase sheet.
final class PurchaseOperationGate: @unchecked Sendable {
    private let busy = Locked(false)

    func begin() throws {
        let acquired = busy.withValue { value in
            if value { return false }
            value = true
            return true
        }
        if !acquired { throw CashSDKError.purchaseInProgress }
    }

    func end() { busy.value = false }
}

func requirePurchaseAttribution(attributed: Bool, belongsToAnotherAccount: Bool?) throws {
    guard attributed else { throw CashSDKError.purchaseNotAttributed }
    if belongsToAnotherAccount == true { throw CashSDKError.purchaseBelongsToAnotherAccount }
}
