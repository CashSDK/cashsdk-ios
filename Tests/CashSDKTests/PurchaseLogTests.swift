import CryptoKit
import Foundation
import XCTest
@testable import CashSDK

/// The per-user record of purchases started on this device: what matches, how long it lasts,
/// what reaches the disk, and what happens when the disk cannot be read.
final class PurchaseLogTests: XCTestCase {
    private let tokenA = AppAccountToken.appAccountToken(for: "A")!

    private func transaction(
        _ id: String,
        productId: String = "app.pro.monthly",
        purchaseDate: Date = Date(),
        originalId: String? = nil,
        renewal: Bool? = false
    ) -> StoreTransaction {
        fixtureTransaction(id, token: tokenA, finishes: FinishLog(), productId: productId,
                           purchaseDate: purchaseDate, originalId: originalId, renewal: renewal)
    }

    // MARK: - Matching

    func testAttemptSurvivesTheAppBeingKilled() async throws {
        let file = temporaryFile("purchases")
        let started = Date()
        await PurchaseLog(fileURL: file).recordAttempt(productId: "app.pro.monthly", userId: "A", at: started)
        // The next launch: a new log over the same file sees the purchase the killed app started.
        let relaunched = PurchaseLog(fileURL: file)
        let approved = transaction("approved", purchaseDate: started.addingTimeInterval(20))
        let claim = await relaunched.claim(for: approved, userId: "A")
        XCTAssertEqual(claim, .purchase)
        // Bound to that transaction: another purchase of the product is not the same attempt.
        let later = await relaunched.claim(for: transaction("later", purchaseDate: started.addingTimeInterval(60)), userId: "A")
        XCTAssertEqual(later, .sync)
        let again = await PurchaseLog(fileURL: file).claim(for: approved, userId: "A")
        XCTAssertEqual(again, .purchase, "the binding is persisted too")
    }

    func testRenewalsNeverMatchAnAttempt() async throws {
        let log = PurchaseLog(fileURL: temporaryFile("purchases"))
        await log.recordAttempt(productId: "app.pro.monthly", userId: "A")
        let renewal = await log.claim(for: transaction("renewal", originalId: "chain", renewal: true), userId: "A")
        XCTAssertEqual(renewal, .sync, "a renewal continues an older purchase on its own schedule")
        let resubscribe = await log.claim(for: transaction("resubscribe", originalId: "chain", renewal: false), userId: "A")
        XCTAssertEqual(resubscribe, .purchase, "a purchase on an existing chain still matches")
    }

    func testWithoutAReasonOnlyNewChainsOrPendingAttemptsMatch() async throws {
        // iOS 15 and 16 when the signed payload has no `transactionReason`.
        let log = PurchaseLog(fileURL: temporaryFile("purchases"))
        await log.recordAttempt(productId: "p.sheet", userId: "A")
        let continuing = await log.claim(for: transaction("c1", productId: "p.sheet", originalId: "chain", renewal: nil), userId: "A")
        XCTAssertEqual(continuing, .sync, "it may be a renewal")
        let newChain = await log.claim(for: transaction("n1", productId: "p.sheet", renewal: nil), userId: "A")
        XCTAssertEqual(newChain, .purchase, "a transaction that starts its own chain is a purchase")

        let pending = await log.recordAttempt(productId: "p.askToBuy", userId: "A")
        await log.markPending(pending, userId: "A")
        let approval = await log.claim(for: transaction("a1", productId: "p.askToBuy", originalId: "chain", renewal: nil), userId: "A")
        XCTAssertEqual(approval, .purchase, "an approval can resubscribe an existing chain")
    }

    func testBindingDropsTheProductsOtherAttempts() async throws {
        let log = PurchaseLog(fileURL: temporaryFile("purchases"))
        // Two taps on the same product.
        await log.recordAttempt(productId: "app.pro.monthly", userId: "A")
        await log.recordAttempt(productId: "app.pro.monthly", userId: "A")
        await log.recordAttempt(productId: "app.pro.yearly", userId: "A")
        let first = await log.claim(for: transaction("t1"), userId: "A")
        XCTAssertEqual(first, .purchase)
        let second = await log.claim(for: transaction("t2"), userId: "A")
        XCTAssertEqual(second, .sync, "the second tap's attempt went with the first")
        let otherProduct = await log.claim(for: transaction("t3", productId: "app.pro.yearly"), userId: "A")
        XCTAssertEqual(otherProduct, .purchase, "other products keep theirs")
    }

    // MARK: - Lifetimes

    func testAttemptsExpireAndAllowForClockSkew() async throws {
        let log = PurchaseLog(fileURL: temporaryFile("purchases"))
        let now = Date()
        await log.recordAttempt(productId: "p.old", userId: "A", at: now.addingTimeInterval(-8 * 86400))
        let late = await log.claim(for: transaction("late", productId: "p.old"), userId: "A")
        XCTAssertEqual(late, .sync, "an approval after seven days is no longer matched")

        await log.recordAttempt(productId: "p.skew", userId: "A", at: now)
        let early = await log.claim(for: transaction("early", productId: "p.skew", purchaseDate: now.addingTimeInterval(-600)), userId: "A")
        XCTAssertEqual(early, .sync, "dated well before the attempt")
        let skewed = await log.claim(for: transaction("skewed", productId: "p.skew", purchaseDate: now.addingTimeInterval(-120)), userId: "A")
        XCTAssertEqual(skewed, .purchase, "a device clock a couple of minutes fast still matches")
    }

    func testTransactionRecordsLastThirtyDays() async throws {
        let log = PurchaseLog(fileURL: temporaryFile("purchases"))
        let now = Date()
        let recent = await log.recordAttempt(productId: "p.recent", userId: "A")
        await log.bind(recent, to: "recent", userId: "A", at: now.addingTimeInterval(-29 * 86400))
        let old = await log.recordAttempt(productId: "p.old", userId: "A")
        await log.bind(old, to: "old", userId: "A", at: now.addingTimeInterval(-31 * 86400))
        let recentClaim = await log.claim(for: transaction("recent", productId: "p.recent"), userId: "A")
        XCTAssertEqual(recentClaim, .purchase, "29 days: still this device's purchase")
        let oldClaim = await log.claim(for: transaction("old", productId: "p.old"), userId: "A")
        XCTAssertEqual(oldClaim, .sync, "31 days: the record ran out")
    }

    func testResolvedTransactionsAreForgotten() async throws {
        let file = temporaryFile("purchases")
        let log = PurchaseLog(fileURL: file)
        let attempt = await log.recordAttempt(productId: "app.pro.monthly", userId: "A")
        await log.bind(attempt, to: "t1", userId: "A")
        await log.resolve(transactionId: "t1", userId: "A")
        let claim = await log.claim(for: transaction("t1"), userId: "A")
        XCTAssertEqual(claim, .sync)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "an empty log leaves no records file behind")
    }

    // MARK: - Storage

    func testRecordsNameNobodyAndStayOnTheDevice() async throws {
        let file = temporaryFile("purchases")
        let log = PurchaseLog(fileURL: file)
        // A numeric id: its app account token is the id in hex, 0x5451f39.
        let numericToken = try XCTUnwrap(AppAccountToken.appAccountToken(for: "88412345"))
        await log.recordAttempt(productId: "p1", userId: "88412345")
        await log.recordAttempt(productId: "p2", userId: "user-8841")
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("user-8841"), "no user id")
        XCTAssertFalse(contents.lowercased().contains("5451f39") || contents.lowercased().contains(numericToken.uuidString.lowercased()), "no app account token")
        let unsalted = SHA256.hash(data: Data("user-8841".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(contents.contains(unsalted), "no plain hash anyone can recompute from a list of ids")

        let keyFile = file.deletingPathExtension().appendingPathExtension("key")
        XCTAssertEqual(try Data(contentsOf: keyFile).count, 32, "the per-install secret sits next to the records")
        for url in [file, keyFile] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, url.lastPathComponent)
        }
        // A new secret (the key file lost) cannot match the old records.
        try FileManager.default.removeItem(at: keyFile)
        let claim = await PurchaseLog(fileURL: file).claim(for: transaction("t", productId: "p2").withToken(AppAccountToken.appAccountToken(for: "user-8841")), userId: "user-8841")
        XCTAssertEqual(claim, .sync)
    }

    func testUnreadableFileIsNotOverwritten() async throws {
        try XCTSkipIf(getuid() == 0, "root reads any file")
        let file = temporaryFile("purchases")
        await PurchaseLog(fileURL: file).recordAttempt(productId: "p.before", userId: "A")
        let original = try Data(contentsOf: file)
        // Protected and not readable yet, like a file before the device's first unlock.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let relaunched = PurchaseLog(fileURL: file)
        await relaunched.recordAttempt(productId: "p.during", userId: "A")
        let during = transaction("during", productId: "p.during")
        let duringClaim = await relaunched.claim(for: during, userId: "A")
        XCTAssertEqual(duringClaim, .purchase, "what this process started is still known")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original, "a file that could not be read is never written over")

        // Readable again: the next access reads it and merges in what was recorded meanwhile.
        let beforeClaim = await relaunched.claim(for: transaction("before", productId: "p.before"), userId: "A")
        XCTAssertEqual(beforeClaim, .purchase, "the record from before survived")
        let merged = await PurchaseLog(fileURL: file).claim(for: during, userId: "A")
        XCTAssertEqual(merged, .purchase, "and the binding made meanwhile reached the file")
    }
}

private extension StoreTransaction {
    func withToken(_ token: UUID?) -> StoreTransaction {
        StoreTransaction(id: id, productId: productId, jws: jws, appAccountToken: token, purchaseDate: purchaseDate,
                         originalId: originalId, renewal: renewal, environment: environment,
                         isServerVerifiable: isServerVerifiable, finish: finish)
    }
}
