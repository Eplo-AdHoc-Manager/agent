import ArgumentParser
import Foundation
import Rainbow

struct AppleKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-key",
        abstract: "Manage Apple API keys (App Store Connect).",
        subcommands: [
            AddKey.self,
            ImportKey.self,
            ListKeys.self,
            RevokeKey.self,
        ],
        defaultSubcommand: AddKey.self
    )

    // MARK: - Add (interactive, preferred)

    struct AddKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Pair an Apple account from the dashboard with a .p8 on this Mac."
        )

        func run() async throws {
            guard AgentConfig.exists else {
                let msg = "✗ Agent not configured. Run 'eplo-agent pair' first.".hex("FF3B30").bold
                FileHandle.standardError.write(Data((msg + "\n").utf8))
                throw ExitCode.failure
            }
            let config = try AgentConfig.load()

            let remote = try await AppleAccountFetcher.fetch(config: config)
            let localKeyIds = Set((try? KeychainManager().listAppleKeys())?.map(\.keyId) ?? [])
            let pending = remote.filter { !localKeyIds.contains($0.keyId) }

            guard !remote.isEmpty else {
                print("")
                print("  No Apple accounts configured for this workspace.".hex("FFCC00"))
                print("  Add one in the dashboard first:".hex("9BA5B4"))
                print("    \(config.serverURL.replacingOccurrences(of: "backend-", with: "frontend-"))/settings".hex("0A84FF"))
                print("")
                return
            }

            guard !pending.isEmpty else {
                print("")
                print("  ✓ Every Apple account already has a key on this runner.".hex("34C759").bold)
                print("  List imported keys with: ".hex("9BA5B4") + "eplo-agent apple-key list".hex("E8ECEF"))
                print("")
                return
            }

            let chosen = try Self.chooseAccount(from: pending)

            print("")
            print("  Select the .p8 file for ".hex("9BA5B4") + chosen.teamName.hex("E8ECEF").bold)
            let p8Path = try Self.openFilePicker(for: chosen.keyId)

            let keyData = try Data(contentsOf: URL(fileURLWithPath: p8Path))
            guard p8Path.hasSuffix(".p8") else {
                throw ValidationError("Expected a .p8 file, got \(p8Path)")
            }

            try KeychainManager().importP8Key(
                keyData: keyData,
                keyId: chosen.keyId,
                issuerId: chosen.issuerId,
                teamId: chosen.teamId
            )

            print("")
            print("  ✓ Imported".hex("34C759").bold + " key \(chosen.keyId.hex("E8ECEF")) for \(chosen.teamName.hex("E8ECEF"))")
            print("    The private key is stored only in your macOS Keychain.".hex("6A7280"))
            print("")
        }

        private static func chooseAccount(from accounts: [AppleAccountRemote]) throws -> AppleAccountRemote {
            if accounts.count == 1 { return accounts[0] }

            print("")
            print("  Pending Apple accounts on this runner:".hex("9BA5B4"))
            for (index, account) in accounts.enumerated() {
                let num = "[\(index + 1)]".hex("0A84FF").bold
                let name = account.teamName.hex("E8ECEF").bold
                let ids = "team \(account.teamId) · key \(account.keyId)".hex("6A7280")
                print("    \(num)  \(name)  \(ids)")
            }
            print("")

            while true {
                FileHandle.standardOutput.write(Data("  Select account [1-\(accounts.count)]: ".hex("9BA5B4").utf8))
                guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces),
                      let choice = Int(line), (1...accounts.count).contains(choice)
                else {
                    print("  Please enter a number between 1 and \(accounts.count).".hex("FFCC00"))
                    continue
                }
                return accounts[choice - 1]
            }
        }

        /// Opens the native macOS file picker via `osascript`. Returns the absolute POSIX path.
        private static func openFilePicker(for keyId: String) throws -> String {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~"
            let defaultHint = "AuthKey_\(keyId).p8"

            let script = """
            set theFile to choose file with prompt "Select \(defaultHint)" default location POSIX file "\(downloads)" of type {"com.apple.security.api-key"}
            return POSIX path of theFile
            """

            let result = try AppleScriptRunner.run(script)
            if result.exitCode != 0 {
                if result.stderr.contains("User canceled") {
                    throw ValidationError("Cancelled")
                }
                throw ValidationError("File picker failed: \(result.stderr)")
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Import

    struct ImportKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import an Apple API key (.p8) into the macOS Keychain."
        )

        @Option(name: .long, help: "Path to the .p8 key file.")
        var path: String

        @Option(name: .long, help: "The Key ID from App Store Connect.")
        var keyId: String

        @Option(name: .long, help: "The Issuer ID from App Store Connect.")
        var issuerId: String

        @Option(name: .long, help: "The Apple Developer Team ID.")
        var teamId: String

        func run() async throws {
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("Error: File not found at \(fileURL.path)")
                throw ExitCode.failure
            }

            guard fileURL.pathExtension == "p8" else {
                print("Error: Expected a .p8 file, got .\(fileURL.pathExtension)")
                throw ExitCode.failure
            }

            let keyData = try Data(contentsOf: fileURL)

            let keychainManager = KeychainManager()
            try keychainManager.importP8Key(
                keyData: keyData,
                keyId: keyId,
                issuerId: issuerId,
                teamId: teamId
            )

            print("Apple API key imported successfully!")
            print("  Key ID    : \(keyId)")
            print("  Issuer ID : \(issuerId)")
            print("  Team ID   : \(teamId)")
            print("")
            print("The private key is stored ONLY in your macOS Keychain.")
            print("It will never be transmitted to the control plane.")
        }
    }

    // MARK: - List

    struct ListKeys: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List imported Apple API keys."
        )

        func run() async throws {
            let keychainManager = KeychainManager()
            let keys = try keychainManager.listAppleKeys()

            if keys.isEmpty {
                print("No Apple API keys found.")
                print("Import one with: eplo-agent apple-key import --path <file.p8> --key-id <ID> --issuer-id <ID> --team-id <ID>")
                return
            }

            print("Apple API Keys")
            print("==============")
            for key in keys {
                print("  Key ID    : \(key.keyId)")
                print("  Team ID   : \(key.teamId)")
                print("  Imported  : \(key.importedAt)")
                print("  ---")
            }
        }
    }

    // MARK: - Revoke

    struct RevokeKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Remove an Apple API key from the Keychain."
        )

        @Option(name: .long, help: "The Key ID to revoke.")
        var keyId: String

        func run() async throws {
            let keychainManager = KeychainManager()
            try keychainManager.revokeKey(keyId: keyId)
            print("Apple API key '\(keyId)' has been removed from the Keychain.")
        }
    }
}
