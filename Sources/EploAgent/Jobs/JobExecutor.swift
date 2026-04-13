import Foundation
import Logging
import EploProtocol

/// Dispatches incoming jobs to the appropriate handler and manages execution lifecycle.
actor JobExecutor {
    private let logger: Logger
    private var activeTasks: [String: Task<Void, Never>] = [:]

    init(logger: Logger) {
        self.logger = logger
    }

    /// Executes a dispatched job, routing to the appropriate handler.
    func execute(_ job: JobDispatchPayload, connection: AgentWebSocketClient, config: AgentConfig) async throws {
        let jobId = job.jobId
        logger.info("Executing job \(jobId) (type: \(job.jobType.rawValue))")

        let task = Task {
            do {
                let progressReporter = ProgressReporter(
                    jobId: jobId,
                    connection: connection,
                    logger: logger
                )

                let handlerResult: [String: AnyCodableValue]

                switch job.jobType {
                case .registerDevice:
                    let handler = DeviceRegistrationHandler(logger: logger)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)

                case .regenerateProfile:
                    let handler = ProfileRegenerationHandler(logger: logger)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)

                case .exportIPA:
                    let handler = IPAExportHandler(logger: logger, config: config)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)

                case .fullDistribution:
                    let handler = FullDistributionHandler(logger: logger, config: config)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)

                case .syncCertificates:
                    let handler = CertificateSyncHandler(logger: logger)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)

                case .syncDevices:
                    let handler = DeviceSyncHandler(logger: logger)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)

                case .healthCheck:
                    let handler = HealthCheckHandler(logger: logger)
                    handlerResult = try await handler.execute(job: job, progress: progressReporter)
                }

                // Send success result.
                let result = JobResultPayload(
                    jobId: jobId,
                    success: true,
                    result: handlerResult
                )
                try? await connection.send(.jobResult(result))
                logger.info("Job \(jobId) completed successfully")

            } catch is CancellationError {
                logger.info("Job \(jobId) was cancelled")
                let result = JobResultPayload(
                    jobId: jobId,
                    success: false,
                    error: JobError(
                        code: "cancelled",
                        message: "Job was cancelled",
                        severity: .transient,
                        retryable: true
                    )
                )
                try? await connection.send(.jobResult(result))

            } catch {
                logger.error("Job \(jobId) failed: \(error)")
                let result = JobResultPayload(
                    jobId: jobId,
                    success: false,
                    error: JobError(
                        code: "execution_error",
                        message: error.localizedDescription,
                        severity: .transient,
                        retryable: true
                    )
                )
                try? await connection.send(.jobResult(result))
            }
        }

        activeTasks[jobId] = task
        await task.value
        activeTasks.removeValue(forKey: jobId)
    }

    /// Cancels a running job by its ID.
    func cancel(jobId: String) {
        if let task = activeTasks[jobId] {
            task.cancel()
            logger.info("Cancelled job \(jobId)")
        } else {
            logger.warning("Cannot cancel job \(jobId): not found in active tasks")
        }
    }
}

// MARK: - ProgressReporter

/// Helper for sending job progress updates over the WebSocket connection.
struct ProgressReporter: Sendable {
    let jobId: String
    let connection: AgentWebSocketClient
    let logger: Logger

    func report(phase: String, progress: Double, message: String? = nil) async {
        let payload = JobProgressPayload(
            jobId: jobId,
            phase: phase,
            progress: progress,
            message: message
        )
        do {
            try await connection.send(.jobProgress(payload))
        } catch {
            logger.warning("Failed to send progress for job \(jobId): \(error)")
        }
    }
}
