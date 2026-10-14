import AppKit
import CashSDKCommerce
import SwiftUI

@main
struct StripeMacApp: App {
    @StateObject private var model = CommerceModel()
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
                        Button("Sign out") { model.logout() }
                    }
                }
                if model.busy { ProgressView() }
                Text(model.message).textSelection(.enabled).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(28).frame(minWidth: 520, minHeight: 500)
            .disabled(model.busy)
            // Back from the browser. Stripe's events reach CashSDK a few seconds after a payment.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.becameActive() }
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
    /// The package whose checkout was opened in the browser, followed when the app is active again.
    private var awaiting: String?

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
            // Purchase attempts are kept in UserDefaults by the SDK, one per customer and
            // package, so a relaunch resumes the same checkout instead of starting a second one.
            self.client = try CashSDKCommerceClient(publishableKey: self.publishableKey, environment: self.environment,
                customerId: first.customerId, origin: origin, apiURL: api,
                getSessionToken: { try await backendSession(backend, token: token).session })
            self.customerId = first.customerId
            self.connected = true
            self.backendToken = ""
            try await self.readAccess()
        }
    }

    func refresh() async { await perform { try await self.readAccess() } }

    /// After the customer pays in the browser and comes back: follow the payment, then the
    /// access, each for a bounded time. A wait that runs out is not a failed payment.
    func becameActive() async {
        guard connected, !busy else { return }
        guard let packageId = awaiting else { await refresh(); return }
        await perform {
            guard let client = self.client else { return }
            self.message = "Checking your payment…"
            let checkout = try await client.waitForPurchase(packageId, timeout: 30)
            switch checkout?.status {
            case .complete?:
                self.awaiting = nil
                let access = try await client.waitForEntitlement("pro", timeout: 30)
                self.hasAccess = access.isActive("pro")
                try await self.readAccess()
                self.message = self.hasAccess
                    ? "Payment confirmed. Pro access is active."
                    : "Payment confirmed. Access has not arrived yet: refresh in a moment."
            case .requiresAction?, .pending?:
                try await self.readAccess()
                self.message = "The checkout is still open. Finish it in your browser, or buy again to reopen it."
            default:
                // Expired, refused, under review, or nothing left to follow.
                self.awaiting = nil
                try await self.readAccess()
                self.message = checkout.map { "Checkout: \($0.status.rawValue)." } ?? "Access refreshed from CashSDK."
            }
        }
    }

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
            // An older server does not refuse a second subscription by itself.
            let subscriptions = try await client.getSubscriptions()
            if subscriptions.subscriptions.contains(where: { $0.active && $0.productIdentifier == package.product.identifier }) {
                throw SampleError.message("This subscription is already active. Use Manage billing.")
            }
            // Resumes this package's open checkout, or starts one. Each package has its own
            // attempt, and one that is over (paid, expired, refused) makes room for the next.
            let callback = try self.safeURL(self.returnURL)
            let checkout = try await client.purchase(package.id, successURL: callback, cancelURL: callback)
            if let url = try checkout.redirectURL() {
                self.awaiting = package.id
                try self.open(url)
                self.message = "Pay in your browser, then come back to this app."
            } else if checkout.status == .complete {
                self.message = "This purchase is complete. Access follows from the payment."
            } else {
                self.message = "Checkout: \(checkout.status.rawValue). Try again in a moment."
            }
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

    /// Local access is gone at once. Ending the session at CashSDK runs on its own: sign-out
    /// never waits for it. Your backend should revoke every session of the customer as well.
    func logout() {
        let old = client
        disconnect()
        message = "Signed out."
        Task { try? await old?.logout() }
    }

    private func disconnect() {
        client = nil; connected = false; hasAccess = false; packages = []; customerId = ""; awaiting = nil
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await operation() } catch {
            if let error = error as? CommerceError, ["identity_changed", "signed_out"].contains(error.code) {
                disconnect()
            }
            message = error.localizedDescription
        }
    }
    private func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw SampleError.message("Could not open your browser. Buy again to reopen the same checkout.") }
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
    let expiresInSeconds: Int?
    var session: CommerceSessionToken {
        CommerceSessionToken(token: token, expiresAt: expiresAt, expiresInSeconds: expiresInSeconds)
    }
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
