import AppKit
import CashSDKCommerce
import CryptoKit
import SwiftUI

@main
struct StripeMacApp: App {
    @StateObject private var model = CommerceModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup("CashSDK Stripe") {
            VStack(alignment: .leading, spacing: 16) {
                Text("CashSDK for macOS").font(.title)
                Text("Sign in through your backend, buy with Stripe, and read verified access.").foregroundStyle(.secondary)
                if !model.connected {
                    TextField("Publishable key (csk_pk_…)", text: $model.publishableKey)
                    TextField("CashSDK API", text: $model.apiURL)
                    TextField("Backend customer session endpoint", text: $model.backendURL)
                    TextField("Hosted checkout return URL", text: $model.returnURL)
                    SecureField("Your signed-in backend session token", text: $model.backendToken)
                    Picker("Environment", selection: $model.environment) {
                        Text("Sandbox").tag(CommerceEnvironment.sandbox)
                        Text("Production").tag(CommerceEnvironment.production)
                    }
                    Button("Connect") { Task { await model.connect() } }
                } else {
                    Text(model.customerId).font(.headline)
                    ForEach(model.packages) { package in
                        Button(package.product.displayName ?? package.identifier) {
                            Task { await model.buy(package) }
                        }.disabled(!package.purchasable)
                    }
                    Text(model.hasAccess ? "Pro access is active" : "Pro access is not active")
                    HStack {
                        Button("Refresh access") { Task { await model.refresh() } }
                        Button("Manage billing") { Task { await model.portal() } }
                        Button("Sign out") { Task { await model.logout() } }
                    }
                }
                if model.busy { ProgressView() }
                Text(model.message).textSelection(.enabled).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(28).frame(minWidth: 520, minHeight: 500)
            .disabled(model.busy)
            .onChange(of: phase) { _, phase in
                if phase == .active && model.connected { Task { await model.refresh() } }
            }
        }
    }
}

@MainActor
final class CommerceModel: ObservableObject {
    @Published var publishableKey = ""
    @Published var apiURL = "https://api.cashsdk.com"
    @Published var backendURL = ""
    @Published var returnURL = ""
    @Published var backendToken = ""
    @Published var environment = CommerceEnvironment.sandbox
    @Published var connected = false
    @Published var busy = false
    @Published var customerId = ""
    @Published var packages: [CommercePackage] = []
    @Published var hasAccess = false
    @Published var message = "Use your merchant session token. Never paste a Stripe or CashSDK server key."
    private var client: CashSDKCommerceClient?
    private var attemptKey = ""
    private struct Attempt: Codable {
        let packageId: String
        let key: String
        var checkoutId: String?
    }

    func connect() async {
        await perform {
            guard !self.backendToken.isEmpty,
                  !["csk_sk_", "csk_rk_", "sk_live_", "sk_test_", "rk_live_", "rk_test_"].contains(where: self.backendToken.hasPrefix) else {
                throw SampleError.message("Use your signed-in merchant session token.")
            }
            let backend = try self.safeURL(self.backendURL)
            let callback = try self.safeURL(self.returnURL)
            let api = try self.safeURL(self.apiURL)
            let token = self.backendToken
            let origin = "\(callback.scheme!)://\(callback.host!)\(callback.port.map { ":\($0)" } ?? "")"
            let first = try await backendSession(backend, token: token)
            self.client = try CashSDKCommerceClient(publishableKey: self.publishableKey, environment: self.environment,
                customerId: first.customerId, origin: origin, apiURL: api,
                getSessionToken: { try await backendSession(backend, token: token).session })
            self.customerId = first.customerId
            let scope = [self.apiURL, self.publishableKey, self.environment.rawValue, first.customerId].joined(separator: "\n")
            self.attemptKey = "cashsdk.checkout." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
            self.connected = true
            self.backendToken = ""
            try await self.readAccess()
        }
    }
    func refresh() async { await perform { try await self.readAccess() } }
    private func readAccess() async throws {
        guard let client else { return }
        let access = try await client.getEntitlements()
        packages = try await client.getOfferings().current?.packages ?? []
        hasAccess = access.isActive("pro")
        message = "Access refreshed from CashSDK."
    }
    func buy(_ package: CommercePackage) async {
        await perform {
            guard let client = self.client else { return }
            let subscriptions = try await client.getSubscriptions()
            if subscriptions.subscriptions.contains(where: { $0.active && $0.productIdentifier == package.product.identifier }) {
                throw SampleError.message("This subscription is already active. Use Manage billing.")
            }
            var attempt = UserDefaults.standard.data(forKey: self.attemptKey).flatMap { try? JSONDecoder().decode(Attempt.self, from: $0) }
            if let id = attempt?.checkoutId {
                let checkout = try await client.getCheckout(id)
                if let url = try checkout.redirectURL() { try self.open(url); return }
                if checkout.status != .expired && checkout.status != .failed {
                    try await self.readAccess()
                    self.message = "Checkout: \(checkout.status.rawValue). Refresh access after payment."
                    return
                }
                attempt = nil
            }
            if let attempt, attempt.packageId != package.id { throw SampleError.message("Resolve the pending checkout before selecting another plan.") }
            if attempt == nil { attempt = Attempt(packageId: package.id, key: UUID().uuidString) }
            var pending = attempt!
            UserDefaults.standard.set(try JSONEncoder().encode(pending), forKey: self.attemptKey)
            let callback = try self.safeURL(self.returnURL)
            let checkout = try await client.checkout(CommerceCheckoutInput(packageId: pending.packageId, successURL: callback, cancelURL: callback), idempotencyKey: pending.key)
            pending.checkoutId = checkout.id
            UserDefaults.standard.set(try JSONEncoder().encode(pending), forKey: self.attemptKey)
            if let url = try checkout.redirectURL() { try self.open(url) }
            self.message = "Checkout: \(checkout.status.rawValue). Return to this app after payment."
        }
    }
    func portal() async {
        await perform {
            guard let client = self.client else { return }
            let portal = try await client.openBillingPortal(returnURL: self.safeURL(self.returnURL))
            try self.open(portal.redirectURL())
            self.message = "Billing opened in your browser."
        }
    }
    func logout() async {
        await perform {
            let old = self.client
            self.client = nil; self.connected = false; self.hasAccess = false; self.packages = []; self.customerId = ""
            try await old?.logout()
            self.message = "Signed out."
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await operation() } catch {
            if let error = error as? CommerceError, ["identity_changed", "signed_out"].contains(error.code) {
                client = nil; connected = false; hasAccess = false; packages = []; customerId = ""
            }
            message = error.localizedDescription
        }
    }
    private func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw SampleError.message("Could not open your browser. Retry with the same checkout.") }
    }
    private func safeURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (environment == .sandbox && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")) else {
            throw SampleError.message("Use HTTPS, or loopback HTTP in sandbox.")
        }
        return url
    }
}

private enum SampleError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
private struct BackendSession: Decodable {
    let customerId: String
    let token: String
    let expiresAt: String?
    var session: CommerceSessionToken { CommerceSessionToken(token: token, expiresAt: expiresAt) }
}
private func backendSession(_ url: URL, token: String) async throws -> BackendSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForResource = 15
    let session = URLSession(configuration: configuration, delegate: RefuseRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SampleError.message("Your backend refused the session. Sign in again.") }
    return try JSONDecoder().decode(BackendSession.self, from: data)
}
private final class RefuseRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
