import Foundation

// MARK: - Paywall config (schema_version 2 component tree)

/// A resolved paywall configuration — the JSON stored in `PaywallVersion.config` and
/// returned by `paywalls:resolve`. This is the `schema_version: 2` "component tree"
/// shape that the dashboard's AI builder emits and the seed templates use.
///
/// The renderer (`PaywallView`) tolerates missing/extra fields: unknown component
/// types render as nothing, and absent optional fields fall back to sensible defaults.
public struct PaywallConfig: Codable, Sendable {
    public let schemaVersion: Int?
    /// `"fullscreen"` or `"sheet"`.
    public let presentation: String?
    /// `"gated"` (dismiss ≠ proceed) or `"non_gated"`.
    public let featureGating: String?
    public let theme: PaywallTheme?
    public let products: [PaywallProductRef]?
    public let root: PaywallComponent?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case presentation
        case featureGating = "feature_gating"
        case theme
        case products
        case root
    }

    /// Whether this paywall wants to be presented as a sheet rather than fullscreen.
    public var prefersSheet: Bool { presentation == "sheet" }
}

public struct PaywallTheme: Codable, Sendable {
    public let accent: String?
    public let background: String?
    public let text: String?
    public let cornerRadius: Double?
    public let darkMode: String?

    enum CodingKeys: String, CodingKey {
        case accent, background, text
        case cornerRadius = "corner_radius"
        case darkMode = "dark_mode"
    }
}

/// Maps a role slot (`primary` / `secondary`) to a concrete product id.
/// Accepts both the AI-schema key `product_id` and the seed key `id`.
public struct PaywallProductRef: Codable, Sendable {
    public let role: String
    public let productId: String
    public let badge: String?

    enum CodingKeys: String, CodingKey {
        case role, badge
        case productId = "product_id"
        case id
    }

    public init(role: String, productId: String, badge: String? = nil) {
        self.role = role
        self.productId = productId
        self.badge = badge
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = (try container.decodeIfPresent(String.self, forKey: .role)) ?? "primary"
        badge = try container.decodeIfPresent(String.self, forKey: .badge)
        if let productId = try container.decodeIfPresent(String.self, forKey: .productId) {
            self.productId = productId
        } else {
            self.productId = (try container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(productId, forKey: .productId)
        try container.encodeIfPresent(badge, forKey: .badge)
    }
}

/// One node in the paywall component tree. `indirect` because a stack contains children.
public indirect enum PaywallComponent: Codable, Sendable {
    case stack(PaywallStack)
    case text(PaywallText)
    case image(PaywallImage)
    case featureList(PaywallFeatureList)
    case productSelector(PaywallProductSelector)
    case timer(PaywallTimer)
    case carousel(PaywallCarousel)
    case comparisonTable(PaywallComparisonTable)
    case badge(PaywallBadge)
    case button(PaywallButton)
    case divider
    case spacer(PaywallSpacer)
    /// Forward-compat: a `type` the SDK doesn't know. Rendered as nothing.
    case unknown(String)

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "stack": self = .stack(try PaywallStack(from: decoder))
        case "text": self = .text(try PaywallText(from: decoder))
        case "image": self = .image(try PaywallImage(from: decoder))
        case "feature_list": self = .featureList(try PaywallFeatureList(from: decoder))
        case "product_selector": self = .productSelector(try PaywallProductSelector(from: decoder))
        case "timer": self = .timer(try PaywallTimer(from: decoder))
        case "carousel": self = .carousel(try PaywallCarousel(from: decoder))
        case "comparison_table": self = .comparisonTable(try PaywallComparisonTable(from: decoder))
        case "badge": self = .badge(try PaywallBadge(from: decoder))
        case "button": self = .button(try PaywallButton(from: decoder))
        case "divider": self = .divider
        case "spacer": self = .spacer((try? PaywallSpacer(from: decoder)) ?? PaywallSpacer(size: nil))
        default: self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .stack(let value): try container.encode("stack", forKey: .type); try value.encode(to: encoder)
        case .text(let value): try container.encode("text", forKey: .type); try value.encode(to: encoder)
        case .image(let value): try container.encode("image", forKey: .type); try value.encode(to: encoder)
        case .featureList(let value): try container.encode("feature_list", forKey: .type); try value.encode(to: encoder)
        case .productSelector(let value): try container.encode("product_selector", forKey: .type); try value.encode(to: encoder)
        case .timer(let value): try container.encode("timer", forKey: .type); try value.encode(to: encoder)
        case .carousel(let value): try container.encode("carousel", forKey: .type); try value.encode(to: encoder)
        case .comparisonTable(let value): try container.encode("comparison_table", forKey: .type); try value.encode(to: encoder)
        case .badge(let value): try container.encode("badge", forKey: .type); try value.encode(to: encoder)
        case .button(let value): try container.encode("button", forKey: .type); try value.encode(to: encoder)
        case .divider: try container.encode("divider", forKey: .type)
        case .spacer(let value): try container.encode("spacer", forKey: .type); try value.encode(to: encoder)
        case .unknown(let type): try container.encode(type, forKey: .type)
        }
    }
}

public struct PaywallStack: Codable, Sendable {
    /// `"vertical"` (default) or `"horizontal"`.
    public let axis: String?
    public let spacing: Double?
    public let padding: Double?
    /// `"center"` (default), `"leading"`, or `"trailing"`.
    public let align: String?
    public let children: [PaywallComponent]?
}

public struct PaywallText: Codable, Sendable {
    /// `"title"`, `"subtitle"`, `"body"`, or `"legal"` — drives default typography.
    public let role: String?
    public let text: String?
    public let style: PaywallTextStyle?
}

public struct PaywallTextStyle: Codable, Sendable {
    public let size: Double?
    /// `"regular"`, `"medium"`, or `"bold"`.
    public let weight: String?
    public let color: String?
    /// `"center"` or `"left"`.
    public let align: String?
}

public struct PaywallImage: Codable, Sendable {
    public let assetId: String?
    public let url: String?
    public let aspect: Double?
    public let cornerRadius: Double?

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case url, aspect
        case cornerRadius = "corner_radius"
    }
}

public struct PaywallFeatureList: Codable, Sendable {
    public let items: [PaywallFeatureItem]?
}

public struct PaywallFeatureItem: Codable, Sendable {
    /// `"check"`, `"star"`, `"bolt"`, or `"heart"`.
    public let icon: String?
    public let text: String?
}

public struct PaywallProductSelector: Codable, Sendable {
    /// `"vertical_cards"` (default) or `"horizontal"`.
    public let layout: String?
    /// Subset of roles to show, e.g. `["primary"]`. Defaults to all configured roles.
    public let products: [String]?
    /// The role selected by default.
    public let defaultRole: String?

    enum CodingKeys: String, CodingKey {
        case layout, products
        case defaultRole = "default"
    }
}

public struct PaywallTimer: Codable, Sendable {
    public let mode: String?
    public let endsInSec: Double?

    enum CodingKeys: String, CodingKey {
        case mode
        case endsInSec = "ends_in_sec"
    }
}

public struct PaywallCarousel: Codable, Sendable {
    public let slides: [PaywallSlide]?
}

public struct PaywallSlide: Codable, Sendable {
    public let type: String?
    public let quote: String?
    public let author: String?
    public let rating: Int?
}

public struct PaywallComparisonTable: Codable, Sendable {
    public let columns: [String]?
    public let rows: [PaywallComparisonRow]?
}

public struct PaywallComparisonRow: Codable, Sendable {
    public let label: String?
    public let values: [Bool]?
}

public struct PaywallBadge: Codable, Sendable {
    public let text: String?
    /// `"popular"`, `"save"`, or `"deal"`.
    public let variant: String?
}

public struct PaywallButton: Codable, Sendable {
    /// `"cta"`, `"restore"`, or `"secondary"`.
    public let role: String?
    public let text: String?
    /// `"purchase_selected"`, `"restore"`, or `"dismiss"`.
    public let action: String?
}

public struct PaywallSpacer: Codable, Sendable {
    public let size: Double?
}

// MARK: - Paywall resolve wire DTOs (internal)

/// `GET /v1/paywalls:resolve` response.
struct PaywallResolveResponse: Decodable {
    let paywall: PaywallEnvelope?
    let variantId: String?
    let experimentId: String?
    /// `true` when the resolver put this user in the experiment holdout — no
    /// paywall shows, and that absence is itself the measured treatment.
    let holdout: Bool?
    /// The app's current offering, returned alongside the paywall so product ids
    /// are never hardcoded in the host app.
    let offering: Offering?
}

struct PaywallEnvelope: Decodable {
    let config: PaywallConfig
}
