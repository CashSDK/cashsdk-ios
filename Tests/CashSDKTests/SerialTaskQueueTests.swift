import XCTest
@testable import CashSDK

/// `logout()` followed by `identify("B")` pushed two bare `Task`s, which carry no ordering
/// guarantee. When the identify landed first, the logout then nulled the API client's identity
/// while `currentUserId == "B"` — every later verify went out unattributed and every entitlements
/// read 401'd, until something else called `identify` again.
final class SerialTaskQueueTests: XCTestCase {

    /// A tiny lock-guarded recorder (the queue runs its work on arbitrary executors).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testOperationsRunInSubmissionOrder() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()

        // Descending sleeps: with unordered `Task`s the recorded order would invert.
        for index in 0..<8 {
            queue.enqueue {
                try? await Task.sleep(nanoseconds: UInt64(8 - index) * 2_000_000)
                recorder.append(index)
            }
        }
        await queue.drain()

        XCTAssertEqual(recorder.snapshot, Array(0..<8))
    }

    func testLaterOperationNeverOverlapsAnEarlierOne() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()

        queue.enqueue {
            recorder.append(1)          // "logout begins"
            try? await Task.sleep(nanoseconds: 20_000_000)
            recorder.append(2)          // "logout ends"
        }
        queue.enqueue {
            recorder.append(3)          // "identify" must not interleave
        }
        await queue.drain()

        XCTAssertEqual(recorder.snapshot, [1, 2, 3])
    }

    func testDrainOnAnEmptyQueueReturns() async {
        await SerialTaskQueue().drain()
    }
}
