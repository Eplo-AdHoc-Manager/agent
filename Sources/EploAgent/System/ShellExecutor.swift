import Foundation
import Logging

/// Executes shell commands using Foundation.Process, capturing stdout and stderr.
struct ShellExecutor: Sendable {

    /// Result of a shell command execution.
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
    }

    /// Executes a command and captures all output after completion.
    static func execute(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in env {
                merged[key] = value
            }
            process.environment = merged
        }

        if let workDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read output before waitUntilExit to avoid deadlock on full pipe buffer.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let stdoutStr = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Result(exitCode: process.terminationStatus, stdout: stdoutStr, stderr: stderrStr)
    }

    /// Executes a command with real-time streaming of combined output.
    ///
    /// The `onOutput` closure is called for each line of stdout. This is useful for
    /// long-running processes like `xcodebuild` where we want to report progress.
    static func executeWithStreaming(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in env {
                merged[key] = value
            }
            process.environment = merged
        }

        if let workDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate output for the final result.
        let stdoutAccumulator = OutputAccumulator()
        let stderrAccumulator = OutputAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                Task { await stdoutAccumulator.append(str) }
                // Stream each line to the callback.
                let lines = str.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    onOutput(line)
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                Task { await stderrAccumulator.append(str) }
            }
        }

        try process.run()
        process.waitUntilExit()

        // Clean up handlers.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdoutStr = await stdoutAccumulator.value
        let stderrStr = await stderrAccumulator.value

        return Result(exitCode: process.terminationStatus, stdout: stdoutStr, stderr: stderrStr)
    }
}

// MARK: - Output Accumulator

/// Thread-safe accumulator for streaming process output.
private actor OutputAccumulator {
    private var buffer = ""

    func append(_ text: String) {
        buffer += text
    }

    var value: String {
        buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
