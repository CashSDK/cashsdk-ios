import Foundation

// MARK: - Offerings

/// A named group of packages the app can present (the current offering is what
/// `paywalls:resolve` returns). Mirrors the server's Offering → Package spine.
public struct Offering: Codable, Sendable, Identifiable {
    public let id: String
    public let identifier: String
    public let displayName: String?
    public let isCurrent: Bool
    public let packages: [Package]

    /// Look a package up by its slot identifier, e.g. `offering["$annual"]`.
    public subscript(identifier: String) -> Package? {
        packages.first { $0.identifier == identifier }
    }

    public var monthly: Package? { self["$monthly"] }
    public var annual: Package? { self["$annual"] }
    public var lifetime: Package? { self["$lifetime"] }
}

/// One slot in an offering, bound to a store product.
public struct Package: Codable, Sendable, Identifiable {
    public let id: String
    /// `$monthly` | `$annual` | `$lifetime` | custom.
    public let identifier: String
    public let position: Int
    public let product: PackageProduct
}

public struct PackageProduct: Codable, Sendable {
    public let id: String
    /// The store product identifier to purchase.
    public let identifier: String
    public let store: String
    public let type: String
    public let duration: String?
    public let price: Int?
    public let currency: String?
    public let displayName: String?
}
