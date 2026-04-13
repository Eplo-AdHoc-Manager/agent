import Foundation

/// Exponential backoff strategy for WebSocket reconnection.
struct ReconnectStrategy: Sendable {
    /// Base delay in seconds.
    let baseDelay: TimeInterval

    /// Maximum delay in seconds.
    let maxDelay: TimeInterval

    /// Multiplier applied on each consecutive failure.
    let multiplier: Double

    /// Current consecutive failure count.
    private(set) var attempt: Int

    init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        multiplier: Double = 2.0
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.attempt = 0
    }

    /// The delay for the current attempt, capped at `maxDelay`.
    var currentDelay: TimeInterval {
        let delay = baseDelay * pow(multiplier, Double(attempt))
        return min(delay, maxDelay)
    }

    /// Records a failed attempt and returns the delay before the next retry.
    mutating func nextDelay() -> TimeInterval {
        let delay = currentDelay
        attempt += 1
        return delay
    }

    /// Resets the backoff counter after a successful connection.
    mutating func reset() {
        attempt = 0
    }
}
