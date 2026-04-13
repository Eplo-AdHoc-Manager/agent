import Foundation
import Logging
import EploProtocol

/// Syncs the registered device list from the Apple Developer portal.
struct DeviceSyncHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        await progress.report(phase: "fetching", progress: 0.0, message: "Fetching device list from Apple")

        logger.info("Syncing device list for job \(job.jobId)")

        let client = try AppStoreConnectClient.fromKeychain(logger: logger)

        try Task.checkCancellation()

        // Fetch all devices (paginated).
        await progress.report(phase: "listing", progress: 0.2, message: "Listing registered devices")

        let devices = try await client.listDevices()
        logger.info("Fetched \(devices.count) devices from App Store Connect")

        try Task.checkCancellation()

        await progress.report(phase: "processing", progress: 0.6, message: "Processing device list")

        // Build the device list for the control plane.
        var deviceEntries: [AnyCodableValue] = []
        var enabledCount = 0
        var disabledCount = 0

        for device in devices {
            let status = device.attributes.status ?? "UNKNOWN"
            if status == "ENABLED" {
                enabledCount += 1
            } else {
                disabledCount += 1
            }

            let entry: [String: AnyCodableValue] = [
                "device_id": .string(device.id),
                "name": .string(device.attributes.name ?? "Unknown"),
                "udid": .string(device.attributes.udid ?? ""),
                "platform": .string(device.attributes.platform ?? ""),
                "status": .string(status),
                "device_class": .string(device.attributes.deviceClass ?? ""),
                "model": .string(device.attributes.model ?? ""),
            ]

            deviceEntries.append(.dictionary(entry))
        }

        await progress.report(
            phase: "reporting",
            progress: 0.9,
            message: "Found \(devices.count) devices (\(enabledCount) enabled, \(disabledCount) disabled)"
        )

        await progress.report(phase: "complete", progress: 1.0, message: "Device sync complete")

        return [
            "total_count": .int(devices.count),
            "enabled_count": .int(enabledCount),
            "disabled_count": .int(disabledCount),
            "devices": .array(deviceEntries),
        ]
    }
}
