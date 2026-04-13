import Foundation
import Logging
import EploProtocol

/// Scans the macOS Keychain for signing certificates and cross-references with App Store Connect.
struct CertificateSyncHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        await progress.report(phase: "scanning", progress: 0.0, message: "Scanning Keychain for certificates")

        logger.info("Syncing signing certificates for job \(job.jobId)")

        // Step 1: List local signing identities from the Keychain.
        let keychainManager = KeychainManager()
        let identities = try keychainManager.listSigningIdentities()

        logger.info("Found \(identities.count) local signing identities")

        try Task.checkCancellation()

        // Step 2: List certificates from App Store Connect API.
        await progress.report(phase: "fetching_remote", progress: 0.3, message: "Fetching certificates from Apple")

        var remoteCertificates: [ASCCertificate] = []
        do {
            let client = try AppStoreConnectClient.fromKeychain(logger: logger)
            remoteCertificates = try await client.listCertificates()
            logger.info("Found \(remoteCertificates.count) certificates in App Store Connect")
        } catch ASCClientError.noKeyAvailable {
            logger.warning("No .p8 key available -- skipping App Store Connect certificate fetch")
        }

        try Task.checkCancellation()

        // Step 3: Cross-reference local and remote certificates.
        await progress.report(phase: "comparing", progress: 0.6, message: "Cross-referencing certificates")

        var certificateEntries: [AnyCodableValue] = []

        for identity in identities {
            // Try to find a matching remote certificate by common name.
            let matchingRemote = remoteCertificates.first { cert in
                guard let remoteName = cert.attributes.name else { return false }
                return identity.commonName.contains(remoteName) || remoteName.contains(identity.commonName)
            }

            var entry: [String: AnyCodableValue] = [
                "common_name": .string(identity.commonName),
                "has_private_key": .bool(identity.hasPrivateKey),
            ]

            if let teamId = identity.teamId {
                entry["team_id"] = .string(teamId)
            }

            if let serial = identity.serialNumber.isEmpty ? nil : identity.serialNumber {
                entry["serial_number"] = .string(serial)
            }

            if let expiry = identity.expirationDate {
                entry["expiration_date"] = .string(ISO8601DateFormatter().string(from: expiry))
            }

            if let remote = matchingRemote {
                entry["asc_id"] = .string(remote.id)
                entry["asc_certificate_type"] = .string(remote.attributes.certificateType ?? "")
                if let remoteExpiry = remote.attributes.expirationDate {
                    entry["asc_expiration_date"] = .string(remoteExpiry)
                }
                entry["synced"] = .bool(true)
            } else {
                entry["synced"] = .bool(false)
            }

            certificateEntries.append(.dictionary(entry))
        }

        // Include remote-only certificates (present in ASC but not in local keychain).
        for cert in remoteCertificates {
            let hasLocal = identities.contains { identity in
                guard let remoteName = cert.attributes.name else { return false }
                return identity.commonName.contains(remoteName) || remoteName.contains(identity.commonName)
            }

            if !hasLocal {
                var entry: [String: AnyCodableValue] = [
                    "common_name": .string(cert.attributes.name ?? "Unknown"),
                    "has_private_key": .bool(false),
                    "asc_id": .string(cert.id),
                    "asc_certificate_type": .string(cert.attributes.certificateType ?? ""),
                    "synced": .bool(false),
                    "remote_only": .bool(true),
                ]

                if let serial = cert.attributes.serialNumber {
                    entry["serial_number"] = .string(serial)
                }
                if let expiry = cert.attributes.expirationDate {
                    entry["asc_expiration_date"] = .string(expiry)
                }

                certificateEntries.append(.dictionary(entry))
            }
        }

        await progress.report(
            phase: "reporting",
            progress: 0.9,
            message: "Found \(identities.count) local, \(remoteCertificates.count) remote certificates"
        )

        await progress.report(phase: "complete", progress: 1.0, message: "Certificate sync complete")

        return [
            "local_count": .int(identities.count),
            "remote_count": .int(remoteCertificates.count),
            "certificates": .array(certificateEntries),
        ]
    }
}
