import ArgumentParser
import EploProtocol

@main
struct EploAgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eplo-agent",
        abstract: "Eplo Agent - iOS ad-hoc distribution runner for macOS.",
        version: AgentVersion.current,
        subcommands: [
            PairCommand.self,
            RunCommand.self,
            StatusCommand.self,
            AppleKeyCommand.self,
            DiagnoseCommand.self,
            VersionCommand.self,
            LogsCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}

enum AgentVersion {
    static let major = 0
    static let minor = 1
    static let patch = 0
    static let current = "\(major).\(minor).\(patch)"
    static let build = "1"
}
