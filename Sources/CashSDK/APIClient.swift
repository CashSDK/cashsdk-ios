import Foundation

/// The device REST client (`05-API.md` §6). An `actor` so its mutable state — the
/// current user id and the per-resource ETag store — is isolated and `Sendable`-safe.
///
/// Every request carries `Authorization: Bearer <publishableKey>` and, once a user is
/// identified, `X-CashSDK-User-Id: <userId>`. Entitlement reads use `If-None-Match` /
/// `ETag` so an unchanged snapshot answers `304` with no body.
actor APIClient {
    private let configuration: CashSDKConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Set once the host calls `identify(userId:)`.
    private var userId: String?

    /// The signed user token (`X-CashSDK-User-Token`), minted by the app's backend (HS256 over
    /// its per-app secret) and passed to `identify(userId:userToken:)`. This is what the server
    /// TRUSTS in production — a raw `X-CashSDK-User-Id` is only honoured outside production, so
    /// without this every identified device call (verify, entitlements, consumables) 401s live.
    private var userToken: String?

    /// Per-resource ETag cache, keyed by a stable resource name.
    private var etags: [String: String] = [:]

    /// Verify and entitlement reads resolve to the same content resource, so they share
    /// one ETag slot: a verify response primes the cache that the next GET revalidates.
    private let entitlementsETagKey = "entitlements"

    /// The store environment (`"Sandbox"` / `"Production"`) sent as `X-CashSDK-Environment`.
    ///
    /// Entitlements are resolved PER ENVIRONMENT server-side. With no header the API falls back
    /// to the app's default (normally `Production`), so a TestFlight/sandbox purchase would be
    /// verified into `Sandbox` and then immediately "disappear" on the next entitlements read —
    /// which resolved `Production` and returned nothing. It is either configured explicitly or
    /// learned from the first verified StoreKit transaction (see `CashSDK.noteEnvironment`).
    private var environment: String?

    init(configuration: CashSDKConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.environment = configuration.environment
    }

    func setUserId(_ userId: String?) {
        self.userId = userId
    }

    func setUserToken(_ userToken: String?) {
        self.userToken = userToken
    }

    /// Set the store environment header value. Changing it invalidates the entitlements ETag —
    /// the two environments are different content, so revalidating one against the other's ETag
    /// would answer `304` and leave the wrong snapshot in place.
    func setEnvironment(_ environment: String?) {
        guard self.environment != environment else { return }
        self.environment = environment
        etags[entitlementsETagKey] = nil
    }

    /// The environment currently being sent, if any.
    func currentEnvironment() -> String? { environment }

    /// Drop the entitlements ETag so the next read re-fetches a full body instead of a `304`.
    /// Called on logout / user change — otherwise a stale `If-None-Match` would 304 and keep the
    /// previous user's snapshot after we've reset it to empty.
    func clearEntitlementsETag() {
        etags[entitlementsETagKey] = nil
    }

    /// Restore the ETag that belongs to a snapshot just hydrated from disk. The ETag and the
    /// snapshot it describes are persisted together, so they are restored together.
    func setEntitlementsETag(_ etag: String?) {
        etags[entitlementsETagKey] = etag
    }

    /// The current entitlements ETag, so the caller can persist it alongside the snapshot.
    func entitlementsETag() -> String? { etags[entitlementsETagKey] }

    // MARK: - Endpoints

    /// The outcome of a `transactions:verify` call.
    ///
    /// `attributed` is the important field. The API answers `200` even when it could not map
    /// the transaction to a user (no `appAccountToken`, no trusted user token — e.g. a promoted
    /// App Store purchase that lands before `identify()`), and the body it returns in that case
    /// is a perfectly well-formed *empty* snapshot. Treating it as success wipes a good cache and
    /// — far worse — finishes the transaction, destroying a consumable the user paid for.
    struct VerifyOutcome: Sendable {
        /// The fresh snapshot, or `nil` when the server answered `304` (unchanged).
        let entitlements: Entitlements?
        /// `false` when the server credited the purchase to nobody.
        let attributed: Bool
        /// The ETag describing `entitlements`, to be persisted with it.
        let etag: String?
    }

    /// `POST /v1/transactions:verify` — report a StoreKit 2 `jwsRepresentation`.
    ///
    /// Safe to retry: the server dedupes by transaction id, so a repeated report of the same
    /// JWS is idempotent.
    func verify(signedTransaction jws: String) async throws -> VerifyOutcome {
        let body = try encoder.encode(VerifyRequest(signedTransaction: jws))
        let (data, response) = try await send(
            path: "v1/transactions:verify",
            method: "POST",
            body: body,
            etagKey: entitlementsETagKey
        )
        // A 304 can only come from the attributed branch — the server computes an ETag from a
        // *resolved* snapshot, which requires a user.
        if response.statusCode == 304 {
            return VerifyOutcome(entitlements: nil, attributed: true, etag: etags[entitlementsETagKey])
        }
        try ensureSuccess(response, data)
        let decoded = try decode(Entitlements.self, from: data)
        let attributed = Self.isAttributed(data, decoded: decoded)
        // Only an attributed response describes this user's entitlements, so only that one may
        // prime the shared ETag slot. Caching the unattributed empty body's ETag would make the
        // next entitlements read 304 against a snapshot that was never ours.
        guard attributed else {
            return VerifyOutcome(entitlements: decoded, attributed: false, etag: nil)
        }
        captureETag(response, key: entitlementsETagKey)
        return VerifyOutcome(entitlements: decoded, attributed: true, etag: etags[entitlementsETagKey])
    }

    /// `GET /v1/entitlements` — the ultra-hot read path. Returns `nil` on `304`.
    func fetchEntitlements(environment: String? = nil) async throws -> Entitlements? {
        var headers: [String: String] = [:]
        // An explicit per-call override still wins; otherwise `send` stamps the client-wide one.
        if let environment { headers["X-CashSDK-Environment"] = environment }
        let (data, response) = try await send(
            path: "v1/entitlements",
            method: "GET",
            extraHeaders: headers,
            etagKey: entitlementsETagKey
        )
        if response.statusCode == 304 { return nil }
        try ensureSuccess(response, data)
        captureETag(response, key: entitlementsETagKey)
        return try decode(Entitlements.self, from: data)
    }

    /// Decide whether a `200` from `transactions:verify` was actually credited to a user.
    ///
    /// Preference order:
    ///  1. An explicit `attributed` / `userId` field, if the API ever adds one (see the SDK
    ///     handoff note) — authoritative, and this code then needs no heuristic.
    ///  2. Otherwise: the attributed branch of `VerifyController` ALWAYS returns a
    ///     `consumables` array alongside the snapshot, while the unattributed early-return is
    ///     exactly `{ entitlements: [], tier: 0, tierIdentifier: null }` with no `consumables`
    ///     key. A missing `consumables` key together with an empty entitlement list is
    ///     therefore the unattributed shape.
    ///
    /// Deliberately biased towards "attributed" when the body cannot be inspected: a false
    /// negative here strands a legitimate purchase, which is worse than the (already handled)
    /// case of applying an empty snapshot.
    /// `internal` (not `private`) so the unit tests can exercise the real server response
    /// bodies without standing up a URL protocol stub.
    static func isAttributed(_ data: Data, decoded: Entitlements) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        if let explicit = object["attributed"] as? Bool { return explicit }
        if let userId = object["userId"] as? String { return !userId.isEmpty }
        if object["consumables"] != nil { return true }
        return !decoded.entitlements.isEmpty
    }

    /// `POST /v1/consumables:spend` — debit a consumable balance.
    ///
    /// `idempotencyKey` is REQUIRED by the server: a dropped response on mobile is
    /// routine, and an unkeyed retry would double-spend the user's balance.
    func spendConsumable(
        productIdentifier: String,
        units: Int,
        idempotencyKey: String,
        note: String?
    ) async throws -> ConsumableSpendResult {
        let body = try encoder.encode(
            SpendRequest(
                productIdentifier: productIdentifier,
                units: units,
                idempotencyKey: idempotencyKey,
                note: note
            )
        )
        let (data, response) = try await send(
            path: "v1/consumables:spend",
            method: "POST",
            body: body
        )
        try ensureSuccess(response, data)
        return try decode(ConsumableSpendResult.self, from: data)
    }

    /// `GET /v1/paywalls:resolve?placement=…` — the server resolves app + campaign +
    /// audience from the key (+ user). Optional targeting `context` is passed as a
    /// JSON-encoded query item.
    func resolvePaywall(placement: String, context: JSONValue?) async throws -> PaywallResolveResponse {
        var query = [URLQueryItem(name: "placement", value: placement)]
        if let context,
           let data = try? encoder.encode(context),
           let json = String(data: data, encoding: .utf8) {
            query.append(URLQueryItem(name: "context", value: json))
        }
        let (data, response) = try await send(path: "v1/paywalls:resolve", method: "GET", query: query)
        try ensureSuccess(response, data)
        return try decode(PaywallResolveResponse.self, from: data)
    }

    /// `POST /v1/events` — fire-and-forget telemetry batch (`202 Accepted`).
    func sendEvents(_ batch: EventBatch) async throws {
        let body = try encoder.encode(batch)
        let (data, response) = try await send(path: "v1/events", method: "POST", body: body)
        try ensureSuccess(response, data)
    }

    // MARK: - Plumbing

    private func send(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        extraHeaders: [String: String] = [:],
        body: Data? = nil,
        etagKey: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let userId {
            request.setValue(userId, forHTTPHeaderField: "X-CashSDK-User-Id")
        }
        if let userToken {
            request.setValue(userToken, forHTTPHeaderField: "X-CashSDK-User-Token")
        }
        // Stamped on EVERY request, not just entitlement reads: verify, entitlements and
        // paywall resolution all resolve per-environment server-side, and mixing them is what
        // makes a sandbox purchase vanish from the next read.
        if let environment {
            request.setValue(environment, forHTTPHeaderField: "X-CashSDK-Environment")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let etagKey, let etag = etags[etagKey] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CashSDKError.invalidResponse }
            return (data, http)
        } catch let error as CashSDKError {
            throw error
        } catch {
            throw CashSDKError.network(underlying: error)
        }
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        var base = configuration.apiBase.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        // Built by string so verb-suffixed paths (`transactions:verify`) keep their colon.
        guard var components = URLComponents(string: base + "/" + path) else {
            throw CashSDKError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CashSDKError.invalidResponse }
        return url
    }

    private func captureETag(_ response: HTTPURLResponse, key: String) {
        if let etag = response.value(forHTTPHeaderField: "ETag") {
            etags[key] = etag
        }
    }

    private func ensureSuccess(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw Self.serverError(status: response.statusCode, data: data)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CashSDKError.invalidResponse
        }
    }

    /// Parse the error body. The API returns either `{ "error": "code_string" }`
    /// (device guards) or the richer `{ "error": { code, message, … } }` envelope.
    private static func serverError(status: Int, data: Data) -> CashSDKError {
        var code: String?
        var message: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let string = object["error"] as? String {
                code = string
            } else if let dictionary = object["error"] as? [String: Any] {
                code = dictionary["code"] as? String
                message = dictionary["message"] as? String
            }
        }
        return .server(status: status, code: code, message: message)
    }
}
