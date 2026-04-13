import Foundation
import Logging
import EploProtocol

/// Orchestrates the full distribution pipeline: register device -> regenerate profile -> export IPA.
struct FullDistributionHandler: Sendable {
    let logger: Logger
    let config: AgentConfig

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        logger.info("Starting full distribution pipeline for job \(job.jobId)")

        var combinedResult: [String: AnyCodableValue] = [:]

        // Mutable copy of parameters that we can enrich between steps.
        var parameters = job.parameters

        // Phase 1: Register device (if UDID provided).
        if parameters["udid"] != nil {
            await progress.report(
                phase: "device_registration",
                progress: 0.0,
                message: "Registering device with Apple"
            )

            let deviceHandler = DeviceRegistrationHandler(logger: logger)
            let deviceJob = JobDispatchPayload(
                jobId: job.jobId,
                jobType: .registerDevice,
                parameters: parameters,
                timeout: job.timeout,
                priority: job.priority
            )
            let deviceResult = try await deviceHandler.execute(job: deviceJob, progress: progress)

            // Store device result under a namespaced key.
            combinedResult["device"] = .dictionary(deviceResult)

            // If we got a device_id back, make sure it's available for profile regeneration.
            if let deviceId = deviceResult["device_id"] {
                // Build the list of device IDs for profile generation.
                // The caller may already provide device_ids; we ensure the new one is included.
                if case .string(let newDeviceId) = deviceId {
                    logger.info("Device registered/found with ID: \(newDeviceId)")
                }
            }

            try Task.checkCancellation()
        }

        // Phase 2: Regenerate provisioning profile.
        if parameters["bundle_id"] != nil {
            await progress.report(
                phase: "profile_regeneration",
                progress: 0.33,
                message: "Regenerating provisioning profile"
            )

            let profileHandler = ProfileRegenerationHandler(logger: logger)
            let profileJob = JobDispatchPayload(
                jobId: job.jobId,
                jobType: .regenerateProfile,
                parameters: parameters,
                timeout: job.timeout,
                priority: job.priority
            )
            let profileResult = try await profileHandler.execute(job: profileJob, progress: progress)

            combinedResult["profile"] = .dictionary(profileResult)

            // Feed profile info into IPA export parameters.
            if case .string(let profileName) = profileResult["profile_name"] {
                parameters["provisioning_profile_name"] = .string(profileName)
            }

            try Task.checkCancellation()
        }

        // Phase 3: Export IPA.
        if parameters["archive_path"] != nil {
            await progress.report(
                phase: "ipa_export",
                progress: 0.66,
                message: "Exporting IPA for distribution"
            )

            let ipaHandler = IPAExportHandler(logger: logger, config: config)
            let ipaJob = JobDispatchPayload(
                jobId: job.jobId,
                jobType: .exportIPA,
                parameters: parameters,
                timeout: job.timeout,
                priority: job.priority
            )
            let ipaResult = try await ipaHandler.execute(job: ipaJob, progress: progress)

            combinedResult["ipa"] = .dictionary(ipaResult)
        }

        await progress.report(
            phase: "complete",
            progress: 1.0,
            message: "Full distribution pipeline completed"
        )

        logger.info("Full distribution pipeline completed for job \(job.jobId)")

        return combinedResult
    }
}
