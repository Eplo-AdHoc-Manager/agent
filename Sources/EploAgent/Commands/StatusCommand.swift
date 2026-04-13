import ArgumentParser
import Foundation
import EploProtocol

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the agent status."
    )

    func run() async throws {
        guard AgentConfig.exists else {
            print("Agent is not configured.")
            print("Run 'eplo-agent pair' to set up this runner.")
            return
        }

        let config = try AgentConfig.load()

        print("Eplo Agent Status")
        print("=================")
        print("  Runner ID       : \(config.runnerID)")
        print("  Server URL      : \(config.serverURL)")
        print("  Configured at   : \(iso8601(config.configuredAt))")
        print("  Agent version   : \(AgentVersion.current)")
        print("  Protocol version: \(ProtocolVersion.current)")
        print("")

        let info = await SystemInfo.gather()
        print("System Information")
        print("==================")
        print("  macOS            : \(info.macOSVersion)")
        print("  Xcode            : \(info.xcodeVersion)")
        print("  Architecture     : \(info.architecture)")
        print("  Hostname         : \(info.hostname)")
        print("  Free disk space  : \(info.diskFreeGB) GB")
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
