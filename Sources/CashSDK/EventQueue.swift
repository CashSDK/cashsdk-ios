import Foundation

/// Durable, bounded, FIFO buffer for analytics events.
///
/// Telemetry used to live in a plain in-memory array flushed on a 5-second timer. Anything a
/// device recorded while offline, backgrounded, or before being killed was lost outright, and
/// a re-sent batch double-counted server-side because nothing identified an individual event.
///
/// This is an `actor` for the same reason ``EntitlementStore`` is: the in-memory copy and the
/// on-disk file must never race. Every mutation is persisted immediately (a small atomic JSON
/// write in Application Support), so an event is durable from the instant it is recorded — the
/// process can die on the very next line and nothing is lost.
///
/// It is **bounded**. A device offline for a week must not grow an unbounded file, so the
/// queue holds at most ``capacity`` events and evicts the OLDEST first — newer events are the
/// ones a session is about to be judged on. Evictions are COUNTED, not silent: the count rides
/// out with the next batch as an `events_dropped` event, so loss is visible in the same
/// analytics the events feed.
actor EventQueue {
    /// The default cap. ~500 events × a few hundred bytes ≈ 100 KB worst case.
    static let defaultCapacity = 500

    /// Telemetry name for the drop marker. Deliberately mirrors the SDK's other snake_case
    /// lifecycle events so it lands in the same event stream.
    static let dropMarkerEvent = "events_dropped"

    /// The on-disk shape. `dropped` is persisted alongside the events: a drop that happened
    /// while offline must still be reportable after a relaunch.
    private struct Record: Codable {
        var events: [EventPayload]
        var dropped: Int
    }

    private let fileURL: URL?
    private let fileManager: FileManager
    private let capacity: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var events: [EventPayload] = []
    private var dropped = 0
    private var hydrated = false

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        capacity: Int = EventQueue.defaultCapacity
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.makeFileURL(fileManager)
        self.capacity = max(1, capacity)
    }

    // MARK: - Queue operations

    /// Append an event and return the resulting queue depth (so the caller can decide whether
    /// to flush now or debounce). Persists before returning.
    @discardableResult
    func append(_ event: EventPayload) -> Int {
        hydrate()
        events.append(event)
        trim()
        persist()
        return events.count
    }

    /// Remove and return up to `max` of the OLDEST events, plus a drop marker if events were
    /// evicted since the last take.
    ///
    /// The batch is removed from disk here, so a caller whose send fails **must** hand it back
    /// to ``restore(_:)`` — that is the only thing standing between a failed request and lost
    /// telemetry.
    func take(max: Int) -> [EventPayload] {
        hydrate()
        guard max > 0 else { return [] }
        var batch: [EventPayload] = []
        // The marker goes out with the batch (and comes back with it on failure), so the count
        // can't be lost by zeroing it optimistically before a send that never lands.
        if dropped > 0 {
            batch.append(
                EventPayload(
                    event: Self.dropMarkerEvent,
                    props: ["count": .number(Double(dropped)), "reason": .string("queue_full")],
                    ts: Date().timeIntervalSince1970 * 1000
                )
            )
            dropped = 0
        }
        let take = Swift.min(max - batch.count, events.count)
        if take > 0 {
            batch.append(contentsOf: events.prefix(take))
            events.removeFirst(take)
        }
        if !batch.isEmpty { persist() }
        return batch
    }

    /// Put a failed batch back at the FRONT, preserving send order.
    ///
    /// A drop marker in the batch goes back to being an ordinary queued event, so the eviction
    /// count is still reported once the device comes back — it is never silently swallowed by
    /// the failure that prevented its first delivery.
    func restore(_ batch: [EventPayload]) {
        guard !batch.isEmpty else { return }
        hydrate()
        events.insert(contentsOf: batch, at: 0)
        trim()
        persist()
    }

    /// Drop a batch that can never succeed (a `4xx` the server will reject identically forever).
    /// Keeping it would block every later event behind it for the life of the install.
    func discard(_ batch: [EventPayload]) {
        // Nothing to do — `take` already removed it. Exists so the call site reads as a
        // deliberate decision rather than a forgotten `restore`.
        _ = batch
    }

    /// How many events are waiting.
    func count() -> Int {
        hydrate()
        return events.count
    }

    /// How many events have been evicted and not yet reported.
    func droppedCount() -> Int {
        hydrate()
        return dropped
    }

    /// Drop everything (test/teardown seam; also correct on an app-data reset).
    func clear() {
        hydrate()
        events.removeAll()
        dropped = 0
        persist()
    }

    // MARK: - Persistence

    /// Read the queue off disk exactly once per actor instance. A missing or corrupt file is
    /// simply "no events yet" — telemetry must never throw into the host.
    private func hydrate() {
        guard !hydrated else { return }
        hydrated = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(Record.self, from: data) else { return }
        events = record.events
        dropped = record.dropped
        trim()
    }

    /// Enforce the cap by evicting the oldest, counting what was evicted.
    private func trim() {
        guard events.count > capacity else { return }
        let overflow = events.count - capacity
        events.removeFirst(overflow)
        dropped += overflow
    }

    private func persist() {
        guard let fileURL else { return }
        guard let data = try? encoder.encode(Record(events: events, dropped: dropped)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
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
        return directory.appendingPathComponent("events.json")
    }
}
