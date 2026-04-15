import Foundation
import Logging
import Rainbow
#if canImport(Darwin)
import Darwin
#endif

/// Configures swift-log to write to both stdout (pretty) and a log file (plain).
enum AgentLogger {
    static let logDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/eplo-agent")
    }()

    static let logFile: URL = {
        logDirectory.appendingPathComponent("agent.log")
    }()

    static let maxLogFileSize: UInt64 = 10 * 1024 * 1024
    static let maxRotatedFiles: Int = 5

    static func bootstrap(label: String) -> Logger {
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        let useColor = Self.stdoutIsTTY
        Rainbow.outputTarget = useColor ? .console : .unknown
        Rainbow.enabled = useColor

        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                PrettyStreamLogHandler(label: label, colorize: useColor),
                FileLogHandler(label: label, logFile: logFile),
            ])
        }

        var logger = Logger(label: label)
        logger.logLevel = .info
        return logger
    }

    private static var stdoutIsTTY: Bool {
        #if canImport(Darwin)
        return isatty(fileno(stdout)) != 0
        #else
        return false
        #endif
    }
}

// MARK: - PrettyStreamLogHandler

/// Writes to stdout with ANSI color and a compact, glyph-led layout.
///
/// Output shape: `HH:mm:ss.SSS  ●  tag         message  key=value ...`
struct PrettyStreamLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level = .info

    private let label: String
    private let colorize: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let outputQueue = DispatchQueue(label: "eplo.agent.logging.stdout")

    init(label: String, colorize: Bool) {
        self.label = label
        self.colorize = colorize
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let timestamp = Self.timeFormatter.string(from: Date())
        let glyph = Self.glyph(for: event.level)
        let tag = Self.shortTag(for: label).paddedTo(12)
        let message = "\(event.message)"
        let metadataString = Self.formatMetadata(event.metadata ?? metadata)

        let line: String
        if colorize {
            let time = timestamp.hex("808080")
            let glyphColored = Self.colorGlyph(glyph, level: event.level)
            let tagColored = tag.hex("9BA5B4")
            let messageColored = Self.colorMessage(message, level: event.level)
            let metaColored = metadataString.hex("6A7280")
            line = "\(time)  \(glyphColored)  \(tagColored)  \(messageColored)\(metaColored)"
        } else {
            line = "\(timestamp)  \(glyph)  \(tag)  \(message)\(metadataString)"
        }

        Self.outputQueue.async {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    // MARK: - Formatting helpers

    private static func glyph(for level: Logger.Level) -> String {
        switch level {
        case .trace:    return "·"
        case .debug:    return "·"
        case .info:     return "●"
        case .notice:   return "●"
        case .warning:  return "▲"
        case .error:    return "✗"
        case .critical: return "⛔"
        }
    }

    private static func colorGlyph(_ glyph: String, level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: return glyph.hex("6A7280")
        case .info:          return glyph.hex("0A84FF")
        case .notice:        return glyph.hex("34C759")
        case .warning:       return glyph.hex("FFCC00")
        case .error:         return glyph.hex("FF3B30")
        case .critical:      return glyph.hex("BF5AF2").bold
        }
    }

    private static func colorMessage(_ message: String, level: Logger.Level) -> String {
        switch level {
        case .trace, .debug:
            return message.hex("9BA5B4")
        case .info, .notice:
            return message.hex("E8ECEF")
        case .warning:
            return message.hex("FFCC00")
        case .error:
            return message.hex("FF6E63").bold
        case .critical:
            return message.hex("FF3B30").bold
        }
    }

    private static func shortTag(for label: String) -> String {
        // "eplo.agent.run" -> "run"
        guard let last = label.split(separator: ".").last else { return label }
        return String(last)
    }

    private static func formatMetadata(_ metadata: Logger.Metadata) -> String {
        guard !metadata.isEmpty else { return "" }
        let parts = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "  " + parts.joined(separator: " ")
    }
}

private extension String {
    func paddedTo(_ width: Int) -> String {
        if count >= width { return String(prefix(width)) }
        return self + String(repeating: " ", count: width - count)
    }
}

// MARK: - FileLogHandler

/// Plain file handler. No color codes reach the file.
struct FileLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
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
        let meta = event.metadata ?? metadata
        let metaString = meta.isEmpty
            ? ""
            : "  " + meta.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "\(timestamp) [\(event.level)] [\(label)] \(event.message)\(metaString)\n"

        guard let data = line.data(using: .utf8) else { return }

        rotateIfNeeded()

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

        for i in stride(from: AgentLogger.maxRotatedFiles - 1, through: 1, by: -1) {
            let source = dir.appendingPathComponent("\(baseName).\(i).\(ext)")
            let dest = dir.appendingPathComponent("\(baseName).\(i + 1).\(ext)")
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: source, to: dest)
        }

        let rotated = dir.appendingPathComponent("\(baseName).1.\(ext)")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: logFile, to: rotated)
    }
}
