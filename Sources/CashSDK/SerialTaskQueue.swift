import Foundation

/// A strictly FIFO queue of async operations.
///
/// `Task { … }` gives NO ordering guarantee: two `Task`s created back-to-back can run in
/// either order. That is fine for fire-and-forget telemetry, but it is a correctness bug for
/// identity mutations (`logout()` then `identify("B")` must not land as `identify("B")` then
/// `logout()`, which would null the client identity while `currentUserId == "B"`) and for
/// snapshot persistence (an older write must never land after a newer one and leave a stale
/// entitlement cache on disk).
///
/// `enqueue` is synchronous and takes the lock, so the *submission* order is the caller's
/// call order; each task then awaits its predecessor, so the *execution* order matches.
final class SerialTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Append `operation` to the queue. Returns immediately; the work runs after every
    /// operation enqueued before it has finished.
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    /// Await everything currently queued. Test/teardown seam — not part of the public API.
    func drain() async {
        await currentTail()?.value
    }

    /// Snapshot the tail under the lock. Kept synchronous: `NSLock` must not be taken across
    /// an `await`.
    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}
