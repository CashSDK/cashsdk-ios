import Foundation

/// Locally rejects unusable credentials before StoreKit opens. Signature verification remains
/// on the server; decoding a JWT here never grants access.
///
/// `minimumLifetime` rejects a token that expires within that many seconds as expired: a
/// purchase needs its token to outlive the payment sheet.
func validateIdentityToken(_ token: String?, userId: String, now: Date = Date(), minimumLifetime: TimeInterval = 0, allowUnsignedLocalIdentity: Bool = false) throws {
    guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !(userId.count > 1 && userId.first == "0" && userId.allSatisfy(\.isNumber)) else {
        throw CashSDKError.notIdentified
    }
    if allowUnsignedLocalIdentity && token == nil { return }
    guard let token else { throw CashSDKError.identityTokenRequired }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[2].isEmpty else { throw CashSDKError.identityTokenInvalid }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          claims["sub"] as? String == userId,
          let expiry = claims["exp"] as? Double, expiry.isFinite else {
        throw CashSDKError.identityTokenInvalid
    }
    guard expiry > now.timeIntervalSince1970 + max(0, minimumLifetime) else { throw CashSDKError.identityTokenExpired }
    if let notBefore = claims["nbf"] as? Double, notBefore > now.timeIntervalSince1970 {
        throw CashSDKError.identityTokenInvalid
    }
}

struct ReadyIdentity: Sendable {
    let userId: String
    let token: String?
    let revision: UInt64
    let api: APIClient
}

/// Exposes the owner and session revision used by a completed readiness barrier.
public struct IdentityReadiness: Sendable, Equatable {
    public let userId: String
    public let revision: UInt64
}
