import ArgumentParser
import Foundation

struct AppleKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-key",
        abstract: "Manage Apple API keys (App Store Connect).",
        subcommands: [
            ImportKey.self,
            ListKeys.self,
            RevokeKey.self,
        ]
    )

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
