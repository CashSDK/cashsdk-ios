import Foundation
import os

/// Developer-facing diagnostics.
///
/// The SDK had **no logging of any kind**, and several paths correctly do nothing — a purchase
/// made in Xcode's local StoreKit environment is not sent to the server (Apple does not sign
/// it, so it cannot be verified), and a transaction that arrives before `identify()` is parked
/// rather than attributed to nobody. Both are the right behaviour and both were invisible.
///
/// That combination is what a merchant meets in their first hour. The standard way to try a new
/// IAP SDK is Xcode StoreKit Testing in the simulator — no sandbox account, no device — and
/// there `purchase()` returned `.success` while nothing reached CashSDK and the dashboard stayed
/// empty, with nothing anywhere explaining why. The integration looked broken. It wasn't.
///
/// Everything here goes through `os.Logger`, so it appears in Xcode's console and in Console.app
/// under the `com.cashsdk.sdk` subsystem, costs nothing when nobody is looking, and never writes
/// to `stdout` in a shipping app.
enum CashSDKLog {
    private static let logger = Logger(subsystem: "com.cashsdk.sdk", category: "CashSDK")

    /// Messages that must not repeat once per transaction — a loop of identical advice is noise
    /// that trains a developer to ignore the console.
    private static let saidOnce = OSAllocatedUnfairLock(initialState: Set<String>())

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    /// Log `message` the first time this `key` is seen in the process.
    static func once(_ key: String, _ message: String) {
        let isNew = saidOnce.withLock { seen -> Bool in seen.insert(key).inserted }
        guard isNew else { return }
        logger.warning("\(message, privacy: .public)")
    }
}

/// `OSAllocatedUnfairLock` is iOS 16+; this keeps the iOS 15 deployment target compiling.
/// Small enough that vendoring beats conditionalising every call site.
struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private final class Box { var value: State; init(_ v: State) { value = v } }
    private let box: Box

    init(initialState: State) { box = Box(initialState) }

    func withLock<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&box.value)
    }
}
