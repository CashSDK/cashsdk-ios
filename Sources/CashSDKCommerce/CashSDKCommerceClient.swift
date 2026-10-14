import Foundation

/// Native Stripe commerce for directly distributed Mac apps. No StoreKit or provider secrets.
/// Use a separate instance per authenticated customer. Sessions are held only in memory.
public actor CashSDKCommerceClient {
    public typealias SessionProvider = @Sendable () async throws -> CommerceSessionToken
    /// The longest session CashSDK issues. A session is never reused for longer.
    private static let maxSession: TimeInterval = 600
    /// How long a session whose absolute expiry is already past on this clock is reused.
    private static let shortSession: TimeInterval = 60
    private let publishableKey: String
    private let environment: CommerceEnvironment
    private let customerId: String
    private let origin: String
    private let apiURL: URL
    private let provider: SessionProvider
    private let transport: URLSession
    private let timeout: TimeInterval
    private let purchaseStore: CommercePurchaseStore
    private var session: CommerceSessionToken?
    /// When to stop reusing `session`, on this Mac's clock.
    private var sessionExpiry: Date?
    private var refreshing: (id: UUID, task: Task<CommerceSessionToken, Error>)?
    private var epoch = 0
    private var signedOut = false
    private var snapshot: CommerceEntitlements?
    private var readSequence = 0
    private var acceptedSequence = 0
    private var purchases: [String: Task<CommerceCheckout, Error>] = [:]

    /// - Parameter purchaseStore: where `purchase` keeps its attempts. UserDefaults by default.
    public init(publishableKey: String, environment: CommerceEnvironment, customerId: String,
                origin: String, apiURL: URL = URL(string: "https://api.cashsdk.com")!,
                timeout: TimeInterval = 15, purchaseStore: CommercePurchaseStore = UserDefaultsPurchaseStore(),
                getSessionToken: @escaping SessionProvider) throws {
        try self.init(publishableKey: publishableKey, environment: environment, customerId: customerId,
                      origin: origin, apiURL: apiURL, timeout: timeout,
                      configuration: .ephemeral, purchaseStore: purchaseStore, getSessionToken: getSessionToken)
    }

    // Configuration injection is internal: tests use URLProtocol, callers cannot enable credential redirects.
    init(publishableKey: String, environment: CommerceEnvironment, customerId: String,
         origin: String, apiURL: URL, timeout: TimeInterval, configuration: URLSessionConfiguration,
         purchaseStore: CommercePurchaseStore = UserDefaultsPurchaseStore(),
         getSessionToken: @escaping SessionProvider) throws {
        guard publishableKey.range(of: "^csk_pk_[A-Za-z0-9_]+$", options: .regularExpression) != nil,
              !customerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, customerId.count <= 200,
              timeout.isFinite, (0.1...60).contains(timeout),
              let originURL = URL(string: origin),
              Self.allowedURL(originURL, environment: environment),
              Self.serializedOrigin(originURL) == origin,
              originURL.path.isEmpty, originURL.query == nil, originURL.fragment == nil,
              Self.allowedURL(apiURL, environment: environment),
              (apiURL.path.isEmpty || apiURL.path == "/"), apiURL.query == nil, apiURL.fragment == nil else {
            throw CommerceError(code: "invalid_configuration", message: "Use a publishable key, authenticated customer and exact HTTPS origins (loopback HTTP is allowed in sandbox)")
        }
        self.publishableKey = publishableKey; self.environment = environment; self.customerId = customerId
        self.origin = origin; self.apiURL = apiURL; self.timeout = timeout; self.provider = getSessionToken
        self.purchaseStore = purchaseStore
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.transport = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { transport.invalidateAndCancel() }

    public func getCustomer() async throws -> CommerceCustomer {
        let customer: CommerceCustomer = try await request("GET", "customer")
        try validateIdentity(customer.customerId, customer.environment)
        return customer
    }

    public func getEntitlements() async throws -> CommerceEntitlements {
        readSequence += 1
        let sequence = readSequence
        let value: CommerceEntitlements = try await request("GET", "entitlements")
        try validateIdentity(value.customerId, value.environment)
        guard value.revision >= 0, commerceDate(value.computedAt) != nil,
              value.entitlements.allSatisfy({ !$0.identifier.isEmpty && ($0.expiresAt == nil || commerceDate($0.expiresAt!) != nil) }) else {
            throw CommerceError.invalidResponse
        }
        // Redis recovery can reset the server revision. The request order is authoritative
        // within this client, including what concurrent callers receive for UI updates.
        if sequence < acceptedSequence, let snapshot { return snapshot }
        snapshot = value; acceptedSequence = sequence
        return value
    }

    /// A local UI hint. Protect server resources with a server entitlement check too.
    public func isActive(_ identifier: String) -> Bool { !signedOut && (snapshot?.isActive(identifier) ?? false) }

    public func getSubscriptions() async throws -> CommerceSubscriptions {
        let value: CommerceSubscriptions = try await request("GET", "subscriptions")
        try validateIdentity(value.customerId, value.environment)
        return value
    }

    public func getOfferings() async throws -> CommerceOfferings { try await request("GET", "offerings") }

    /// A checkout with your own key. Prefer `purchase`, which keeps one key per customer and
    /// package for you. Persist the key before sending, and reuse it after an uncertain
    /// result, including after relaunch.
    public func checkout(_ input: CommerceCheckoutInput, idempotencyKey: String) async throws -> CommerceCheckout {
        try Self.validatePackage(input.packageId)
        guard idempotencyKey.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil else {
            throw CommerceError(code: "invalid_idempotency_key", message: "A stable idempotency key of 16 to 128 letters, digits, underscores or hyphens is required")
        }
        try validateReturnURL(input.successUrl); try validateReturnURL(input.cancelUrl)
        let value: CommerceCheckout = try await request("POST", "checkouts", body: JSONEncoder().encode(input), key: idempotencyKey)
        try validateCheckout(value)
        return value
    }

    public func getCheckout(_ id: String) async throws -> CommerceCheckout {
        guard id.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else {
            throw CommerceError(code: "invalid_checkout", message: "Invalid checkout ID")
        }
        let value: CommerceCheckout = try await request("GET", "checkouts/\(id)")
        guard value.id == id else { throw CommerceError.invalidResponse }
        try validateCheckout(value)
        return value
    }

    /// Buy one package: start the customer's checkout for it, or pick up the one already
    /// started, then open `redirectURL()` in the browser.
    ///
    /// One idempotency key is kept per customer and package in the purchase store, saved
    /// before the request; the checkout id is saved before this returns. A lost answer, a
    /// retry or a relaunch therefore reaches the same checkout. An attempt that is over makes
    /// room for the next: an expired or failed checkout (nothing was charged) starts a new one
    /// at once; a complete or `needs_review` one is returned once, and the next call starts a
    /// new attempt. `already_subscribed`, `already_owned` and `already_purchased` also end the
    /// attempt. `checkout_in_progress` and lost connections keep it: call again. A second call
    /// for the same package while one runs joins it.
    public func purchase(_ packageId: String, successURL: URL, cancelURL: URL,
                         connectionId: String? = nil) async throws -> CommerceCheckout {
        guard !signedOut else { throw Self.signedOutError }
        try Self.validatePackage(packageId)
        try validateReturnURL(successURL.absoluteString); try validateReturnURL(cancelURL.absoluteString)
        let input = CommerceCheckoutInput(packageId: packageId, successURL: successURL, cancelURL: cancelURL, connectionId: connectionId)
        let slot = purchaseSlot(packageId)
        if let running = purchases[slot] { return try await running.value }
        let task = Task { try await self.runPurchase(input, slot: slot) }
        purchases[slot] = task
        defer { if purchases[slot] == task { purchases[slot] = nil } }
        return try await task.value
    }

    /// The checkout of the customer's current attempt for a package, read again, or nil when
    /// there is none. An attempt that is over is cleared once read.
    public func getPurchase(_ packageId: String) async throws -> CommerceCheckout? {
        try Self.validatePackage(packageId)
        let slot = purchaseSlot(packageId)
        guard let id = PurchaseAttempt(stored: purchaseStore.value(forKey: slot))?.id else { return nil }
        let checkout = try await savedCheckout(id)
        if checkout?.isOver ?? true { purchaseStore.remove(slot) }
        return checkout
    }

    /// After the customer comes back from the browser: wait for the checkout of their attempt
    /// for a package, as `waitForCheckout` does. Nil when there is no attempt. A checkout that
    /// is over clears the attempt. Then wait for the entitlement: a checkout grants nothing.
    public func waitForPurchase(_ packageId: String, timeout: TimeInterval = 30,
                                interval: TimeInterval = 1) async throws -> CommerceCheckout? {
        try Self.validatePackage(packageId)
        let slot = purchaseSlot(packageId)
        guard let id = PurchaseAttempt(stored: purchaseStore.value(forKey: slot))?.id else { return nil }
        let checkout: CommerceCheckout
        do { checkout = try await waitForCheckout(id, timeout: timeout, interval: interval) }
        catch let error as CommerceError where error.code == "checkout_not_found" {
            purchaseStore.remove(slot)
            return nil
        }
        if checkout.isOver { purchaseStore.remove(slot) }
        return checkout
    }

    private func runPurchase(_ input: CommerceCheckoutInput, slot: String) async throws -> CommerceCheckout {
        let revision = epoch
        var attempt = PurchaseAttempt(stored: purchaseStore.value(forKey: slot))
        if attempt == nil { purchaseStore.remove(slot) }
        if let id = attempt?.id {
            let saved = try await savedCheckout(id)
            if let saved, saved.status == .requiresAction { return saved }
            if saved == nil || saved!.isOver {
                purchaseStore.remove(slot)
                // A purchase that went through, or whose outcome is under review, is the answer.
                // An expired or failed one charged nothing: a new attempt starts now.
                if let saved, saved.status == .complete || saved.status == .needsReview { return saved }
                attempt = nil
            }
            // A pending checkout is asked for again below, with the same key.
        }
        var renewed = false
        while true {
            let fresh = attempt == nil
            let current = attempt ?? PurchaseAttempt(key: UUID().uuidString)
            if fresh { try save(current, slot) }  // Before the request that uses it.
            attempt = current
            var checkout: CommerceCheckout
            do {
                checkout = try await self.checkout(input, idempotencyKey: current.key)
                var wait: UInt64 = 1
                while checkout.status == .pending && wait <= 3 {
                    if attempt?.id != checkout.id {
                        attempt = PurchaseAttempt(key: current.key, id: checkout.id)
                        try save(attempt!, slot)
                    }
                    try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                    guard revision == epoch else { throw CommerceError.identityChanged }
                    checkout = try await self.checkout(input, idempotencyKey: current.key)
                    wait += 1
                }
            } catch let error as CommerceError {
                if finalPurchaseRefusals.contains(error.code) { purchaseStore.remove(slot) }
                else if error.code == "idempotency_conflict" && !fresh && !renewed {
                    // The saved key belongs to another request, for example other return URLs.
                    purchaseStore.remove(slot); attempt = nil; renewed = true
                    continue
                }
                throw error
            }
            if checkout.status == .expired || checkout.status == .failed {
                purchaseStore.remove(slot)
                // A saved key can name an attempt that ended since. Start a new one, once.
                if !fresh && !renewed { attempt = nil; renewed = true; continue }
                return checkout
            }
            if checkout.isOver { purchaseStore.remove(slot); return checkout }
            // Saved before the browser opens, so the way back finds this checkout.
            try save(PurchaseAttempt(key: current.key, id: checkout.id), slot)
            return checkout
        }
    }

    private func purchaseSlot(_ packageId: String) -> String {
        let scope = [apiURL.absoluteString, publishableKey, environment.rawValue, customerId, packageId]
        let encoded = (try? JSONEncoder().encode(scope)).map { String(decoding: $0, as: UTF8.self) } ?? scope.joined(separator: "\n")
        return "cashsdk.purchase:" + encoded
    }

    private func save(_ attempt: PurchaseAttempt, _ slot: String) throws {
        do { try purchaseStore.set(attempt.stored, forKey: slot) }
        catch { throw CommerceError(code: "storage_unavailable", message: "The purchase attempt could not be saved. Nothing was sent.") }
    }

    /// A saved checkout, or nil once CashSDK no longer knows it for this customer.
    private func savedCheckout(_ id: String) async throws -> CommerceCheckout? {
        do { return try await getCheckout(id) }
        catch let error as CommerceError where error.code == "checkout_not_found" { return nil }
    }

    public func openBillingPortal(returnURL: URL) async throws -> CommerceBillingPortal {
        try validateReturnURL(returnURL.absoluteString)
        let value: CommerceBillingPortal = try await request("POST", "billing-portal", body: JSONEncoder().encode(["returnUrl": returnURL.absoluteString]))
        try validateIdentity(value.customerId, value.environment)
        guard value.provider == "stripe" else { throw CommerceError.invalidResponse }
        _ = try value.redirectURL()
        return value
    }

    /// Read a checkout until it is settled or the time runs out. A timeout returns the last
    /// status, which can still be pending: that is not a failed charge. A lost connection, a
    /// timeout, a rate limit or a 5xx does not end the wait before its deadline (Retry-After is
    /// honored); a sign-out, a change of customer or cancellation ends it at once. The delay
    /// starts at `interval` (1 to 5 seconds) and grows by half each time, up to 5 seconds.
    public func waitForCheckout(_ id: String, timeout: TimeInterval = 30,
                                interval: TimeInterval = 1) async throws -> CommerceCheckout {
        try await poll(timeout: timeout, interval: interval, read: { try await self.getCheckout(id) }, done: { $0.settled })
    }

    /// Read access until the entitlement is active or the time runs out, as `waitForCheckout`
    /// does. Access can follow a paid checkout by a few seconds.
    public func waitForEntitlement(_ identifier: String, timeout: TimeInterval = 30,
                                   interval: TimeInterval = 1) async throws -> CommerceEntitlements {
        try await poll(timeout: timeout, interval: interval, read: { try await self.getEntitlements() },
                       done: { $0.isActive(identifier) })
    }

    private func poll<T: Sendable>(timeout: TimeInterval, interval: TimeInterval,
                                   read: () async throws -> T, done: (T) -> Bool) async throws -> T {
        guard timeout.isFinite, (0...300).contains(timeout), interval.isFinite, (1...5).contains(interval) else {
            throw CommerceError(code: "invalid_configuration", message: "Wait timeout must be between zero and 300 seconds and interval between 1 and 5 seconds")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let revision = epoch
        var delay = interval
        var last: T?
        while true {
            var pause = delay
            do {
                let value = try await read()
                last = value
                if done(value) { return value }
            } catch let error as CommerceError where error.retryable {
                guard revision == epoch else { throw CommerceError.identityChanged }
                if Date() >= deadline {
                    if let last { return last }
                    throw error
                }
                pause = max(delay, min(error.retryAfter ?? 0, 30))
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0, let last { return last }
            try await Task.sleep(nanoseconds: UInt64(max(0, min(pause, remaining)) * 1_000_000_000))
            guard revision == epoch else { throw CommerceError.identityChanged }
            delay = min(delay * 1.5, 5)
        }
    }

    /// Clears local access before anything else, then ends this session at CashSDK. A thrown
    /// `CommerceError` (`network_error`, `timeout`, or the server's code) only says CashSDK
    /// could not be told: do not hold your own sign-out for it. Your backend should revoke
    /// every session of the customer on sign-out anyway.
    public func logout() async throws {
        let token = session?.token
        signOutLocally()
        guard let token else { return }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.data(for: makeRequest("DELETE", "sessions/current", token: token)) }
        catch { throw transportError(error) }
        guard let http = response as? HTTPURLResponse else { throw CommerceError.invalidResponse }
        if http.statusCode != 401 && !(200..<300).contains(http.statusCode) { throw serverError(data, http) }
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil, key: String? = nil) async throws -> T {
        guard !signedOut else { throw Self.signedOutError }
        let revision = epoch
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let token = try await sessionToken()
            guard revision == epoch else { throw CommerceError.identityChanged }
            var req = makeRequest(method, path, token: token)
            req.httpBody = body
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let key { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await transport.data(for: req) }
            catch {
                guard revision == epoch else { throw CommerceError.identityChanged }
                throw transportError(error)
            }
            guard revision == epoch else { throw CommerceError.identityChanged }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw CommerceError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 {
                // A key CashSDK refuses is a configuration error. A new session cannot fix it.
                let refusal = serverError(data, http)
                if refusal.code == "invalid_publishable_key" { throw refusal }
                if session?.token == token { session = nil; sessionExpiry = nil }
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw serverError(data, http) }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw CommerceError.invalidResponse }
        }
        throw CommerceError(code: "invalid_web_session", message: "Sign in again", status: 401)
    }

    private func sessionToken() async throws -> String {
        if let session, let sessionExpiry, sessionExpiry.timeIntervalSinceNow > 30 { return session.token }
        let revision = epoch
        let refresh: (id: UUID, task: Task<CommerceSessionToken, Error>)
        if let refreshing { refresh = refreshing }
        else {
            refresh = (UUID(), Task {
                let operation = Task { try await provider() }
                defer { operation.cancel() }
                return try await boundedCommerceTask(operation, timeout: timeout)
            })
            refreshing = refresh
        }
        do {
            let value = try await boundedCommerceTask(refresh.task, timeout: timeout)
            guard revision == epoch else { throw CommerceError.identityChanged }
            guard value.token.range(of: "^csk_ws_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
                  let expiry = Self.sessionExpiry(value, receivedAt: Date()) else {
                throw CommerceError(code: "invalid_web_session", message: "The backend must return a valid customer session")
            }
            session = value
            sessionExpiry = expiry
            if refreshing?.id == refresh.id { refreshing = nil }
            return value.token
        } catch {
            if refreshing?.id == refresh.id { refreshing = nil }
            throw error
        }
    }

    /// When to stop reusing a session, on this Mac's clock. `expiresInSeconds` is relative, so
    /// a clock that is off does not matter. An absolute `expiresAt` already past on this clock
    /// is used for a short while anyway: CashSDK's 401 is what ends a session. Without either,
    /// the session is used until CashSDK refuses it. Nil when the backend says it already ended.
    static func sessionExpiry(_ value: CommerceSessionToken, receivedAt: Date) -> Date? {
        if let seconds = value.expiresInSeconds {
            guard seconds > 0 else { return nil }
            return receivedAt.addingTimeInterval(min(TimeInterval(seconds), maxSession))
        }
        guard let expiresAt = value.expiresAt else { return .distantFuture }
        guard let at = commerceDate(expiresAt) else { return nil }
        let left = at.timeIntervalSince(receivedAt)
        return receivedAt.addingTimeInterval(left > 0 ? min(left, maxSession) : shortSession)
    }

    private func makeRequest(_ method: String, _ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: apiURL.appendingPathComponent("v1/web/\(path)"), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        req.setValue(token, forHTTPHeaderField: "X-CashSDK-Web-Session")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func signOutLocally() {
        epoch += 1; signedOut = true; session = nil; sessionExpiry = nil; snapshot = nil
        refreshing?.task.cancel(); refreshing = nil
        purchases.values.forEach { $0.cancel() }; purchases = [:]
    }

    /// A transport failure as a retryable `network_error` or `timeout`. Never a raw URLError.
    private func transportError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        let timedOut = (error as? URLError)?.code == .timedOut
        return CommerceError(code: timedOut ? "timeout" : "network_error",
                             message: "CashSDK could not be reached. Retry a checkout only with the same idempotency key.",
                             retryable: true)
    }

    private func validateIdentity(_ id: String, _ env: CommerceEnvironment) throws {
        guard env == environment else {
            throw CommerceError(code: "environment_mismatch", message: "The server response does not match this client's customer environment")
        }
        guard id == customerId else {
            signOutLocally()
            throw CommerceError.identityChanged
        }
    }
    private func validateCheckout(_ value: CommerceCheckout) throws {
        guard !value.id.isEmpty, value.environment == environment, value.provider == "stripe", value.accessStatus == "check_entitlements" else { throw CommerceError.invalidResponse }
        // Another sign-in can change the customer behind this client. Never show their checkout.
        if let owner = value.customerId, owner != customerId {
            signOutLocally()
            throw CommerceError.identityChanged
        }
        _ = try value.redirectURL()
    }
    private func validateReturnURL(_ value: String) throws {
        guard let url = URL(string: value), Self.allowedURL(url, environment: environment),
              Self.serializedOrigin(url) == origin, url.fragment == nil, value.count <= 2048 else {
            throw CommerceError(code: "invalid_return_url", message: "Use a return URL on the configured HTTPS origin without credentials or fragments")
        }
    }
    private static func validatePackage(_ packageId: String) throws {
        guard !packageId.isEmpty, packageId.count <= 200 else {
            throw CommerceError(code: "invalid_package", message: "A package ID is required")
        }
    }
    private static let signedOutError = CommerceError(code: "signed_out", message: "Create a new client after signing in")
    private static func serializedOrigin(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
    }
    private static func allowedURL(_ url: URL, environment: CommerceEnvironment) -> Bool {
        guard let host = url.host, !host.isEmpty, !host.contains("*"), url.user == nil, url.password == nil else { return false }
        return url.scheme == "https" || (environment == .sandbox && url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A refused request as a CommerceError. The status decides whether a retry can help (429 and
/// 5xx), so a proxy's HTML page is as retryable as CashSDK's JSON; a JSON body adds the code.
private func serverError(_ data: Data, _ response: HTTPURLResponse) -> CommerceError {
    let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let error = envelope?["error"] as? [String: Any] ?? [:]
    return CommerceError(code: error["code"] as? String ?? "http_\(response.statusCode)",
                         message: error["message"] as? String ?? "The CashSDK request failed",
                         status: response.statusCode,
                         retryable: error["retryable"] as? Bool ?? (response.statusCode == 429 || response.statusCode >= 500),
                         requestId: response.value(forHTTPHeaderField: "X-Request-Id") ?? error["requestId"] as? String,
                         retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
}

/// `Retry-After` in seconds: delay seconds or an HTTP date.
func retryAfter(_ value: String?) -> TimeInterval? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else { return nil }
    return max(0, date.timeIntervalSinceNow)
}
