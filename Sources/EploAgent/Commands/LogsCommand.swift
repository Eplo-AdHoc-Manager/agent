import ArgumentParser
import Foundation

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show recent agent logs."
    )

    @Flag(name: .shortAndLong, help: "Follow the log output (like tail -f).")
    var follow: Bool = false

    @Option(name: .shortAndLong, help: "Number of lines to show.")
    var lines: Int = 50

    func run() async throws {
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/eplo-agent/agent.log")

        guard FileManager.default.fileExists(atPath: logFile.path) else {
            print("No log file found at \(logFile.path)")
            print("The agent has not been started yet.")
            return
        }

        if follow {
            // Use tail -f to follow the log.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            process.arguments = ["-f", "-n", "\(lines)", logFile.path]
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            // Forward SIGINT to the child process.
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                process.interrupt()
            }
            sigintSource.resume()
            signal(SIGINT, SIG_IGN) // Let DispatchSource handle it.

            try process.run()
            process.waitUntilExit()
        } else {
            // Read last N lines.
            let content = try String(contentsOf: logFile, encoding: .utf8)
            let allLines = content.components(separatedBy: .newlines)
            let lastLines = allLines.suffix(lines)
            for line in lastLines {
                print(line)
            }
        }
    }
}
