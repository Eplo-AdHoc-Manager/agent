import XCTest
@testable import EploAgent

final class ReconnectStrategyTests: XCTestCase {
    func testExponentialBackoff() {
        var strategy = ReconnectStrategy(baseDelay: 1.0, maxDelay: 30.0, multiplier: 2.0)

        // First delay should be baseDelay (1s).
        XCTAssertEqual(strategy.nextDelay(), 1.0, accuracy: 0.001)

        // Second delay should be 2s.
        XCTAssertEqual(strategy.nextDelay(), 2.0, accuracy: 0.001)

        // Third delay should be 4s.
        XCTAssertEqual(strategy.nextDelay(), 4.0, accuracy: 0.001)

        // Fourth delay should be 8s.
        XCTAssertEqual(strategy.nextDelay(), 8.0, accuracy: 0.001)

        // Fifth delay should be 16s.
        XCTAssertEqual(strategy.nextDelay(), 16.0, accuracy: 0.001)
    }

    func testMaxDelayCap() {
        var strategy = ReconnectStrategy(baseDelay: 1.0, maxDelay: 30.0, multiplier: 2.0)

        // Exhaust the backoff until we hit the cap.
        for _ in 0..<10 {
            _ = strategy.nextDelay()
        }

        // After many attempts, delay should be capped at maxDelay.
        let delay = strategy.nextDelay()
        XCTAssertEqual(delay, 30.0, accuracy: 0.001)
    }

    func testReset() {
        var strategy = ReconnectStrategy(baseDelay: 1.0, maxDelay: 30.0, multiplier: 2.0)

        // Advance a few attempts.
        _ = strategy.nextDelay()
        _ = strategy.nextDelay()
        _ = strategy.nextDelay()

        XCTAssertEqual(strategy.attempt, 3)

        // Reset should bring us back to attempt 0.
        strategy.reset()
        XCTAssertEqual(strategy.attempt, 0)
        XCTAssertEqual(strategy.currentDelay, 1.0, accuracy: 0.001)
    }

    func testCustomParameters() {
        var strategy = ReconnectStrategy(baseDelay: 0.5, maxDelay: 10.0, multiplier: 3.0)

        XCTAssertEqual(strategy.nextDelay(), 0.5, accuracy: 0.001) // 0.5 * 3^0
        XCTAssertEqual(strategy.nextDelay(), 1.5, accuracy: 0.001) // 0.5 * 3^1
        XCTAssertEqual(strategy.nextDelay(), 4.5, accuracy: 0.001) // 0.5 * 3^2
        XCTAssertEqual(strategy.nextDelay(), 10.0, accuracy: 0.001) // capped at 10
    }
}
