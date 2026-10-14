import Foundation
import Security

/// The identity persisted across launches: who the SDK last identified, and the signed
/// token that proves it to the server.
struct StoredIdentity: Codable, Sendable, Equatable {
    let userId: String
    let userToken: String?
}

/// Keychain-backed identity persistence.
///
/// Why persist at all: StoreKit redelivers unfinished transactions *at launch*, usually before
/// the host app has called `identify(...)`. With no identity the SDK cannot report them (the
/// server would credit nobody), so it must leave them unfinished — and a consumable the user
/// already paid for strands until someone happens to call `restore()`. Restoring the last known
/// identity during `bootstrap()` lets the launch backstop run immediately.
///
/// Why the Keychain and not `UserDefaults`: `userToken` is a bearer credential. The Keychain is
/// the most secure store the platform offers without extra entitlements, and
/// `kSecAttrAccessibleAfterFirstUnlock` keeps it readable from a background launch.
///
/// Every operation fails silently: the SDK must never crash or throw because the Keychain is
/// unavailable (it is, for example, in some unit-test hosts and command-line targets).
final class IdentityStore: @unchecked Sendable {
    private let service: String
    private let account = "current-user"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = "com.cashsdk.identity") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Use the data-protection keychain on every platform so the same code path works
            // on macOS hosts (CI, unit tests) without a keychain-access-group entitlement.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() -> StoredIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let identity = try? decoder.decode(StoredIdentity.self, from: data) else {
            return nil
        }
        return identity
    }

    func save(userId: String, userToken: String?) {
        guard let data = try? encoder.encode(StoredIdentity(userId: userId, userToken: userToken)) else {
            return
        }
        // Delete-then-add rather than SecItemUpdate: it is one code path for both
        // "first identify" and "re-identify with a freshly minted token".
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
