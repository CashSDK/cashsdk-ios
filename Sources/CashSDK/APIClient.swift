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
    private var identityRevision: UInt64 = 0

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

    /// How long one request may take before it is abandoned, and how long a whole
    /// request-and-retry may run.
    ///
    /// `URLSession.shared` waits **60 seconds** for a response and 7 days for the resource. On a
    /// money path that is not a timeout, it is a hang: a verify that retries three times against
    /// a network that accepts the connection and then goes quiet kept a customer on a spinner for
    /// three minutes after paying. Android has always used 15s/20s here. A read that has produced
    /// nothing in 15 seconds is not about to succeed, and the transaction is not lost by giving
    /// up: it stays unfinished and the next recovery pass reports it.
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60

    /// The session used when the host does not inject one. Not `URLSession.shared`, which cannot
    /// be given timeouts without changing them for everything else in the app.
    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // A purchase verify must not be served from a cache, and none of these responses are
        // cacheable by URLCache anyway: freshness is carried by our own ETags.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    init(configuration: CashSDKConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.defaultSession()
        self.environment = configuration.environment
    }

    /// Install both identity headers in one actor turn, so no request sees a mixed pair.
    func setIdentity(userId: String?, userToken: String?) {
        identityRevision &+= 1
        if self.userId != userId { etags.removeAll() }
        self.userId = userId
        self.userToken = userToken
    }

    /// Swap in a fresh token for the SAME user. Unlike ``setIdentity(userId:userToken:)`` this
    /// starts no new identity revision: a response to a request sent with the old token still
    /// describes this user, so nothing in flight is discarded. `false` if `userId` is not the
    /// user this client speaks for.
    func replaceUserToken(_ token: String, for userId: String) -> Bool {
        guard self.userId == userId else { return false }
        userToken = token
        return true
    }

    /// Set the store environment header value. Changing it invalidates the entitlements ETag —
    /// the two environments are different content, so revalidating one against the other's ETag
    /// would answer `304` and leave the wrong snapshot in place.
    func adoptEnvironment(_ environment: String) {
        guard configuration.environment == nil else { return }
        setEnvironment(environment)
    }

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
        /// The store environment the server resolved this purchase into, from the
        /// `X-CashSDK-Environment` response header.
        ///
        /// Read from the HEADER rather than the body because a verify can answer `304`, and a
        /// 304 carries no body. That is not a corner case on iOS 15: `Transaction.environment`
        /// is iOS 16+, so on 15 the server's answer is the only source, and the re-report a
        /// relaunch makes through `launchBackstop` is exactly the call that 304s once the
        /// snapshot is unchanged. Without this the SDK would fall back to the app's default
        /// environment and a sandbox tester's entitlements would read back empty.
        let environment: String?
    }

    /// A throttled verify or entitlement read: `429`, or `503`, with the server's `Retry-After`
    /// when it sent one.
    ///
    /// Only ``verify(signedTransaction:claim:)`` and ``fetchEntitlements(environment:revalidate:)``
    /// throw this, and it never leaves the SDK: `CashSDK` notes the wait and rethrows `error`,
    /// the plain ``CashSDKError/server(status:code:message:)``.
    struct Throttled: Error {
        let error: CashSDKError
        /// Seconds to wait, from `Retry-After`; nil when the header was absent or unreadable.
        let retryAfter: TimeInterval?
    }

    /// `POST /v1/transactions:verify` — report a StoreKit 2 `jwsRepresentation`.
    ///
    /// Safe to retry: the server dedupes by transaction id, so a repeated report of the same
    /// JWS is idempotent.
    ///
    /// `claim` goes out as `X-CashSDK-Claim`. The server lets only `purchase` and `restore` move
    /// a purchase between app accounts (under the app's restore policy); `sync` never changes
    /// ownership.
    func verify(signedTransaction jws: String, claim: VerifyClaim) async throws -> VerifyOutcome {
        let body = try encoder.encode(VerifyRequest(signedTransaction: jws))
        let (data, response) = try await send(
            path: "v1/transactions:verify",
            method: "POST",
            extraHeaders: ["X-CashSDK-Claim": claim.rawValue],
            body: body
        )
        // A 304 can only come from the attributed branch — the server computes an ETag from a
        // *resolved* snapshot, which requires a user.
        let environment = response.value(forHTTPHeaderField: "X-CashSDK-Environment")
        if response.statusCode == 304 {
            return VerifyOutcome(
                entitlements: nil,
                attributed: true,
                etag: etags[entitlementsETagKey],
                environment: environment
            )
        }
        if response.statusCode == 429 || response.statusCode == 503 {
            throw Throttled(
                error: Self.serverError(status: response.statusCode, data: data),
                retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        try ensureSuccess(response, data)
        let decoded = try decode(Entitlements.self, from: data)
        let attributed = Self.isAttributed(data, decoded: decoded)
        // Only an attributed response describes this user's entitlements, so only that one may
        // prime the shared ETag slot. Caching the unattributed empty body's ETag would make the
        // next entitlements read 304 against a snapshot that was never ours.
        guard attributed else {
            return VerifyOutcome(
                entitlements: decoded,
                attributed: false,
                etag: nil,
                environment: environment
            )
        }
        captureETag(response, key: entitlementsETagKey)
        return VerifyOutcome(
            entitlements: decoded,
            attributed: true,
            etag: etags[entitlementsETagKey],
            environment: environment
        )
    }

    /// `GET /v1/entitlements` — the ultra-hot read path. Returns `nil` on `304`.
    ///
    /// `revalidate: false` sends no `If-None-Match`, so the server answers with the full
    /// snapshot even when it has not changed. The refresh at an entitlement's `expiresAt` needs
    /// that answer: a `304` there would only confirm a snapshot whose deadline just passed.
    func fetchEntitlements(environment: String? = nil, revalidate: Bool = true) async throws -> Entitlements? {
        var headers: [String: String] = [:]
        // An explicit per-call override still wins; otherwise `send` stamps the client-wide one.
        if let environment { headers["X-CashSDK-Environment"] = environment }
        let (data, response) = try await send(
            path: "v1/entitlements",
            method: "GET",
            extraHeaders: headers,
            etagKey: revalidate ? entitlementsETagKey : nil
        )
        if response.statusCode == 304 { return nil }
        if response.statusCode == 429 || response.statusCode == 503 {
            throw Throttled(
                error: Self.serverError(status: response.statusCode, data: data),
                retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
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

    /// `GET /v1/offerings/current` — the offering this app would present right now.
    ///
    /// Deliberately the DEVICE endpoint, not the `/v1/offerings` on the public API: that one
    /// authenticates with a secret key, which reads the whole revenue ledger and must never
    /// ship inside an app.
    func currentOffering() async throws -> Offering? {
        let (data, response) = try await send(path: "v1/offerings/current", method: "GET")
        try ensureSuccess(response, data)
        return try decode(OfferingsResponse.self, from: data).current
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
        let requestIdentityRevision = identityRevision
        let requestEnvironment = environment
        // The SDK owns an owner-scoped snapshot and its ETag. URLCache must not substitute a
        // second, independently persisted body or turn a 304 into a stale successful read.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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
            guard identityRevision == requestIdentityRevision, environment == requestEnvironment else {
                throw CashSDKError.notIdentified
            }
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

    /// `Retry-After` as seconds from `now`. The header is either delta-seconds or an HTTP date
    /// (RFC 9110 §10.2.3). Nil when absent or unreadable; never negative.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds.isFinite ? max(0, seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
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
