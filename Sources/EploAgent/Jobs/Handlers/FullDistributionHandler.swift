import Foundation
import Logging
import EploProtocol

/// Orchestrates the full distribution pipeline: register device -> regenerate profile -> export IPA.
struct FullDistributionHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws {
        logger.info("Starting full distribution pipeline for job \(job.jobId)")

        // Phase 1: Register device (if UDID provided).
        if job.parameters["udid"] != nil {
            await progress.report(
                phase: "device_registration",
                progress: 0.0,
                message: "Registering device with Apple"
            )

            let deviceHandler = DeviceRegistrationHandler(logger: logger)
            try await deviceHandler.execute(job: job, progress: progress)

            try Task.checkCancellation()
        }

        // Phase 2: Regenerate provisioning profile.
        if job.parameters["profile_id"] != nil {
            await progress.report(
                phase: "profile_regeneration",
                progress: 0.33,
                message: "Regenerating provisioning profile"
            )

            let profileHandler = ProfileRegenerationHandler(logger: logger)
            try await profileHandler.execute(job: job, progress: progress)

            try Task.checkCancellation()
        }

        // Phase 3: Export IPA.
        if job.parameters["archive_path"] != nil {
            await progress.report(
                phase: "ipa_export",
                progress: 0.66,
                message: "Exporting IPA for distribution"
            )

            let ipaHandler = IPAExportHandler(logger: logger)
            try await ipaHandler.execute(job: job, progress: progress)
        }

        await progress.report(
            phase: "complete",
            progress: 1.0,
            message: "Full distribution pipeline completed"
        )

        logger.info("Full distribution pipeline completed for job \(job.jobId)")
    }
}
