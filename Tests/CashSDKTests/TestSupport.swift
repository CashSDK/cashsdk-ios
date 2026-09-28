import Foundation
import XCTest
@testable import CashSDK

/// A user token shaped like the backend's (the device never checks the signature).
func fixtureToken(_ user: String, expiresIn seconds: TimeInterval = 3600) -> String {
    let claims: [String: Any] = ["sub": user, "exp": Date().timeIntervalSince1970 + seconds]
    let data = try! JSONSerialization.data(withJSONObject: claims)
    let payload = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// An ISO 8601 timestamp `seconds` from now, with milliseconds.
func isoDate(fromNow seconds: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(seconds))
}

/// A request as the stub received it. The body is read once, on arrival, because URLSession
/// hands it to a protocol as a stream.
struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var jws: String? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object["signedTransaction"] as? String
    }
}

/// One stubbed API per test. Requests are routed by host, and every server gets its own, so a
/// late request from an SDK built by an earlier test never shows up in this test's log.
final class StubServer: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }
    typealias Handler = @Sendable (RecordedRequest) -> Response

    let host = "\(UUID().uuidString.lowercased()).fixture.invalid"
    var baseURL: URL { URL(string: "https://\(host)")! }
    private let handler = Locked<Handler?>(nil)
    private let log = Locked<[RecordedRequest]>([])

    init(_ handler: Handler? = nil) {
        self.handler.value = handler
        StubProtocol.register(self)
    }

    func respond(_ handler: @escaping Handler) { self.handler.value = handler }

    var requests: [RecordedRequest] { log.value }
    var verifies: [RecordedRequest] { requests.filter { $0.path == "/v1/transactions:verify" } }
    var entitlementReads: [RecordedRequest] { requests.filter { $0.path == "/v1/entitlements" } }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    fileprivate func handle(_ request: RecordedRequest) -> Response {
        log.withValue { $0.append(request) }
        if let handler = handler.value { return handler(request) }
        // Telemetry is fire-and-forget; anything else unstubbed is a server error.
        return Response(status: request.path == "/v1/events" ? 202 : 500)
    }
}

final class StubProtocol: URLProtocol {
    private static let servers = Locked<[String: StubServer]>([:])

    static func register(_ server: StubServer) {
        servers.withValue { $0[server.host] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = Self.servers.value[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        let response = server.handle(recorded)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Server bodies, shaped like `VerifyController` answers them.
enum Fixture {
    static var pro: [String: Any] { ["identifier": "pro", "name": "Pro", "rank": 2, "source": "subscription"] }

    static func verified(
        user: String,
        entitlements: [[String: Any]] = [pro],
        transferred: Bool = false,
        confirmed: Bool = true
    ) -> StubServer.Response {
        StubServer.Response(status: 200, body: json([
            "entitlements": entitlements,
            "tier": entitlements.isEmpty ? 0 : 2,
            "tierIdentifier": entitlements.isEmpty ? NSNull() : "pro",
            "consumables": [],
            "attributed": true,
            "belongsToAnotherAccount": false,
            "transferredFromAnotherAccount": transferred,
            "purchaseOutcomeConfirmed": confirmed,
            "userId": user,
        ]))
    }

    static let ownedByAnotherAccount = StubServer.Response(status: 200, body: json([
        "entitlements": [], "tier": 0, "tierIdentifier": NSNull(), "consumables": [],
        "attributed": true, "belongsToAnotherAccount": true, "transferredFromAnotherAccount": false,
    ]))

    static func entitlements(user: String, _ entitlements: [[String: Any]] = [pro], tier: Int = 2) -> StubServer.Response {
        StubServer.Response(status: 200, body: json([
            "entitlements": entitlements, "tier": tier, "tierIdentifier": NSNull(),
            "consumables": [], "userId": user,
        ]))
    }
}

/// Records which transactions were finished.
final class FinishLog: @unchecked Sendable {
    private let ids = Locked<[String]>([])
    var finished: [String] { ids.value }
    func record(_ id: String) { ids.withValue { $0.append(id) } }
}

/// A verified transaction. By default a new purchase (its own chain) that StoreKit reports as
/// bought rather than renewed, as iOS 17 and later do.
func fixtureTransaction(
    _ id: String,
    token: UUID?,
    finishes log: FinishLog,
    productId: String = "app.pro.monthly",
    purchaseDate: Date = Date(),
    originalId: String? = nil,
    renewal: Bool? = false
) -> StoreTransaction {
    StoreTransaction(
        id: id,
        productId: productId,
        jws: "jws-\(id)",
        appAccountToken: token,
        purchaseDate: purchaseDate,
        originalId: originalId ?? id,
        renewal: renewal,
        environment: nil,
        isServerVerifiable: true,
        finish: { log.record(id) }
    )
}

/// Where this process's cache files go: a directory named after the process. `swift test
/// --parallel` runs test cases in several processes at once, and they must not share (or clear)
/// each other's files. Directories of processes that have exited are removed on the way in.
private let testFilesDirectory: URL = {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("cashsdk-tests", isDirectory: true)
    for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        guard let pid = Int32(url.lastPathComponent), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
        try? fileManager.removeItem(at: url)
    }
    let directory = root.appendingPathComponent(String(getpid()), isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}()

func temporaryFile(_ prefix: String) -> URL {
    testFilesDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
}

func temporaryStore() -> EntitlementStore {
    EntitlementStore(fileURL: temporaryFile("entitlements"))
}

func temporaryPurchaseLog() -> PurchaseLog {
    PurchaseLog(fileURL: temporaryFile("purchases"))
}

func temporaryEventQueue() -> EventQueue {
    EventQueue(fileURL: temporaryFile("events"))
}

/// An SDK wired to `server`, with private cache files, no StoreKit listeners, a pinned
/// environment (so nothing is written to the shared UserDefaults) and no real retry sleeps.
func makeSDK(_ server: StubServer, store: EntitlementStore = temporaryStore(), purchaseLog: PurchaseLog = temporaryPurchaseLog()) -> CashSDK {
    let sdk = CashSDK(session: server.session(), automaticRecovery: false, store: store,
                      purchaseLog: purchaseLog, eventQueue: temporaryEventQueue())
    sdk.configure(with: CashSDKConfiguration(publishableKey: "csk_pk_fixture", apiBase: server.baseURL, environment: "Production"))
    sdk.retrySleep.value = { _ in }
    // Expiry tests wait for a deadline: refresh right at it.
    sdk.expiryInitialJitter.value = 0
    return sdk
}

/// Holds async work until the test opens it.
actor TestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

/// Poll until `condition` holds, or fail after `timeout`.
func eventually(timeout: TimeInterval = 5, _ message: String = "condition never held", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail(message, file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
