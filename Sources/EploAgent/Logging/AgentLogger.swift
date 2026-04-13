import Foundation
import Logging

/// Configures swift-log to write to both stdout and a log file.
enum AgentLogger {
    /// The log directory path.
    static let logDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/eplo-agent")
    }()

    /// The main log file path.
    static let logFile: URL = {
        logDirectory.appendingPathComponent("agent.log")
    }()

    /// Maximum log file size in bytes before rotation (10 MB).
    static let maxLogFileSize: UInt64 = 10 * 1024 * 1024

    /// Number of rotated log files to keep.
    static let maxRotatedFiles: Int = 5

    /// Creates and configures a Logger that writes to both stdout and a file.
    static func bootstrap(label: String) -> Logger {
        // Ensure log directory exists.
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                StreamLogHandler.standardOutput(label: label),
                FileLogHandler(label: label, logFile: logFile),
            ])
        }

        var logger = Logger(label: label)
        logger.logLevel = .info
        return logger
    }
}

// MARK: - FileLogHandler

/// A swift-log handler that writes to a file with basic rotation.
struct FileLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    private let label: String
    private let logFile: URL

    init(label: String, logFile: URL) {
        self.label = label
        self.logFile = logFile
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formattedMessage = "\(timestamp) [\(event.level)] [\(label)] \(event.message)\n"

        guard let data = formattedMessage.data(using: .utf8) else { return }

        // Rotate if needed.
        rotateIfNeeded()

        // Append to file.
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > AgentLogger.maxLogFileSize else {
            return
        }

        let fm = FileManager.default
        let dir = logFile.deletingLastPathComponent()
        let baseName = logFile.deletingPathExtension().lastPathComponent
        let ext = logFile.pathExtension

        // Shift rotated files: agent.4.log -> agent.5.log, etc.
        for i in stride(from: AgentLogger.maxRotatedFiles - 1, through: 1, by: -1) {
            let source = dir.appendingPathComponent("\(baseName).\(i).\(ext)")
            let dest = dir.appendingPathComponent("\(baseName).\(i + 1).\(ext)")
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: source, to: dest)
        }

        // Rotate current file to .1.
        let rotated = dir.appendingPathComponent("\(baseName).1.\(ext)")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: logFile, to: rotated)
    }
}
