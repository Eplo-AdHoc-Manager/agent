import Foundation
import Logging
import EploProtocol

/// Scans the macOS Keychain for signing certificates and syncs metadata to the control plane.
struct CertificateSyncHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws {
        await progress.report(phase: "scanning", progress: 0.0, message: "Scanning Keychain for certificates")

        logger.info("Syncing signing certificates for job \(job.jobId)")

        // TODO: Implement certificate scanning
        // 1. Use KeychainManager to query for Apple Distribution and Development certificates
        // 2. For each certificate, extract:
        //    - Common name (e.g. "Apple Distribution: Team Name (TEAM_ID)")
        //    - Serial number
        //    - Expiration date
        //    - Team ID
        //    - Whether it has a matching private key
        // 3. Send the certificate metadata (NOT the private key) back to the control plane
        try Task.checkCancellation()

        let keychainManager = KeychainManager()
        let identities = try keychainManager.listSigningIdentities()

        await progress.report(
            phase: "reporting",
            progress: 0.8,
            message: "Found \(identities.count) signing identities"
        )

        logger.info("Found \(identities.count) signing identities")

        await progress.report(phase: "complete", progress: 1.0, message: "Certificate sync complete")
    }
}
