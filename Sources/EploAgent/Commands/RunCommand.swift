import ArgumentParser
import Foundation
import Logging
import NIO
import EploProtocol
#if canImport(Darwin)
import Darwin
#endif

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the Eplo agent daemon."
    )

    @Flag(name: .long, help: "Run in the foreground (default behavior).")
    var foreground: Bool = false

    func run() async throws {
        let logger = AgentLogger.bootstrap(label: "eplo.agent.run")

        guard AgentConfig.exists else {
            print("Error: Agent not configured. Run 'eplo-agent pair' first.")
            throw ExitCode.failure
        }

        let config = try AgentConfig.load()
        logger.info("Loaded configuration for runner \(config.runnerID)")
        logger.info("Connecting to \(config.serverURL)")

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let wsClient = AgentWebSocketClient(
            config: config,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )

        let jobExecutor = JobExecutor(logger: logger)

        // Register message handler.
        await wsClient.onMessage { message in
            switch message {
            case .jobDispatch(let payload):
                logger.info("Received job: \(payload.jobId) (\(payload.jobType.rawValue))")
                try? await wsClient.send(.jobAccepted(jobId: payload.jobId))
                await wsClient.setCurrentJob(payload.jobId)

                do {
                    try await jobExecutor.execute(payload, connection: wsClient)
                } catch {
                    logger.error("Job \(payload.jobId) failed: \(error)")
                }

                await wsClient.setCurrentJob(nil)

            case .jobCancel(let jobId):
                logger.info("Job cancel requested: \(jobId)")
                await jobExecutor.cancel(jobId: jobId)

            case .configUpdate(let newConfig):
                logger.info("Received config update: \(newConfig.count) keys")

            case .updateAvailable(let version, _):
                logger.info("Update available: v\(version)")

            case .syncRequest(let requestId):
                logger.info("Sync request: \(requestId)")
                try? await wsClient.send(
                    .syncResponse(requestId: requestId, state: [:])
                )

            default:
                break
            }
        }

        // Connect.
        await wsClient.connect()

        print("Eplo Agent running (runner: \(config.runnerID))")
        print("Press Ctrl+C to stop.")

        // Wait for termination signal using DispatchSource.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            // Ignore default signal handling so DispatchSource receives them.
            Darwin.signal(SIGINT, SIG_IGN)
            Darwin.signal(SIGTERM, SIG_IGN)

            var resumed = false
            let handler = {
                guard !resumed else { return }
                resumed = true
                sigintSource.cancel()
                sigtermSource.cancel()
                continuation.resume()
            }

            sigintSource.setEventHandler(handler: handler)
            sigtermSource.setEventHandler(handler: handler)
            sigintSource.resume()
            sigtermSource.resume()
        }

        logger.info("Shutting down...")
        await wsClient.disconnect()

        try await eventLoopGroup.shutdownGracefully()
        logger.info("Agent stopped")
    }
}
