import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL
import WebSocketKit
import EploProtocol

/// Maintains a persistent WebSocket connection to the Eplo control plane.
///
/// Responsibilities:
/// - Connects with Bearer token authentication
/// - Performs the HELLO -> CAPABILITIES -> READY handshake
/// - Dispatches incoming messages to registered handlers
/// - Sends periodic heartbeats (every 30 seconds)
/// - Auto-reconnects with exponential backoff on disconnection
actor AgentWebSocketClient {
    // MARK: - Types

    enum State: Sendable {
        case disconnected
        case connecting
        case handshaking
        case ready
        case shuttingDown
    }

    typealias MessageHandler = @Sendable (ProtocolMessage) async -> Void

    // MARK: - Properties

    private let config: AgentConfig
    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup
    private var webSocket: WebSocket?
    private var state: State = .disconnected
    private var reconnectStrategy = ReconnectStrategy()
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var messageHandler: MessageHandler?
    private let startTime = Date()
    private(set) var currentJobId: String?

    // MARK: - Init

    init(config: AgentConfig, eventLoopGroup: EventLoopGroup, logger: Logger) {
        self.config = config
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
    }

    // MARK: - Public API

    /// Registers a handler for incoming protocol messages.
    func onMessage(_ handler: @escaping MessageHandler) {
        self.messageHandler = handler
    }

    /// Opens the WebSocket connection and starts the handshake.
    func connect() async {
        guard state == .disconnected else {
            logger.warning("Connect called while in state \(state)")
            return
        }

        state = .connecting
        await performConnect()
    }

    /// Gracefully closes the connection.
    func disconnect() async {
        state = .shuttingDown
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        if let ws = webSocket, !ws.isClosed {
            try? await ws.close().get()
        }
        webSocket = nil
        state = .disconnected
        logger.info("Disconnected from control plane")
    }

    /// Sends a protocol message over the WebSocket.
    func send(_ message: ProtocolMessage) async throws {
        guard let ws = webSocket, !ws.isClosed else {
            throw WebSocketClientError.notConnected
        }

        let envelope = try encodeMessage(message)
        let data = try MessageEnvelope.makeEncoder().encode(envelope)
        let text = String(data: data, encoding: .utf8)!
        try await ws.send(text)
        logger.trace("Sent message: \(envelope.type.rawValue)")
    }

    /// Updates the current job ID for heartbeat reporting.
    func setCurrentJob(_ jobId: String?) {
        currentJobId = jobId
    }

    /// Returns the current connection state.
    var connectionState: State {
        state
    }

    /// Time since the agent started.
    var uptime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    // MARK: - Connection

    private func performConnect() async {
        let serverURL = config.serverURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let wsURL = serverURL.hasSuffix("/")
            ? "\(serverURL)ws/agent"
            : "\(serverURL)/ws/agent"

        logger.info("Connecting to \(wsURL)...")

        var tlsConfig: TLSConfiguration?
        if wsURL.hasPrefix("wss://") {
            tlsConfig = TLSConfiguration.makeClientConfiguration()
        }

        let headers = HTTPHeaders([
            ("Authorization", "Bearer \(config.token)"),
            ("X-Agent-Version", AgentVersion.current),
            ("X-Runner-ID", config.runnerID.uuidString),
        ])

        do {
            try await WebSocket.connect(
                to: wsURL,
                headers: headers,
                configuration: .init(tlsConfiguration: tlsConfig),
                on: eventLoopGroup
            ) { ws in
                await self.handleConnected(ws)
            }
        } catch {
            logger.error("Connection failed: \(error)")
            await scheduleReconnect()
        }
    }

    private func handleConnected(_ ws: WebSocket) {
        self.webSocket = ws
        self.state = .handshaking
        self.reconnectStrategy.reset()
        logger.info("WebSocket connected, waiting for HELLO...")

        ws.onText { _, text in
            await self.handleIncomingText(text)
        }

        ws.onClose.whenComplete { _ in
            Task {
                await self.handleDisconnect()
            }
        }
    }

    private func handleIncomingText(_ text: String) async {
        guard let data = text.data(using: .utf8) else {
            logger.error("Could not decode incoming text as UTF-8")
            return
        }

        do {
            let envelope = try MessageEnvelope.makeDecoder().decode(
                MessageEnvelope.self,
                from: data
            )
            logger.trace("Received message: \(envelope.type.rawValue)")
            await handleEnvelope(envelope)
        } catch {
            logger.error("Failed to decode message: \(error)")
        }
    }

    // MARK: - Message Handling

    private func handleEnvelope(_ envelope: MessageEnvelope) async {
        switch envelope.type {
        case .hello:
            await handleHello(envelope)
        case .ready:
            await handleReady()
        case .ping:
            try? await send(.pong)
        case .jobDispatch, .jobCancel, .syncRequest, .configUpdate, .updateAvailable:
            let message = try? decodeMessage(envelope)
            if let message {
                await messageHandler?(message)
            }
        default:
            logger.warning("Unexpected message type from server: \(envelope.type.rawValue)")
        }
    }

    private func handleHello(_ envelope: MessageEnvelope) async {
        logger.info("Received HELLO from server")

        let systemInfo = await SystemInfo.gather()
        let capabilities = CapabilitiesPayload(
            agentVersion: AgentVersion.current,
            protocolVersion: ProtocolVersion.current,
            capabilities: RunnerCapabilities(
                macOSVersion: systemInfo.macOSVersion,
                xcodeVersion: systemInfo.xcodeVersion,
                architecture: systemInfo.architecture,
                availableDiskGB: systemInfo.diskFreeGB,
                certificateCount: 0,
                profileCount: 0
            )
        )

        do {
            try await send(.capabilities(capabilities))
            logger.info("Sent CAPABILITIES")
        } catch {
            logger.error("Failed to send capabilities: \(error)")
        }
    }

    private func handleReady() async {
        state = .ready
        logger.info("Handshake complete - agent is READY")
        startHeartbeat()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }

                let systemInfo = await SystemInfo.gather()
                let runnerId = self.config.runnerID.uuidString
                let jobId = self.currentJobId
                let uptimeValue = self.uptime

                let payload = HeartbeatPayload(
                    runnerId: runnerId,
                    status: jobId != nil ? .busy : .online,
                    uptime: uptimeValue,
                    currentJobId: jobId,
                    cpuUsage: systemInfo.cpuUsage,
                    memoryUsage: systemInfo.memoryUsage,
                    diskFreeGB: systemInfo.diskFreeGB
                )

                try? await self.send(.heartbeat(payload))
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() async {
        webSocket = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        guard state != .shuttingDown else { return }

        state = .disconnected
        logger.warning("WebSocket disconnected")
        await scheduleReconnect()
    }

    private func scheduleReconnect() async {
        guard state != .shuttingDown else { return }

        var strategy = reconnectStrategy
        let delay = strategy.nextDelay()
        reconnectStrategy = strategy

        logger.info("Reconnecting in \(String(format: "%.1f", delay))s (attempt \(reconnectStrategy.attempt))...")

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.performConnect()
        }
    }

    // MARK: - Encoding / Decoding

    private func encodeMessage(_ message: ProtocolMessage) throws -> MessageEnvelope {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        switch message {
        case .capabilities(let payload):
            let data = try encoder.encode(payload)
            let dict = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
            return MessageEnvelope(
                type: .capabilities,
                id: generateMessageId(),
                payload: dict
            )

        case .heartbeat(let payload):
            let data = try encoder.encode(payload)
            let decoder = JSONDecoder()
            let dict = try decoder.decode([String: AnyCodableValue].self, from: data)
            return MessageEnvelope(
                type: .heartbeat,
                id: generateMessageId(),
                payload: dict
            )

        case .jobAccepted(let jobId):
            return MessageEnvelope(
                type: .jobAccepted,
                id: generateMessageId(),
                payload: ["job_id": .string(jobId)]
            )

        case .jobProgress(let payload):
            let data = try encoder.encode(payload)
            let dict = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
            return MessageEnvelope(
                type: .jobProgress,
                id: generateMessageId(),
                payload: dict
            )

        case .jobResult(let payload):
            let data = try encoder.encode(payload)
            let dict = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
            return MessageEnvelope(
                type: .jobResult,
                id: generateMessageId(),
                payload: dict
            )

        case .pong:
            return MessageEnvelope(
                type: .pong,
                id: generateMessageId()
            )

        case .error(let protocolError):
            return MessageEnvelope(
                type: .error,
                id: generateMessageId(),
                payload: ["code": .string(protocolError.rawValue)]
            )

        case .resume(let lastMessageId):
            return MessageEnvelope(
                type: .resume,
                id: generateMessageId(),
                payload: ["last_message_id": .string(lastMessageId)]
            )

        case .logs(let entries):
            let data = try encoder.encode(entries)
            let array = try JSONDecoder().decode([AnyCodableValue].self, from: data)
            return MessageEnvelope(
                type: .logs,
                id: generateMessageId(),
                payload: ["entries": .array(array)]
            )

        case .syncResponse(let requestId, let state):
            var payload = state
            payload["request_id"] = .string(requestId)
            return MessageEnvelope(
                type: .syncResponse,
                id: generateMessageId(),
                payload: payload
            )

        default:
            throw WebSocketClientError.unsupportedMessageType
        }
    }

    private func decodeMessage(_ envelope: MessageEnvelope) throws -> ProtocolMessage {
        let encoder = JSONEncoder()
        let decoder = MessageEnvelope.makeDecoder()

        switch envelope.type {
        case .hello:
            let data = try encoder.encode(envelope.payload)
            let payload = try decoder.decode(HelloPayload.self, from: data)
            return .hello(payload)

        case .ready:
            return .ready

        case .jobDispatch:
            let data = try encoder.encode(envelope.payload)
            let payload = try decoder.decode(JobDispatchPayload.self, from: data)
            return .jobDispatch(payload)

        case .jobCancel:
            guard case .string(let jobId) = envelope.payload["job_id"] else {
                throw WebSocketClientError.invalidPayload
            }
            return .jobCancel(jobId: jobId)

        case .syncRequest:
            guard case .string(let requestId) = envelope.payload["request_id"] else {
                throw WebSocketClientError.invalidPayload
            }
            return .syncRequest(requestId: requestId)

        case .configUpdate:
            return .configUpdate(config: envelope.payload)

        case .updateAvailable:
            guard case .string(let version) = envelope.payload["version"],
                  case .string(let url) = envelope.payload["url"] else {
                throw WebSocketClientError.invalidPayload
            }
            return .updateAvailable(version: version, url: url)

        case .ping:
            return .ping

        default:
            throw WebSocketClientError.unsupportedMessageType
        }
    }

    private func generateMessageId() -> String {
        UUID().uuidString.lowercased()
    }
}

// MARK: - Errors

enum WebSocketClientError: Error, CustomStringConvertible {
    case notConnected
    case unsupportedMessageType
    case invalidPayload

    var description: String {
        switch self {
        case .notConnected:
            return "WebSocket is not connected"
        case .unsupportedMessageType:
            return "Unsupported message type for this direction"
        case .invalidPayload:
            return "Invalid or missing payload fields"
        }
    }
}
