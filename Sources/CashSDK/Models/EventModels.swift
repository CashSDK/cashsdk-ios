import Foundation

// MARK: - Event wire DTOs (internal)

/// One analytics event in a `POST /v1/events` batch.
///
/// `Codable` (not merely `Encodable`) because the queue behind this type is DURABLE: an event
/// is written to disk the moment it is recorded, so it survives being backgrounded, killed, or
/// offline, and is decoded back on the next launch.
///
/// `id` is the **client event id** and is generated once, at creation time — never at send
/// time. The server dedupes on `[appId, clientEventId]`, so a batch that is retried after a
/// dropped response (routine on mobile) is idempotent instead of double-counting. Regenerating
/// it per attempt would defeat exactly that.
struct EventPayload: Codable, Equatable, Sendable {
    /// Client-generated unique id — the server's dedupe key. Stable across retries.
    let id: String
    let event: String
    let userId: String?
    let placement: String?
    let paywall: String?
    let variant: String?
    let product: String?
    let environment: String?
    let props: [String: JSONValue]?
    /// Epoch milliseconds.
    let ts: Double?

    init(
        id: String = UUID().uuidString,
        event: String,
        userId: String? = nil,
        placement: String? = nil,
        paywall: String? = nil,
        variant: String? = nil,
        product: String? = nil,
        environment: String? = nil,
        props: [String: JSONValue]? = nil,
        ts: Double? = nil
    ) {
        self.id = id
        self.event = event
        self.userId = userId
        self.placement = placement
        self.paywall = paywall
        self.variant = variant
        self.product = product
        self.environment = environment
        self.props = props
        self.ts = ts
    }
}

/// `POST /v1/events` request body — the server accepts a batch (`05-API.md` §6.4).
struct EventBatch: Encodable {
    let events: [EventPayload]
    let platform: String
    let appVersion: String?
}
