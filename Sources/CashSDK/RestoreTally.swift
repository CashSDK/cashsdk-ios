import Foundation

/// What happened to one transaction during a recovery or restore pass.
enum BackstopReport {
    /// The server confirmed the purchase for the signed-in account. `transferred` when it moved
    /// here from another account under the app's `transfer` restore policy.
    case confirmed(transactionId: String, transferred: Bool)
    /// The purchase stays with another account in this app.
    case ownedByAnotherAccount(transactionId: String)
    /// The pass could not report something: a verify failure, an unverified transaction, or a
    /// session change.
    case failed(Error)
}

/// Collects one restore pass into a ``RestoreResult``. Counts distinct transactions, since a
/// purchase can appear both in current entitlements and among unfinished transactions.
final class RestoreTally: @unchecked Sendable {
    private struct State {
        var restored: Set<String> = []
        var ownedByAnotherAccount: Set<String> = []
        var transferred: Set<String> = []
        var failure: Error?
    }

    private let state = Locked(State())

    func record(_ report: BackstopReport) {
        state.withValue { state in
            switch report {
            case .confirmed(let id, let transferred):
                state.restored.insert(id)
                if transferred { state.transferred.insert(id) }
            case .ownedByAnotherAccount(let id):
                state.ownedByAnotherAccount.insert(id)
            case .failed(let error):
                if state.failure == nil { state.failure = error }
            }
        }
    }

    /// The first failure, if any. A restore with one throws rather than report a partial result.
    var failure: Error? { state.value.failure }

    func result(entitlements: Entitlements) -> RestoreResult {
        let state = state.value
        return RestoreResult(
            restoredCount: state.restored.count,
            ownedByAnotherAccountCount: state.ownedByAnotherAccount.subtracting(state.restored).count,
            transferredCount: state.transferred.count,
            entitlements: entitlements
        )
    }
}
