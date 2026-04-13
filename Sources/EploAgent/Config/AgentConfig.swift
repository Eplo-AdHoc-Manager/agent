import Foundation

/// Persistent configuration for the Eplo agent, stored at ~/.config/eplo-agent/config.json.
struct AgentConfig: Codable, Sendable {
    /// The control plane server URL (e.g. "wss://app.eplo.io").
    var serverURL: String

    /// Unique identifier for this runner instance.
    var runnerID: UUID

    /// The raw pairing token used for authentication.
    var token: String

    /// When this agent was first configured.
    var configuredAt: Date

    // MARK: - File Paths

    private static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/eplo-agent")
    }

    static var configFileURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    // MARK: - Load / Save

    /// Loads the agent configuration from disk.
    /// - Throws: If the file does not exist or cannot be decoded.
    static func load() throws -> AgentConfig {
        let data = try Data(contentsOf: configFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentConfig.self, from: data)
    }

    /// Saves this configuration to disk, creating the directory if needed.
    func save() throws {
        let directory = Self.configDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configFileURL, options: .atomic)

        // Restrict permissions to owner only (0600).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.configFileURL.path
        )
    }

    /// Whether a configuration file exists on disk.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: configFileURL.path)
    }
}
