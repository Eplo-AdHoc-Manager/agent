import Foundation
import Logging
import EploProtocol

/// Regenerates a provisioning profile via the App Store Connect API.
struct ProfileRegenerationHandler: Sendable {
    let logger: Logger

    /// Directory where provisioning profiles are installed on macOS.
    private static let profilesDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/MobileDevice/Provisioning Profiles"
    }()

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        await progress.report(phase: "preparing", progress: 0.0, message: "Preparing profile regeneration")

        guard case .string(let bundleIdIdentifier) = job.parameters["bundle_id"] else {
            throw JobHandlerError.missingParameter("bundle_id")
        }

        // Profile ID is optional -- if provided, we delete the existing profile first.
        let existingProfileId = job.parameters["profile_id"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        let profileName = job.parameters["profile_name"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            ?? "Eplo Ad Hoc - \(bundleIdIdentifier)"

        let profileType = job.parameters["profile_type"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            ?? "IOS_APP_ADHOC"

        logger.info("Regenerating profile for \(bundleIdIdentifier) (existing: \(existingProfileId ?? "none"))")

        await progress.report(phase: "authenticating", progress: 0.05, message: "Loading Apple API key")

        let client = try AppStoreConnectClient.fromKeychain(logger: logger)

        try Task.checkCancellation()

        // Step 1: Delete old profile if specified.
        if let profileId = existingProfileId {
            await progress.report(phase: "deleting_old", progress: 0.1, message: "Removing old profile")
            do {
                try await client.deleteProfile(id: profileId)
                logger.info("Deleted old profile: \(profileId)")
            } catch {
                logger.warning("Failed to delete old profile \(profileId): \(error). Continuing...")
            }
        }

        try Task.checkCancellation()

        // Step 2: Look up the bundle ID resource.
        await progress.report(phase: "lookup", progress: 0.2, message: "Looking up bundle ID")
        guard let bundleIdResource = try await client.getBundleId(identifier: bundleIdIdentifier) else {
            throw JobHandlerError.executionFailed(
                "Bundle ID '\(bundleIdIdentifier)' not found in App Store Connect"
            )
        }
        logger.info("Found bundle ID resource: \(bundleIdResource.id)")

        try Task.checkCancellation()

        // Step 3: Get all current certificates and devices.
        await progress.report(phase: "fetching_resources", progress: 0.3, message: "Fetching certificates and devices")

        let certificates = try await client.listCertificates()
        let devices = try await client.listDevices()

        // Filter to distribution certificates (Apple Distribution or iOS Distribution).
        let distributionCerts = certificates.filter { cert in
            let certType = cert.attributes.certificateType ?? ""
            return certType.contains("DISTRIBUTION") || certType.contains("IOS_DISTRIBUTION")
        }

        guard !distributionCerts.isEmpty else {
            throw JobHandlerError.executionFailed("No distribution certificates found in App Store Connect")
        }

        // Filter to enabled iOS devices.
        let enabledDevices = devices.filter { device in
            let status = device.attributes.status ?? ""
            let platform = device.attributes.platform ?? ""
            return status == "ENABLED" && (platform == "IOS" || platform == "UNIVERSAL")
        }

        guard !enabledDevices.isEmpty else {
            throw JobHandlerError.executionFailed("No enabled iOS devices found in App Store Connect")
        }

        logger.info("Using \(distributionCerts.count) certificate(s) and \(enabledDevices.count) device(s)")

        try Task.checkCancellation()

        // Step 4: Create the new profile.
        await progress.report(phase: "creating", progress: 0.5, message: "Creating new provisioning profile")

        let newProfile = try await client.createProfile(
            name: profileName,
            type: profileType,
            bundleIdResourceId: bundleIdResource.id,
            certificateIds: distributionCerts.map(\.id),
            deviceIds: enabledDevices.map(\.id)
        )
        logger.info("Created new profile: \(newProfile.id) (\(newProfile.attributes.name ?? "unnamed"))")

        try Task.checkCancellation()

        // Step 5: Download the profile content.
        await progress.report(phase: "downloading", progress: 0.7, message: "Downloading profile content")

        let profileData = try await client.downloadProfile(id: newProfile.id)

        // Step 6: Install the profile to ~/Library/MobileDevice/Provisioning Profiles/.
        await progress.report(phase: "installing", progress: 0.85, message: "Installing profile locally")

        let profileUUID = newProfile.attributes.uuid ?? UUID().uuidString
        let profileFilename = "\(profileUUID).mobileprovision"
        let profilePath = "\(Self.profilesDirectory)/\(profileFilename)"

        // Ensure the directory exists.
        try FileManager.default.createDirectory(
            atPath: Self.profilesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try profileData.write(to: URL(fileURLWithPath: profilePath))
        logger.info("Installed profile at: \(profilePath)")

        await progress.report(phase: "complete", progress: 1.0, message: "Profile regenerated successfully")

        return [
            "profile_id": .string(newProfile.id),
            "profile_uuid": .string(profileUUID),
            "profile_name": .string(newProfile.attributes.name ?? profileName),
            "profile_type": .string(newProfile.attributes.profileType ?? profileType),
            "profile_state": .string(newProfile.attributes.profileState ?? "ACTIVE"),
            "expiration_date": .string(newProfile.attributes.expirationDate ?? ""),
            "profile_path": .string(profilePath),
            "device_count": .int(enabledDevices.count),
            "certificate_count": .int(distributionCerts.count),
        ]
    }
}
