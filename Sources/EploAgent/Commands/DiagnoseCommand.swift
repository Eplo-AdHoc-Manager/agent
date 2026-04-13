import ArgumentParser
import Foundation

struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Run diagnostic checks on this Mac."
    )

    func run() async throws {
        print("Eplo Agent Diagnostics")
        print("======================")
        print("")

        let info = await SystemInfo.gather()

        // macOS Version
        check("macOS version", value: info.macOSVersion, pass: true)

        // Architecture
        check("Architecture", value: info.architecture, pass: true)

        // Xcode
        let xcodeInstalled = info.xcodeVersion != "Not installed"
        check("Xcode", value: info.xcodeVersion, pass: xcodeInstalled)

        // Command Line Tools
        let cliToolsInstalled = await checkCommandLineTools()
        check("CLI Tools", value: cliToolsInstalled ? "Installed" : "Not found", pass: cliToolsInstalled)

        // Disk Space (warn if < 10 GB)
        let diskOk = info.diskFreeGB >= 10
        check("Disk space", value: "\(info.diskFreeGB) GB free", pass: diskOk)

        // Agent Configuration
        let configured = AgentConfig.exists
        check("Agent config", value: configured ? "Found" : "Not configured", pass: configured)

        // Server connectivity
        if configured {
            let config = try? AgentConfig.load()
            if let config {
                let reachable = await checkServerReachability(url: config.serverURL)
                check("Server reachable", value: config.serverURL, pass: reachable)
            }
        } else {
            check("Server reachable", value: "Skipped (not configured)", pass: false)
        }

        // Keychain access
        let keychainOk = checkKeychainAccess()
        check("Keychain access", value: keychainOk ? "OK" : "Denied", pass: keychainOk)

        // Signing certificates
        let keychainManager = KeychainManager()
        let certs = (try? keychainManager.listSigningIdentities()) ?? []
        check("Signing identities", value: "\(certs.count) found", pass: !certs.isEmpty)

        print("")
    }

    // MARK: - Helpers

    private func check(_ name: String, value: String, pass: Bool) {
        let symbol = pass ? "[OK]" : "[!!]"
        let padded = name.padding(toLength: 22, withPad: " ", startingAt: 0)
        print("  \(symbol) \(padded): \(value)")
    }

    private func checkCommandLineTools() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func checkServerReachability(url: String) async -> Bool {
        let httpURL = url
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        guard let url = URL(string: httpURL) else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...499).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    private func checkKeychainAccess() -> Bool {
        // Basic check: can we query the keychain at all?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "eplo-agent-diagnostics",
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecItemNotFound (-25300) means keychain is accessible but item doesn't exist.
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
