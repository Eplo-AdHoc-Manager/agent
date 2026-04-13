import Foundation
import Logging
import EploProtocol

/// Registers a device UDID with Apple via the App Store Connect API.
struct DeviceRegistrationHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        await progress.report(phase: "preparing", progress: 0.0, message: "Preparing device registration")

        // Extract parameters from the job payload.
        guard case .string(let udid) = job.parameters["udid"] else {
            throw JobHandlerError.missingParameter("udid")
        }

        guard case .string(let deviceName) = job.parameters["device_name"] else {
            throw JobHandlerError.missingParameter("device_name")
        }

        let platform = job.parameters["platform"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            ?? "IOS"

        // Allow specifying a specific key ID, or use the first available.
        let keyId = job.parameters["key_id"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        logger.info("Registering device: \(deviceName) (\(udid)) platform=\(platform)")

        await progress.report(phase: "authenticating", progress: 0.1, message: "Loading Apple API key")

        let client: AppStoreConnectClient
        if let keyId = keyId {
            client = try AppStoreConnectClient.fromKeychain(keyId: keyId, logger: logger)
        } else {
            client = try AppStoreConnectClient.fromKeychain(logger: logger)
        }

        try Task.checkCancellation()

        await progress.report(phase: "registering", progress: 0.3, message: "Calling App Store Connect API")

        let device: ASCDevice
        do {
            device = try await client.registerDevice(name: deviceName, udid: udid, platform: platform)
            logger.info("Device registered: \(device.id)")
        } catch ASCClientError.deviceAlreadyRegistered(let existingDevice) {
            // Device already exists -- treat as success.
            logger.info("Device already registered: \(existingDevice.id)")
            await progress.report(phase: "complete", progress: 1.0, message: "Device already registered")
            return [
                "device_id": .string(existingDevice.id),
                "udid": .string(udid),
                "name": .string(existingDevice.attributes.name ?? deviceName),
                "platform": .string(existingDevice.attributes.platform ?? platform),
                "status": .string(existingDevice.attributes.status ?? "ENABLED"),
                "already_registered": .bool(true),
            ]
        }

        try Task.checkCancellation()

        await progress.report(phase: "verifying", progress: 0.8, message: "Verifying registration")

        await progress.report(phase: "complete", progress: 1.0, message: "Device registered successfully")

        return [
            "device_id": .string(device.id),
            "udid": .string(udid),
            "name": .string(device.attributes.name ?? deviceName),
            "platform": .string(device.attributes.platform ?? platform),
            "status": .string(device.attributes.status ?? "ENABLED"),
            "already_registered": .bool(false),
        ]
    }
}
