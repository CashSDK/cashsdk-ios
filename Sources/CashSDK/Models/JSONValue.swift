import Foundation

// MARK: - JSON value

/// A type-safe container for arbitrary JSON, used for open-ended event `props` and
/// `register(placement:params:)` context. Keeps the SDK dependency-free (no `AnyCodable`).
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Best-effort conversion from an untyped `Any` (as passed via `[String: Any]`).
    public init(any value: Any) {
        switch value {
        case let v as JSONValue: self = v
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)           // checked before the numeric cases
        case let v as Int: self = .number(Double(v))
        case let v as Int64: self = .number(Double(v))
        case let v as Double: self = .number(v)
        case let v as NSNumber: self = .number(v.doubleValue)
        case let v as [Any]: self = .array(v.map(JSONValue.init(any:)))
        case let v as [String: Any]: self = .object(v.mapValues(JSONValue.init(any:)))
        case is NSNull: self = .null
        default: self = .null
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
