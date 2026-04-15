import ArgumentParser
import Foundation
import Logging
import Rainbow

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
        Banner.print()
        logger.info("Starting pairing")

        guard URL(string: server) != nil else {
            throw ValidationError("Invalid server URL: \(server)")
        }

        let config = AgentConfig(
            serverURL: server,
            runnerID: UUID(),
            token: token,
            configuredAt: Date()
        )

        try config.save()
        logger.notice("Configuration saved")

        let success = "✓ Pairing successful".hex("34C759").bold
        let label = { (s: String) in s.hex("9BA5B4") }
        let value = { (s: String) in s.hex("E8ECEF") }

        let out = """

          \(success)

            \(label("Runner ID  "))  \(value(config.runnerID.uuidString))
            \(label("Server     "))  \(value(config.serverURL))
            \(label("Config     "))  \(value(AgentConfig.configFileURL.path))

          Start the agent with: \("eplo-agent run".hex("0A84FF").bold)

        """
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}
