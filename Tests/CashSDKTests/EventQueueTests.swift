import XCTest
@testable import CashSDK

/// Telemetry used to sit in a plain in-memory array flushed on a 5s timer: everything a device
/// recorded while offline, backgrounded, or before being killed was lost, and a re-sent batch
/// double-counted server-side. These cover the three properties that fix requires — durability
/// across process death, a hard bound with observable loss, and a client id that is stable
/// across retries.
final class EventQueueTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cashsdk-events-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeQueue(capacity: Int = EventQueue.defaultCapacity) -> EventQueue {
        EventQueue(fileURL: fileURL, capacity: capacity)
    }

    private func event(_ name: String) -> EventPayload {
        EventPayload(event: name, userId: "u1", ts: 1_700_000_000_000)
    }

    // MARK: - Durability

    func testEventsSurviveProcessDeath() async {
        let queue = makeQueue()
        await queue.append(event("paywall_open"))
        await queue.append(event("purchase_start"))

        // A brand-new actor over the same file == the next launch.
        let batch = await makeQueue().take(max: 10)
        XCTAssertEqual(batch.map(\.event), ["paywall_open", "purchase_start"])
    }

    func testTakenBatchIsGoneFromDiskUntilRestored() async {
        let queue = makeQueue()
        await queue.append(event("a"))
        let batch = await queue.take(max: 10)
        XCTAssertEqual(batch.count, 1)

        let inFlight = await makeQueue().count()
        XCTAssertEqual(inFlight, 0, "an in-flight batch must not be re-sent from disk")

        await queue.restore(batch)
        let restored = await makeQueue().count()
        XCTAssertEqual(restored, 1, "a failed send must put the batch back, durably")
    }

    func testRestorePreservesSendOrderAtTheFront() async {
        let queue = makeQueue()
        await queue.append(event("first"))
        await queue.append(event("second"))
        let batch = await queue.take(max: 1)
        await queue.append(event("third"))
        await queue.restore(batch)

        let drained = await queue.take(max: 10)
        XCTAssertEqual(drained.map(\.event), ["first", "second", "third"])
    }

    // MARK: - Client event id

    func testClientIdIsStableAcrossPersistenceAndRetries() async {
        let queue = makeQueue()
        let payload = event("purchase_success")
        await queue.append(payload)

        let first = await queue.take(max: 10)
        await queue.restore(first)
        let retry = await makeQueue().take(max: 10)

        XCTAssertEqual(first.first?.id, payload.id)
        XCTAssertEqual(retry.first?.id, payload.id, "the server dedupes on this — a retry must reuse it")
    }

    func testEachEventGetsADistinctId() {
        let ids = Set((0..<50).map { _ in EventPayload(event: "e").id })
        XCTAssertEqual(ids.count, 50)
    }

    func testClientIdIsOnTheWireAsId() throws {
        let data = try JSONEncoder().encode(EventPayload(id: "evt-1", event: "paywall_open"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The server reads `id` (falling back to `clientEventId`) into Event.clientEventId.
        XCTAssertEqual(object["id"] as? String, "evt-1")
    }

    // MARK: - Bounding

    func testQueueIsBoundedAndDropsOldestFirst() async {
        let queue = makeQueue(capacity: 3)
        for i in 0..<6 { await queue.append(event("e\(i)")) }

        let remaining = await queue.count()
        let dropped = await queue.droppedCount()
        XCTAssertEqual(remaining, 3)
        XCTAssertEqual(dropped, 3)

        let batch = await queue.take(max: 10)
        // The drop marker leads, then the three NEWEST events.
        XCTAssertEqual(batch.first?.event, EventQueue.dropMarkerEvent)
        XCTAssertEqual(Array(batch.dropFirst()).map(\.event), ["e3", "e4", "e5"])
    }

    func testDropCountIsReportedOnceAndSurvivesAFailedSend() async throws {
        let queue = makeQueue(capacity: 1)
        for i in 0..<4 { await queue.append(event("e\(i)")) }

        let batch = await queue.take(max: 10)
        let marker = try XCTUnwrap(batch.first)
        XCTAssertEqual(marker.event, EventQueue.dropMarkerEvent)
        XCTAssertEqual(marker.props?["count"], .number(3))
        let afterTake = await queue.droppedCount()
        XCTAssertEqual(afterTake, 0, "the count leaves with the batch")

        // The send failed: the marker goes back as an ordinary event so the loss is still
        // reported once the device comes back, and is never counted twice.
        await queue.restore(batch)
        let retry = await queue.take(max: 10)
        XCTAssertEqual(retry.filter { $0.event == EventQueue.dropMarkerEvent }.count, 1)

        await queue.append(event("later"))
        let after = await queue.take(max: 10)
        XCTAssertTrue(after.allSatisfy { $0.event != EventQueue.dropMarkerEvent }, "reported exactly once")
    }

    func testDroppedCountSurvivesRelaunch() async {
        let queue = makeQueue(capacity: 2)
        for i in 0..<5 { await queue.append(event("e\(i)")) }
        let dropped = await makeQueue().droppedCount()
        XCTAssertEqual(dropped, 3)
    }

    // MARK: - Degenerate inputs

    func testCorruptFileIsTreatedAsEmpty() async throws {
        try Data("{ not json".utf8).write(to: fileURL)
        let queue = makeQueue()
        let empty = await queue.count()
        XCTAssertEqual(empty, 0)
        await queue.append(event("a"))
        let persisted = await makeQueue().count()
        XCTAssertEqual(persisted, 1, "a corrupt cache must not wedge the queue")
    }

    func testTakeOnEmptyQueueIsANoOp() async {
        let batch = await makeQueue().take(max: 10)
        XCTAssertTrue(batch.isEmpty)
    }

    func testClearDropsEverything() async {
        let queue = makeQueue(capacity: 1)
        for i in 0..<3 { await queue.append(event("e\(i)")) }
        await queue.clear()
        let remaining = await makeQueue().count()
        let dropped = await makeQueue().droppedCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(dropped, 0)
    }
}
