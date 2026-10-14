import Foundation

/// A non-cooperative token provider must not keep the caller suspended after timeout or sign-out.
func boundedCommerceTask<T: Sendable>(_ task: Task<T, Error>, timeout: TimeInterval) async throws -> T {
    let waiter = CommerceWaiter<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiter.install(continuation)
            let result = Task {
                do { waiter.finish(.success(try await task.value)) }
                catch { waiter.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    waiter.finish(.failure(CommerceError(code: "timeout", message: "Customer session request timed out", retryable: true)))
                } catch { }
            }
            waiter.tasks([result, timer])
        }
    } onCancel: {
        waiter.finish(.failure(CancellationError()))
    }
}

private final class CommerceWaiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var children: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func tasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if result != nil { lock.unlock(); tasks.forEach { $0.cancel() } }
        else { children = tasks; lock.unlock() }
    }
    func finish(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        let tasks = children
        children = []
        lock.unlock()
        continuation?.resume(with: value)
        tasks.forEach { $0.cancel() }
    }
}
