import Foundation

/// Native Stripe commerce for directly distributed Mac apps. No StoreKit or provider secrets.
/// Use a separate instance per authenticated customer. Sessions are held only in memory.
public actor CashSDKCommerceClient {
    public typealias SessionProvider = @Sendable () async throws -> CommerceSessionToken
    private let publishableKey: String
    private let environment: CommerceEnvironment
    private let customerId: String
    private let origin: String
    private let apiURL: URL
    private let provider: SessionProvider
    private let transport: URLSession
    private let timeout: TimeInterval
    private var session: CommerceSessionToken?
    private var refreshing: (id: UUID, task: Task<CommerceSessionToken, Error>)?
    private var epoch = 0
    private var signedOut = false
    private var snapshot: CommerceEntitlements?
    private var readSequence = 0
    private var acceptedSequence = 0

    public init(publishableKey: String, environment: CommerceEnvironment, customerId: String,
                origin: String, apiURL: URL = URL(string: "https://api.cashsdk.com")!,
                timeout: TimeInterval = 15, getSessionToken: @escaping SessionProvider) throws {
        try self.init(publishableKey: publishableKey, environment: environment, customerId: customerId,
                      origin: origin, apiURL: apiURL, timeout: timeout,
                      configuration: .ephemeral, getSessionToken: getSessionToken)
    }

    // Configuration injection is internal: tests use URLProtocol, callers cannot enable credential redirects.
    init(publishableKey: String, environment: CommerceEnvironment, customerId: String,
         origin: String, apiURL: URL, timeout: TimeInterval, configuration: URLSessionConfiguration,
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

    /// Persist the key before sending. Reuse it after an uncertain result, including after relaunch.
    public func checkout(_ input: CommerceCheckoutInput, idempotencyKey: String) async throws -> CommerceCheckout {
        guard idempotencyKey.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil,
              !input.packageId.isEmpty else {
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

    public func openBillingPortal(returnURL: URL) async throws -> CommerceBillingPortal {
        try validateReturnURL(returnURL.absoluteString)
        let value: CommerceBillingPortal = try await request("POST", "billing-portal", body: JSONEncoder().encode(["returnUrl": returnURL.absoluteString]))
        try validateIdentity(value.customerId, value.environment)
        guard value.provider == "stripe" else { throw CommerceError.invalidResponse }
        _ = try value.redirectURL()
        return value
    }

    /// A timeout returns the last status, which can still be pending. It is not a failed charge.
    public func waitForCheckout(_ id: String, timeout: TimeInterval = 30) async throws -> CommerceCheckout {
        try validateWait(timeout)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let revision = epoch
        while true {
            let value = try await getCheckout(id)
            if value.settled || ProcessInfo.processInfo.systemUptime >= deadline { return value }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard revision == epoch else { throw CommerceError.identityChanged }
        }
    }

    public func waitForEntitlement(_ identifier: String, timeout: TimeInterval = 30) async throws -> CommerceEntitlements {
        try validateWait(timeout)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let revision = epoch
        while true {
            let value = try await getEntitlements()
            if value.isActive(identifier) || ProcessInfo.processInfo.systemUptime >= deadline { return value }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard revision == epoch else { throw CommerceError.identityChanged }
        }
    }

    /// Clears local access immediately and attempts to revoke the current server session.
    /// Your backend should also revoke all sessions for this customer on account sign-out.
    public func logout() async throws {
        let token = session?.token
        epoch += 1; signedOut = true; session = nil; snapshot = nil
        refreshing?.task.cancel(); refreshing = nil
        guard let token else { return }
        var req = makeRequest("DELETE", "sessions/current", token: token)
        req.timeoutInterval = timeout
        let (data, response) = try await transport.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CommerceError.invalidResponse }
        if http.statusCode != 401 && !(200..<300).contains(http.statusCode) { throw serverError(data, http) }
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil, key: String? = nil) async throws -> T {
        guard !signedOut else { throw CommerceError(code: "signed_out", message: "Create a new client after signing in") }
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
                if Task.isCancelled { throw CancellationError() }
                let timedOut = (error as? URLError)?.code == .timedOut
                throw CommerceError(code: timedOut ? "timeout" : "network_error", message: "CashSDK could not be reached. Retry a checkout only with the same idempotency key.", retryable: true)
            }
            guard revision == epoch else { throw CommerceError.identityChanged }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw CommerceError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 {
                if session?.token == token { session = nil }
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw serverError(data, http) }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw CommerceError.invalidResponse }
        }
        throw CommerceError(code: "invalid_web_session", message: "Sign in again", status: 401)
    }

    private func sessionToken() async throws -> String {
        if let session, let expiry = session.expiresAt.flatMap(commerceDate), expiry.timeIntervalSinceNow > 30 { return session.token }
        if let session, session.expiresAt == nil { return session.token }
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
                  value.expiresAt == nil || (value.expiresAt.flatMap(commerceDate)?.timeIntervalSinceNow ?? 0) > 0 else {
                throw CommerceError(code: "invalid_web_session", message: "The backend must return a valid customer session")
            }
            session = value
            if refreshing?.id == refresh.id { refreshing = nil }
            return value.token
        } catch {
            if refreshing?.id == refresh.id { refreshing = nil }
            throw error
        }
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

    private func validateIdentity(_ id: String, _ env: CommerceEnvironment) throws {
        guard id == customerId, env == environment else {
            epoch += 1; signedOut = true; session = nil; snapshot = nil
            refreshing?.task.cancel(); refreshing = nil
            throw CommerceError.identityChanged
        }
    }
    private func validateCheckout(_ value: CommerceCheckout) throws {
        guard !value.id.isEmpty, value.environment == environment, value.provider == "stripe", value.accessStatus == "check_entitlements" else { throw CommerceError.invalidResponse }
        _ = try value.redirectURL()
    }
    private func validateReturnURL(_ value: String) throws {
        guard let url = URL(string: value), Self.allowedURL(url, environment: environment),
              Self.serializedOrigin(url) == origin, url.fragment == nil, value.count <= 2048 else {
            throw CommerceError(code: "invalid_return_url", message: "Use a return URL on the configured HTTPS origin without credentials or fragments")
        }
    }
    private func validateWait(_ timeout: TimeInterval) throws {
        guard timeout.isFinite, (0...300).contains(timeout) else {
            throw CommerceError(code: "invalid_configuration", message: "Wait timeout must be between zero and 300 seconds")
        }
    }
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

private func serverError(_ data: Data, _ response: HTTPURLResponse) -> CommerceError {
    let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let error = envelope?["error"] as? [String: Any] ?? [:]
    let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    return CommerceError(code: error["code"] as? String ?? "http_\(response.statusCode)",
                         message: error["message"] as? String ?? "The CashSDK request failed",
                         status: response.statusCode,
                         retryable: error["retryable"] as? Bool ?? (response.statusCode == 429 || response.statusCode >= 500),
                         requestId: response.value(forHTTPHeaderField: "X-Request-Id") ?? error["requestId"] as? String,
                         retryAfter: retry.map { max(0, $0) })
}
