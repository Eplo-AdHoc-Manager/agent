import XCTest
@testable import EploAgent

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        let original = AgentConfig(
            serverURL: "https://app.eplo.io",
            runnerID: UUID(),
            token: "test-token-abc123",
            configuredAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentConfig.self, from: data)

        XCTAssertEqual(decoded.serverURL, original.serverURL)
        XCTAssertEqual(decoded.runnerID, original.runnerID)
        XCTAssertEqual(decoded.token, original.token)

        // Dates lose sub-second precision with ISO 8601.
        XCTAssertEqual(
            decoded.configuredAt.timeIntervalSince1970,
            original.configuredAt.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testConfigJSON() throws {
        let json = """
        {
            "serverURL": "https://app.eplo.io",
            "runnerID": "550E8400-E29B-41D4-A716-446655440000",
            "token": "my-secret-token",
            "configuredAt": "2026-01-15T10:30:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(AgentConfig.self, from: json)

        XCTAssertEqual(config.serverURL, "https://app.eplo.io")
        XCTAssertEqual(config.runnerID.uuidString, "550E8400-E29B-41D4-A716-446655440000")
        XCTAssertEqual(config.token, "my-secret-token")
    }
}
