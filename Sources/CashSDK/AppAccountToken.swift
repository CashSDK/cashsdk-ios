import Foundation

/// Canonical `appAccountToken` derivation (docs/13 §9.2, FR-2.2).
///
/// The value is stamped onto a StoreKit purchase as `Transaction.appAccountToken`; the server maps
/// it back to the app user. It MUST be byte-identical to the server (`deriveAppAccountToken`) and
/// the Android SDK — this mirrors `AppAccountToken` in `packages/cashsdk-android/.../AppAccountToken.kt`
/// method-for-method — or attribution silently misses. Golden vectors on all three guard the parity.
///
/// Scheme: `00000000-0000-4000-8000-<12 lowercase hex>`.
///   • Numeric id (1 … 2^48-1): the 12 hex ARE the id — reversible, matches the backend/seed.
///   • Any other id: FNV-1a-64 over the UTF-8 bytes, folded to the low 48 bits.
///
/// ## Integration constraint: do not pass zero-padded numeric user ids
///
/// The numeric branch embeds the VALUE of the id, so `"7"`, `"07"` and `"007"` all derive the
/// SAME token — identically on the server, on iOS and on Android. If your backend emits
/// zero-padded ids, two different users can share one `appAccountToken`, and their purchases,
/// entitlements and refunds merge onto whichever account the server resolves first.
///
/// Pass the un-padded id to `identify(userId:)`, or use an opaque (non-numeric) id — those take
/// the FNV branch, which is sensitive to every byte including leading zeros. This is a property
/// of the shared derivation, not something a single SDK can correct: changing it here would break
/// byte-parity with the server and silently drop attribution for every existing purchase.
enum AppAccountToken {
    /// Derive the canonical `appAccountToken` from a user id: `00000000-0000-4000-8000-<hex12>`
    /// (docs/13 §9.2, FR-2.2). Byte-identical to the server (`deriveAppAccountToken`) and the
    /// Android SDK (`AppAccountToken.derive`) — golden vectors guard the parity across all three.
    static func appAccountToken(for userId: String) -> UUID? {
        UUID(uuidString: "00000000-0000-4000-8000-\(hex12(userId))")
    }

    /// The 12-hex tail: a NUMERIC id (1 … 2^48-1) embeds itself, so the token is reversible and
    /// matches the backend/seed exactly; any other (opaque) id folds through FNV-1a-48.
    ///
    /// The numeric branch requires PURE ASCII digits to match the server's `/^[0-9]+$/` — a leading
    /// `+`/`-` MUST fall to FNV, otherwise `UInt64("+15551234567")` would embed 15551234567 while the
    /// server FNV-hashes it, and a phone-number user id would silently miss attribution.
    static func hex12(_ userId: String) -> String {
        let allDigits = !userId.isEmpty && userId.allSatisfy { $0 >= "0" && $0 <= "9" }
        if allDigits, let n = UInt64(userId), n > 0, n <= 0xFFFF_FFFF_FFFF {
            return String(format: "%012llx", n)
        }
        return fnv1aHex12(userId)
    }

    private static func fnv1aHex12(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%012llx", hash & 0xFFFF_FFFF_FFFF)
    }
}
