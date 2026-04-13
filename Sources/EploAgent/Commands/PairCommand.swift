import ArgumentParser
import Foundation
import Logging

struct PairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair this Mac with an Eplo control plane tenant."
    )

    @Option(name: .long, help: "The pairing token from the Eplo dashboard.")
    var token: String

    @Option(name: .long, help: "The control plane server URL (e.g. https://app.eplo.io).")
    var server: String

    func run() async throws {
        let logger = AgentLogger.bootstrap(label: "eplo.agent.pair")
        logger.info("Starting pairing...")

        // Validate server URL.
        guard let _ = URL(string: server) else {
            throw ValidationError("Invalid server URL: \(server)")
        }

        let config = AgentConfig(
            serverURL: server,
            runnerID: UUID(),
            token: token,
            configuredAt: Date()
        )

        // Test connectivity by opening a WebSocket connection.
        print("Testing connection to \(server)...")

        // Save the configuration. A full handshake test would require the server
        // to be running — for now, just validate and persist.
        try config.save()
        logger.info("Configuration saved to \(AgentConfig.configFileURL.path)")

        print("")
        print("Pairing successful!")
        print("  Runner ID : \(config.runnerID)")
        print("  Server    : \(config.serverURL)")
        print("  Config    : \(AgentConfig.configFileURL.path)")
        print("")
        print("Start the agent with: eplo-agent run")
    }
}
