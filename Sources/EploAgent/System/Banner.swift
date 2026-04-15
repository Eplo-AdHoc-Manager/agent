import Foundation
import Rainbow
#if canImport(Darwin)
import Darwin
#endif

/// Renders a compact startup banner on the terminal.
enum Banner {
    /// Prints the banner to stdout. No-op when stdout is not a TTY.
    static func print() {
        #if canImport(Darwin)
        guard isatty(fileno(stdout)) != 0 else { return }
        #else
        return
        #endif

        let stripe = rainbowStripe(width: 34)
        let title = "eplo-agent".hex("E8ECEF").bold
        let subtitle = "v\(AgentVersion.current) · iOS ad-hoc distribution runner".hex("6A7280")

        let out = """

          \(stripe)
          \(title)
          \(subtitle)

        """
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// Builds the iOS rainbow stripe using 24-bit ANSI color.
    private static func rainbowStripe(width: Int) -> String {
        // iOS HIG semantic colors, in iOS-icon rainbow order.
        let colors: [String] = [
            "FF3B30", // red
            "FF9500", // orange
            "FFCC00", // yellow
            "34C759", // green
            "0A84FF", // blue
            "BF5AF2", // purple
        ]
        let segment = max(1, width / colors.count)
        let bar = String(repeating: "━", count: segment)
        return colors.map { bar.hex($0) }.joined()
    }
}
