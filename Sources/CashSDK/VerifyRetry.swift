import Foundation

// MARK: - Verify retries

extension CashSDK {
    /// The longest `Retry-After` a verify waits out while its caller waits. A longer one leaves
    /// the transaction unfinished for a recovery pass scheduled after it.
    static let maxInFlightRetryAfter: TimeInterval = 30

    /// The longest pause a `Retry-After` can put on automatic reports, so one bad header cannot
    /// stop recovery for the rest of the session.
    static let maxAutomaticPause: TimeInterval = 5 * 60

    /// Retry a transient failure (offline, timeout, `408`, `429`, `5xx`), `attempts` tries in all.
    ///
    /// A throttled answer that carries `Retry-After` waits that long plus a little jitter, as
    /// long as it is at most ``maxInFlightRetryAfter``; a longer one gives up at once. Everything
    /// else backs off exponentially from 0.5s, also jittered, so devices that failed together do
    /// not retry together. Safe for `transactions:verify`, which the server dedupes by
    /// transaction id.
    static func retrying<T>(
        attempts: Int = 3,
        random: () -> Double = { Double.random(in: 0...1) },
        sleep: (TimeInterval) async throws -> Void,
        onRetryAfter: (TimeInterval) -> Void = { _ in },
        _ operation: () async throws -> T
    ) async throws -> T {
        var backoff: TimeInterval = 0.5
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let throttled as APIClient.Throttled {
                if let retryAfter = throttled.retryAfter { onRetryAfter(retryAfter) }
                guard attempt < attempts,
                      let delay = throttledDelay(retryAfter: throttled.retryAfter, backoff: backoff, random: random()) else {
                    throw throttled.error
                }
                try await sleep(delay)
                if throttled.retryAfter == nil { backoff *= 2 }
            } catch {
                guard attempt < attempts, isRetryable(error) else { throw error }
                try await sleep(backoff * (1 + 0.5 * random()))
                backoff *= 2
            }
            attempt += 1
        }
    }

    /// How long to wait before retrying a throttled verify, or nil to stop retrying in flight.
    /// `random` is in `0...1`.
    static func throttledDelay(retryAfter: TimeInterval?, backoff: TimeInterval, random: Double) -> TimeInterval? {
        guard let retryAfter else { return backoff * (1 + 0.5 * random) }
        guard retryAfter <= maxInFlightRetryAfter else { return nil }
        // Never sooner than the server asked. The jitter spreads out devices throttled together.
        return min(retryAfter + random * max(0.1, retryAfter * 0.1), maxInFlightRetryAfter)
    }
}
