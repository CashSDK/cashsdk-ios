import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Events

extension CashSDK {
    /// Events per `POST /v1/events` request. The server caps a batch at 500; stay well under it
    /// so one failed request can't strand a large slice of the queue.
    static let eventBatchSize = 50

    /// Flush as soon as this many events are queued, instead of waiting out the debounce.
    static let eventFlushThreshold = 20

    /// Debounce for an ordinary event — batches a burst (paywall impression + interactions)
    /// into one request.
    static let eventFlushDebounce: TimeInterval = 5

    /// Ceiling on the retry backoff. An offline device retries at most every 5 minutes; the
    /// foreground hook gets it out sooner than that whenever the user comes back.
    static let eventRetryMaxDelay: TimeInterval = 300

    /// Log a telemetry event (queued durably, batched to `POST /v1/events`).
    public func logEvent(_ name: String, props: [String: Any]? = nil) {
        recordEvent(name, props: props?.mapValues(JSONValue.init(any:)))
    }

    /// Internal typed event entry point used by the purchase / paywall lifecycle.
    ///
    /// Never blocks: the payload is built inline (so its client id and timestamp describe the
    /// moment it happened, not the moment it was written) and handed to the durable queue on a
    /// serial task queue.
    func recordEvent(
        _ name: String,
        placement: String? = nil,
        paywall: String? = nil,
        variant: String? = nil,
        product: String? = nil,
        props: [String: JSONValue]? = nil
    ) {
        let payload = EventPayload(
            // Generated HERE, once. The server dedupes on it, so a retried batch is idempotent;
            // minting a new id per send attempt would double-count every retry.
            id: UUID().uuidString,
            event: name,
            userId: currentUserId.value,
            placement: placement,
            paywall: paywall,
            variant: variant,
            product: product,
            environment: nil,
            props: props,
            ts: Date().timeIntervalSince1970 * 1000
        )
        enqueue(payload)
    }

    private func enqueue(_ payload: EventPayload) {
        // Serial, so events are persisted in the order they were recorded.
        eventWriteQueue.enqueue { [weak self] in
            guard let self else { return }
            let depth = await self.eventQueue.append(payload)
            if depth >= Self.eventFlushThreshold {
                self.flushEvents()
            } else {
                self.scheduleFlush(after: Self.eventFlushDebounce)
            }
        }
    }

    // MARK: - Flush

    /// Ask for a flush now. Returns immediately; the work runs on the flush queue, and two
    /// concurrent requests can never produce two in-flight batches of the same events.
    func flushEvents() {
        eventFlushQueue.enqueue { [weak self] in await self?.flushOnce() }
    }

    /// Schedule a single deferred flush. Coalesced — a burst of events schedules one timer, and
    /// a retry backoff already in flight is not shortened by ordinary traffic.
    func scheduleFlush(after delay: TimeInterval) {
        let alreadyScheduled = flushScheduled.withValue { scheduled -> Bool in
            if scheduled { return true }
            scheduled = true
            return false
        }
        guard !alreadyScheduled else { return }
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * Double(NSEC_PER_SEC)))
            }
            guard let self else { return }
            self.flushScheduled.value = false
            self.flushEvents()
        }
    }

    /// Send one batch.
    ///
    /// The batch is removed from the durable queue before the request and handed BACK on a
    /// retryable failure, so a dropped connection costs nothing. A permanent rejection (a `4xx`
    /// that will answer identically forever — bad publishable key, malformed body) drops the
    /// batch instead: keeping it would wedge every later event behind it for the life of the
    /// install.
    private func flushOnce() async {
        guard let api = apiClient() else { return }
        let batch = await eventQueue.take(max: Self.eventBatchSize)
        guard !batch.isEmpty else { return }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        do {
            try await api.sendEvents(EventBatch(events: batch, platform: "ios", appVersion: appVersion))
            eventFlushFailures.value = 0
            // More waiting (a long offline backlog): keep draining rather than sitting on it
            // until the next event or foreground.
            if await eventQueue.count() > 0 { flushEvents() }
        } catch {
            guard Self.isRetryable(error) else {
                await eventQueue.discard(batch)
                return
            }
            await eventQueue.restore(batch)
            scheduleRetry()
        }
    }

    /// Exponential backoff: 4s, 8s, 16s … capped at ``eventRetryMaxDelay``.
    private func scheduleRetry() {
        let attempt = eventFlushFailures.withValue { failures -> Int in
            failures = min(failures + 1, 8)
            return failures
        }
        let delay = min(pow(2.0, Double(attempt)) * 2.0, Self.eventRetryMaxDelay)
        scheduleFlush(after: delay)
    }

    // MARK: - Triggers

    /// Flush when the app returns to the foreground.
    ///
    /// This is the trigger that actually recovers an offline session: iOS suspends the process
    /// in the background, so a timer scheduled before the user left may not fire for hours —
    /// and a queue that only drains on new activity strands the last events of every session.
    func observeForegroundForEventFlush() {
        let already = foregroundObserverInstalled.withValue { installed -> Bool in
            if installed { return true }
            installed = true
            return false
        }
        guard !already else { return }
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // A fresh foreground is a fresh chance — don't make the user wait out a backoff
            // that was computed while the device had no connectivity.
            self.eventFlushFailures.value = 0
            self.flushEvents()
        }
        #endif
    }

    /// Called after any successful API round trip. Connectivity is provably back, so this is
    /// the cheapest possible signal to drain a backlog that is otherwise waiting out a backoff.
    func networkDidSucceed() {
        guard eventFlushFailures.value > 0 else { return }
        eventFlushFailures.value = 0
        flushEvents()
    }
}
