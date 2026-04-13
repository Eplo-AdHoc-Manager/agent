import Foundation
import Logging
import EploProtocol

/// Verifies that the runner is healthy and capable of executing jobs.
struct HealthCheckHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws {
        await progress.report(phase: "checking", progress: 0.0, message: "Running health checks")

        logger.info("Running health check for job \(job.jobId)")

        let systemInfo = await SystemInfo.gather()

        // Check Xcode.
        await progress.report(phase: "xcode", progress: 0.2, message: "Checking Xcode installation")
        let xcodeOk = systemInfo.xcodeVersion != "Not installed"
        if !xcodeOk {
            logger.warning("Xcode is not installed")
        }

        try Task.checkCancellation()

        // Check disk space.
        await progress.report(phase: "disk", progress: 0.4, message: "Checking disk space")
        let diskOk = systemInfo.diskFreeGB >= 5
        if !diskOk {
            logger.warning("Low disk space: \(systemInfo.diskFreeGB) GB")
        }

        // Check keychain.
        await progress.report(phase: "keychain", progress: 0.6, message: "Checking Keychain access")
        let keychainManager = KeychainManager()
        let identities = try keychainManager.listSigningIdentities()

        // Check signing identities.
        await progress.report(phase: "signing", progress: 0.8, message: "Checking signing identities")

        logger.info("""
        Health check results:
          Xcode: \(systemInfo.xcodeVersion)
          Disk: \(systemInfo.diskFreeGB) GB free
          Identities: \(identities.count)
          Architecture: \(systemInfo.architecture)
        """)

        await progress.report(phase: "complete", progress: 1.0, message: "Health check complete")
    }
}

// MARK: - Job Handler Error

enum JobHandlerError: Error, CustomStringConvertible {
    case missingParameter(String)
    case executionFailed(String)
    case notImplemented(String)

    var description: String {
        switch self {
        case .missingParameter(let name):
            return "Missing required parameter: \(name)"
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .notImplemented(let feature):
            return "Not implemented: \(feature)"
        }
    }
}
