import Foundation
import Security

/// Information about an imported Apple API key (metadata only, never the private key).
struct AppleKeyInfo: Sendable {
    let keyId: String
    let issuerId: String
    let teamId: String
    let importedAt: String
}

/// Information about a signing identity found in the Keychain.
struct SigningIdentity: Sendable {
    let commonName: String
    let serialNumber: String
    let teamId: String?
    let expirationDate: Date?
    let hasPrivateKey: Bool
}

/// Wrapper around Security.framework for managing Apple API keys and signing certificates.
///
/// Private keys (.p8, .p12) NEVER leave this machine. Only metadata is shared with the control plane.
struct KeychainManager: Sendable {
    private static let servicePrefix = "eplo-agent"

    // MARK: - Apple API Key Management

    /// Imports a .p8 API key into the macOS Keychain.
    func importP8Key(keyData: Data, keyId: String, issuerId: String, teamId: String) throws {
        // Store the key data as a generic password in the Keychain.
        let account = "apple-api-key-\(keyId)"
        let service = "\(Self.servicePrefix).apple-keys"

        // Build metadata to store alongside the key.
        let metadata: [String: String] = [
            "key_id": keyId,
            "issuer_id": issuerId,
            "team_id": teamId,
            "imported_at": ISO8601DateFormatter().string(from: Date()),
        ]

        let metadataData = try JSONEncoder().encode(metadata)

        // Delete any existing key with the same ID.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the key to the Keychain.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrLabel as String: "Eplo Apple API Key: \(keyId)",
            kSecAttrComment as String: String(data: metadataData, encoding: .utf8) ?? "",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.importFailed(status: status)
        }
    }

    /// Lists all imported Apple API keys (metadata only).
    func listAppleKeys() throws -> [AppleKeyInfo] {
        let service = "\(Self.servicePrefix).apple-keys"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw KeychainError.queryFailed(status: status)
        }

        return items.compactMap { item -> AppleKeyInfo? in
            guard let comment = item[kSecAttrComment as String] as? String,
                  let commentData = comment.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(
                      [String: String].self,
                      from: commentData
                  ) else {
                return nil
            }

            return AppleKeyInfo(
                keyId: metadata["key_id"] ?? "unknown",
                issuerId: metadata["issuer_id"] ?? "unknown",
                teamId: metadata["team_id"] ?? "unknown",
                importedAt: metadata["imported_at"] ?? "unknown"
            )
        }
    }

    /// Removes an Apple API key from the Keychain.
    func revokeKey(keyId: String) throws {
        let service = "\(Self.servicePrefix).apple-keys"
        let account = "apple-api-key-\(keyId)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Loads the raw .p8 key data from the Keychain (for local use only, never transmitted).
    func loadP8Key(keyId: String) throws -> Data {
        let service = "\(Self.servicePrefix).apple-keys"
        let account = "apple-api-key-\(keyId)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.keyNotFound(keyId: keyId)
        }

        return data
    }

    // MARK: - Signing Identities

    /// Lists code signing identities (Apple Distribution / Development certificates) in the Keychain.
    func listSigningIdentities() throws -> [SigningIdentity] {
        // TODO: Implement full certificate enumeration using SecItemCopyMatching
        // with kSecClassIdentity to find identities that have both a certificate
        // and a private key.
        //
        // For now, use `security find-identity -v -p codesigning` as a fallback.

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Parse lines like:
        //   1) ABC123... "Apple Distribution: Team Name (TEAMID)"
        var identities: [SigningIdentity] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match lines starting with a number followed by ')'
            guard let parenIndex = trimmed.firstIndex(of: ")"),
                  trimmed[trimmed.startIndex..<parenIndex].allSatisfy({ $0.isNumber || $0 == " " }) else {
                continue
            }

            // Extract the quoted name.
            if let firstQuote = trimmed.firstIndex(of: "\""),
               let lastQuote = trimmed.lastIndex(of: "\""),
               firstQuote != lastQuote {
                let nameStart = trimmed.index(after: firstQuote)
                let name = String(trimmed[nameStart..<lastQuote])

                // Extract team ID from the name if present (in parentheses at end).
                var teamId: String? = nil
                if let openParen = name.lastIndex(of: "("),
                   let closeParen = name.lastIndex(of: ")") {
                    teamId = String(name[name.index(after: openParen)..<closeParen])
                }

                identities.append(SigningIdentity(
                    commonName: name,
                    serialNumber: "",
                    teamId: teamId,
                    expirationDate: nil,
                    hasPrivateKey: true
                ))
            }
        }

        return identities
    }
}

// MARK: - Errors

enum KeychainError: Error, CustomStringConvertible {
    case importFailed(status: OSStatus)
    case queryFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case keyNotFound(keyId: String)

    var description: String {
        switch self {
        case .importFailed(let status):
            return "Failed to import key to Keychain (status: \(status))"
        case .queryFailed(let status):
            return "Failed to query Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete key from Keychain (status: \(status))"
        case .keyNotFound(let keyId):
            return "Key '\(keyId)' not found in Keychain"
        }
    }
}
