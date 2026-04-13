import ArgumentParser
import EploProtocol

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show version information."
    )

    func run() async throws {
        print("Eplo Agent")
        print("  Agent version   : \(AgentVersion.current)")
        print("  Protocol version: \(ProtocolVersion.current)")
        print("  Build           : \(AgentVersion.build)")
        #if arch(arm64)
        print("  Architecture    : arm64")
        #elseif arch(x86_64)
        print("  Architecture    : x86_64")
        #else
        print("  Architecture    : unknown")
        #endif
    }
}
