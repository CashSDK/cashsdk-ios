import Foundation
import StoreKit

/// The result of driving StoreKit's purchase flow to completion.
enum StorePurchaseOutcome: Sendable {
    /// A cryptographically verified transaction plus its original signed JWS (the JWS
    /// lives on the `VerificationResult`, not the decoded `Transaction`).
    case verified(transaction: Transaction, jws: String)
    /// Deferred (Ask-to-Buy / SCA). Resolution will arrive on `Transaction.updates`.
    case pending
    /// The user dismissed the App Store sheet.
    case userCancelled
}

/// The StoreKit 2 engine: product loading, the purchase flow, the lifetime
/// `Transaction.updates` listener, and current-entitlement enumeration for restore /
/// launch backstop. This is intentionally UI-free — it hands verified JWS strings back
/// to `CashSDK`, which reports them to `transactions:verify`.
final class StoreKitManager: @unchecked Sendable {
    private var updatesTask: Task<Void, Never>?

    /// Start the `Transaction.updates` listener (FR-2.5). Every incoming transaction —
    /// renewal, revocation, Ask-to-Buy resolution — is delivered to `handler`.
    func startListening(handler: @escaping @Sendable (VerificationResult<Transaction>) async -> Void) {
        updatesTask?.cancel()
        updatesTask = Task.detached {
            for await update in Transaction.updates {
                await handler(update)
            }
        }
    }

    func stopListening() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// Fetch `Product`s for the given identifiers (StoreKit provides localized prices).
    func products(for ids: [String]) async throws -> [Product] {
        do {
            return try await Product.products(for: ids)
        } catch {
            throw CashSDKError.network(underlying: error)
        }
    }

    /// Run the purchase flow. Presents the App Store sheet, so it hops to the main actor.
    /// The verified transaction is returned *unfinished* — the caller finishes it after
    /// (or alongside) reporting, per `08-IOS-SDK.md` §3.
    @MainActor
    func purchase(_ product: Product, appAccountToken: UUID?) async throws -> StorePurchaseOutcome {
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken {
            options.insert(.appAccountToken(appAccountToken))
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: options)
        } catch {
            throw CashSDKError.network(underlying: error)
        }

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                return .verified(transaction: transaction, jws: verification.jwsRepresentation)
            case .unverified(_, let error):
                // Never grant on an unverified transaction.
                throw CashSDKError.unverifiedTransaction(underlying: error)
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .userCancelled
        }
    }

    /// All currently-entitled, verified transactions paired with their signed JWS — used
    /// for restore and the launch-time backstop (report anything the server hasn't
    /// confirmed). The JWS comes from the `VerificationResult`, the transaction from its
    /// verified payload.
    func currentEntitlements() async -> [(transaction: Transaction, jws: String)] {
        var entries: [(transaction: Transaction, jws: String)] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                entries.append((transaction, result.jwsRepresentation))
            }
        }
        return entries
    }

    /// Ask StoreKit to sync with the App Store (the restore path). May prompt for the
    /// App Store password.
    func sync() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw CashSDKError.network(underlying: error)
        }
    }
}
