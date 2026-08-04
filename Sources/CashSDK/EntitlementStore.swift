import Foundation

/// Offline-first entitlement cache. An `actor` so the in-memory copy and the on-disk
/// file never race. The snapshot is persisted as a `Codable` JSON file in Application
/// Support, so gating survives relaunches and works before the first network response.
///
/// The persisted record is **owner-keyed**: it records the user id (and store environment)
/// the snapshot was resolved for. Without that, a shared device served user B the Pro
/// entitlements and consumable balances of user A after a relaunch — `identify()` can only
/// compare against the *in-memory* previous user, which is `nil` on a cold start — and it
/// kept serving them indefinitely if B's refresh failed (offline, or a 401 from a stale
/// token). ``load(for:environment:)`` therefore hydrates ONLY on an exact owner match and
/// treats a `nil`/mismatched owner as no cache at all.
///
/// The entitlements ETag is stored **inside the same record**, so the two can never drift:
/// an ETag that outlives its snapshot means the next read answers `304` while the cache is
/// empty, and a paying user sees no entitlements forever.
///
/// `CashSDK` keeps a separate lock-guarded mirror for *synchronous* reads
/// (`CashSDK.entitlements`); this actor is the authoritative async copy + persistence.
actor EntitlementStore {
    /// A hydrated cache entry: the snapshot plus the ETag that describes it.
    struct Cached: Sendable, Equatable {
        let entitlements: Entitlements
        let etag: String?

        static let empty = Cached(entitlements: .empty, etag: nil)
    }

    /// The on-disk shape. `ownerUserId` and `environment` are what make the cache safe to
    /// hydrate; `etag` rides along so it is written (and dropped) atomically with the body.
    private struct Record: Codable {
        let ownerUserId: String?
        let environment: String?
        let entitlements: Entitlements
        let etag: String?
    }

    private var current: Entitlements = .empty
    private let fileURL: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.makeFileURL(fileManager)
    }

    /// The last known snapshot (may be `.empty` before ``load(for:environment:)``).
    var snapshot: Entitlements { current }

    /// Read the persisted snapshot for `userId` into memory.
    ///
    /// Returns ``Cached/empty`` — and deletes the file — when the record belongs to someone
    /// else, to no one, or to a different store environment. Never throws: a missing or
    /// corrupt cache is simply "no data yet".
    func load(for userId: String?, environment: String?) -> Cached {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(Record.self, from: data) else {
            current = .empty
            return .empty
        }
        // A snapshot with no recorded owner predates owner-keying (or was written by a
        // logged-out session) — it cannot be proven to belong to this user, so discard it.
        guard let owner = decoded.ownerUserId, owner == userId, decoded.environment == environment else {
            current = .empty
            try? fileManager.removeItem(at: fileURL)
            return .empty
        }
        current = decoded.entitlements
        return Cached(entitlements: decoded.entitlements, etag: decoded.etag)
    }

    /// Replace the snapshot in memory and persist it atomically for `owner`.
    ///
    /// Returns `false` when the write did not land. The caller MUST then drop the in-flight
    /// ETag: keeping an ETag whose snapshot never persisted produces a permanent
    /// "hydrate empty, then 304" lockout.
    @discardableResult
    func update(_ entitlements: Entitlements, owner: String?, environment: String?, etag: String?) -> Bool {
        // Strip the transaction-scoped fields before they reach disk (see
        // `Entitlements.gatingSnapshot()`): a cached `belongsToAnotherAccount = true` would be
        // rehydrated on every later launch and keep asserting a conflict that is long over.
        let gating = entitlements.gatingSnapshot()
        current = gating
        guard let fileURL,
              let data = try? encoder.encode(
                  Record(ownerUserId: owner, environment: environment, entitlements: gating, etag: etag)
              ) else {
            return false
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Clear the cache (e.g. on `logout()`).
    func clear() {
        current = .empty
        guard let fileURL else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    // MARK: - Location

    private static func makeFileURL(_ fileManager: FileManager) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = base.appendingPathComponent("CashSDK", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("entitlements.json")
    }
}
