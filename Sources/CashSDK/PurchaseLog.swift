import CryptoKit
import Foundation

/// Purchases this device started, per user, so recovery reports them as purchases.
///
/// Automatic reports go out with claim `sync`, which never moves a purchase between app
/// accounts. That is right for renewals and for purchases made elsewhere, and wrong for the
/// buyer's own purchase: under the `transfer` restore policy a returning customer's resubscribe,
/// on a chain an old account still owns, is only credited on a `purchase` claim. A purchase whose
/// first verify did not land (offline, a server error, the app killed, a long `Retry-After`) and
/// every Ask-to-Buy or SCA purchase come back through recovery, so recovery has to know which
/// transactions were bought here.
///
/// Two kinds of record, kept per user:
///  - an attempt, written before the payment sheet opens: the product and the start time. The
///    first transaction for that product that carries the user's own app account token, is
///    dated after the start and is not a renewal is the attempt's result (an approved Ask to
///    Buy, or a purchase whose app was killed with the sheet open). It then becomes a
///    transaction record, and the product's other attempts (a second tap) are dropped. Kept
///    ``attemptLifetime``. StoreKit does not report a declined Ask to Buy, so a declined
///    request's attempt simply runs out.
///  - a transaction id, once StoreKit hands the transaction over. Kept until the server credits
///    it or the transaction is finished, and at most ``transactionLifetime``.
///
/// Records are keyed by an HMAC of the user id under a random per-install secret kept in a
/// file next to them, so the records alone do not name anyone, and neither file is backed up.
/// They are kept across logout on purpose: an Ask to Buy approved while the buyer is signed out
/// arrives after they sign back in, and only this record gets it reported as their purchase.
///
/// Stored in Application Support, readable once the device has been unlocked after starting (an
/// approval can arrive in the background while it is locked). A file that exists but cannot be
/// read is never written over: changes stay in memory and are merged in once a read succeeds.
actor PurchaseLog {
    struct Attempt: Codable, Equatable, Sendable {
        let id: UUID
        let productId: String
        let startedAt: Date
        /// StoreKit left the purchase pending (Ask to Buy, SCA). Its approval can land on an
        /// existing chain.
        var pending = false
    }

    struct UserLog: Codable, Equatable {
        var attempts: [Attempt] = []
        /// Transaction id, and when it was recorded.
        var transactions: [String: Date] = [:]
        var isEmpty: Bool { attempts.isEmpty && transactions.isEmpty }
    }

    /// What this process removed while the file could not be read, applied over its contents
    /// once it can be.
    private struct Removals {
        var attempts: Set<UUID> = []
        var transactions: Set<String> = []
        /// Products bound to a transaction, and when: older attempts for them are leftovers.
        var boundProducts: [String: Date] = [:]
    }

    private struct Stored: Codable {
        var users: [String: UserLog]
    }

    /// How long an Ask-to-Buy or SCA approval, or a purchase interrupted mid-sheet, is still
    /// recognized as the purchase started here.
    static let attemptLifetime: TimeInterval = 7 * 24 * 3600
    /// How long a transaction that never got credited keeps its `purchase` claim.
    static let transactionLifetime: TimeInterval = 30 * 24 * 3600
    /// StoreKit dates a transaction by Apple's clock; the attempt start is the device's. Allow
    /// for a device clock that runs a few minutes fast.
    static let clockSkewAllowance: TimeInterval = 5 * 60

    private let fileURL: URL?
    private let keyURL: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Set once both files have been read, or found missing. Until then nothing is written.
    private var loaded = false
    private var secret: SymmetricKey?
    /// Whether ``secret`` is on disk. Records are not written under a secret that is not.
    private var secretSaved = false
    /// Records by key, once loaded.
    private var users: [String: UserLog] = [:]
    /// What this process recorded while the file could not be read, by user id.
    private var unsaved: [String: UserLog] = [:]
    private var removals: [String: Removals] = [:]

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        let url = fileURL ?? Self.makeFileURL(fileManager)
        self.fileURL = url
        self.keyURL = url?.deletingPathExtension().appendingPathExtension("key")
    }

    // MARK: - Recording

    /// Remember a purchase about to open the payment sheet.
    @discardableResult
    func recordAttempt(productId: String, userId: String, at date: Date = Date()) -> Attempt {
        let attempt = Attempt(id: UUID(), productId: productId, startedAt: date)
        change(userId) { log, _ in log.attempts.append(attempt) }
        return attempt
    }

    /// StoreKit left the attempt pending (Ask to Buy, SCA).
    func markPending(_ attempt: Attempt, userId: String) {
        change(userId) { log, _ in
            if let index = log.attempts.firstIndex(where: { $0.id == attempt.id }) { log.attempts[index].pending = true }
        }
    }

    /// The attempt ended before any charge: cancelled, or refused by the App Store.
    func forget(_ attempt: Attempt, userId: String) {
        change(userId) { log, removed in
            log.attempts.removeAll { $0.id == attempt.id }
            removed.attempts.insert(attempt.id)
        }
    }

    /// StoreKit returned the attempt's transaction. From now on that exact transaction is the
    /// purchase, and no attempt for the product is matched against anything else.
    func bind(_ attempt: Attempt, to transactionId: String, userId: String, at date: Date = Date()) {
        change(userId) { log, removed in
            Self.bind(productId: attempt.productId, to: transactionId, at: date, log: &log, removed: &removed)
        }
    }

    /// The server credited the transaction, or it was finished: nothing is left to claim.
    func resolve(transactionId: String, userId: String) {
        load()
        if loaded, record(for: userId)?.transactions[transactionId] == nil { return }
        change(userId) { log, removed in
            log.transactions[transactionId] = nil
            removed.transactions.insert(transactionId)
        }
    }

    // MARK: - Claims

    /// The claim for reporting `transaction` as `userId`: `purchase` when this device started it
    /// for this user, `sync` for anything else (a renewal, a purchase made elsewhere, another
    /// user's). A transaction that is an attempt's result is bound to it here.
    func claim(for transaction: StoreTransaction, userId: String, now: Date = Date()) -> VerifyClaim {
        load()
        guard let log = record(for: userId) else { return .sync }
        if let recorded = log.transactions[transaction.id],
           now.timeIntervalSince(recorded) <= Self.transactionLifetime {
            return .purchase
        }
        guard let ownToken = AppAccountToken.appAccountToken(for: userId),
              transaction.appAccountToken == ownToken,
              log.attempts.contains(where: { Self.isResult(transaction, of: $0, now: now) }) else { return .sync }
        change(userId) { log, removed in
            Self.bind(productId: transaction.productId, to: transaction.id, at: now, log: &log, removed: &removed)
        }
        return .purchase
    }

    /// Whether `transaction` is what `attempt` bought.
    ///
    /// A renewal never is: it continues an earlier purchase on its own schedule, and a `purchase`
    /// claim on it could take the purchase back from an account a `transfer` restore moved it to.
    static func isResult(_ transaction: StoreTransaction, of attempt: Attempt, now: Date) -> Bool {
        guard attempt.productId == transaction.productId,
              now.timeIntervalSince(attempt.startedAt) <= attemptLifetime,
              transaction.purchaseDate >= attempt.startedAt.addingTimeInterval(-clockSkewAllowance) else { return false }
        switch transaction.renewal {
        case true?:
            return false
        case false?:
            return true
        case nil:
            // iOS 15 and 16, when the signed payload has no `transactionReason`. A transaction
            // that starts its own chain is a purchase. One that continues a chain may be a
            // renewal, so it only counts for an attempt StoreKit left pending, whose approval can
            // resubscribe an existing chain. The limit: on those versions a resubscribe that
            // completes after an app kill or a failed sheet goes out as `sync`.
            return transaction.id == transaction.originalId || attempt.pending
        }
    }

    // MARK: - Storage

    private static func bind(productId: String, to transactionId: String, at date: Date, log: inout UserLog, removed: inout Removals) {
        let leftovers = log.attempts.filter { $0.productId == productId }.map(\.id)
        log.attempts.removeAll { $0.productId == productId }
        removed.attempts.formUnion(leftovers)
        removed.boundProducts[productId] = date
        log.transactions[transactionId] = date
        removed.transactions.remove(transactionId)
    }

    private func record(for userId: String) -> UserLog? {
        guard loaded else { return unsaved[userId] }
        return recordKey(userId).flatMap { users[$0] }
    }

    private func change(_ userId: String, _ body: (inout UserLog, inout Removals) -> Void) {
        load()
        if loaded, let key = recordKey(userId) {
            var log = users[key] ?? UserLog()
            var ignored = Removals()
            body(&log, &ignored)
            users[key] = log
            prune(now: Date())
            save()
        } else {
            var log = unsaved[userId] ?? UserLog()
            var removed = removals[userId] ?? Removals()
            body(&log, &removed)
            unsaved[userId] = log
            removals[userId] = removed
        }
    }

    private func load() {
        guard !loaded else { return }
        guard let fileURL, let keyURL else {
            secret = SymmetricKey(size: .bits256)
            finishLoading(users: [:])
            return
        }
        let keyData: Data?
        let recordsData: Data?
        do {
            keyData = try readIfPresent(keyURL)
            recordsData = try readIfPresent(fileURL)
        } catch {
            // A file is there but cannot be read now, like a protected one before the device's
            // first unlock. Keep this process's changes in memory, never write over the file,
            // and read again on the next access.
            return
        }
        if let keyData, keyData.count == 32 {
            secret = SymmetricKey(data: keyData)
            secretSaved = true
            let stored = recordsData.flatMap { try? decoder.decode(Stored.self, from: $0) }
            // Contents from an older build, or damaged, cannot be matched: start over.
            finishLoading(users: stored?.users ?? [:])
        } else {
            // No usable secret: whatever records exist were keyed under a lost one.
            secret = SymmetricKey(size: .bits256)
            finishLoading(users: [:])
        }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch where Self.isMissing(error) {
            return nil
        }
    }

    private func finishLoading(users stored: [String: UserLog]) {
        users = stored
        loaded = true
        let pending = Set(unsaved.keys).union(removals.keys)
        for userId in pending {
            guard let key = recordKey(userId) else { continue }
            var merged = users[key] ?? UserLog()
            let removed = removals[userId] ?? Removals()
            merged.attempts.removeAll { attempt in
                removed.attempts.contains(attempt.id)
                    || removed.boundProducts[attempt.productId].map { attempt.startedAt <= $0 } == true
            }
            merged.transactions = merged.transactions.filter { !removed.transactions.contains($0.key) }
            let recorded = unsaved[userId] ?? UserLog()
            merged.attempts += recorded.attempts.filter { attempt in !merged.attempts.contains { $0.id == attempt.id } }
            merged.transactions.merge(recorded.transactions) { max($0, $1) }
            users[key] = merged
        }
        unsaved = [:]
        removals = [:]
        prune(now: Date())
        if !pending.isEmpty { save() }
    }

    private func prune(now: Date) {
        for key in Array(users.keys) {
            guard var log = users[key] else { continue }
            log.attempts.removeAll { now.timeIntervalSince($0.startedAt) > Self.attemptLifetime }
            log.transactions = log.transactions.filter { now.timeIntervalSince($0.value) <= Self.transactionLifetime }
            users[key] = log.isEmpty ? nil : log
        }
    }

    /// Best effort, like the other caches: a failed write costs a `sync` claim, never access.
    private func save() {
        guard loaded, let fileURL, let keyURL, let secret else { return }
        if users.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        if !secretSaved {
            secretSaved = write(secret.withUnsafeBytes { Data($0) }, to: keyURL)
            guard secretSaved else { return }
        }
        guard let data = try? encoder.encode(Stored(users: users)) else { return }
        _ = write(data, to: fileURL)
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            // Readable in the background once the device has been unlocked after starting.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        // Only the install that wrote it can use it, so a backup gains nothing from it.
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return true
    }

    private func recordKey(_ userId: String) -> String? {
        guard let secret else { return nil }
        return HMAC<SHA256>.authenticationCode(for: Data(userId.utf8), using: secret)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isMissing(underlying) }
        return false
    }

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
        return directory.appendingPathComponent("purchases.json")
    }
}
