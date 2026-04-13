import Foundation
import Logging
import EploProtocol

/// Verifies that the runner is healthy and capable of executing jobs.
struct HealthCheckHandler: Sendable {
    let logger: Logger

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        await progress.report(phase: "checking", progress: 0.0, message: "Running health checks")

        logger.info("Running health check for job \(job.jobId)")

        var checks: [String: AnyCodableValue] = [:]
        var allHealthy = true

        // 1. Check Xcode.
        await progress.report(phase: "xcode", progress: 0.1, message: "Checking Xcode installation")

        let systemInfo = await SystemInfo.gather()
        let xcodeOk = systemInfo.xcodeVersion != "Not installed"
        checks["xcode"] = .dictionary([
            "healthy": .bool(xcodeOk),
            "version": .string(systemInfo.xcodeVersion),
        ])
        if !xcodeOk {
            allHealthy = false
            logger.warning("Xcode is not installed")
        }

        try Task.checkCancellation()

        // 2. Check disk space (require at least 5 GB free).
        await progress.report(phase: "disk", progress: 0.2, message: "Checking disk space")

        let diskOk = systemInfo.diskFreeGB >= 5
        checks["disk"] = .dictionary([
            "healthy": .bool(diskOk),
            "free_gb": .int(systemInfo.diskFreeGB),
        ])
        if !diskOk {
            allHealthy = false
            logger.warning("Low disk space: \(systemInfo.diskFreeGB) GB")
        }

        // 3. Check Keychain accessibility.
        await progress.report(phase: "keychain", progress: 0.3, message: "Checking Keychain access")

        var keychainOk = false
        var identityCount = 0
        do {
            let keychainManager = KeychainManager()
            let identities = try keychainManager.listSigningIdentities()
            identityCount = identities.count
            keychainOk = true
        } catch {
            logger.warning("Keychain access failed: \(error)")
            allHealthy = false
        }
        checks["keychain"] = .dictionary([
            "healthy": .bool(keychainOk),
            "signing_identities": .int(identityCount),
        ])

        try Task.checkCancellation()

        // 4. Check .p8 key availability.
        await progress.report(phase: "api_keys", progress: 0.5, message: "Checking Apple API keys")

        var apiKeyCount = 0
        var apiKeyOk = false
        do {
            let keychainManager = KeychainManager()
            let keys = try keychainManager.listAppleKeys()
            apiKeyCount = keys.count
            apiKeyOk = !keys.isEmpty
        } catch {
            logger.warning("Failed to list API keys: \(error)")
        }
        if !apiKeyOk {
            allHealthy = false
        }
        checks["api_keys"] = .dictionary([
            "healthy": .bool(apiKeyOk),
            "count": .int(apiKeyCount),
        ])

        try Task.checkCancellation()

        // 5. Test network connectivity to api.appstoreconnect.apple.com.
        await progress.report(phase: "network", progress: 0.7, message: "Checking network connectivity")

        var networkOk = false
        do {
            let url = URL(string: "https://api.appstoreconnect.apple.com/v1/")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                // 401 is expected (no auth), but it means the network is reachable.
                networkOk = httpResponse.statusCode == 401 || (200..<500).contains(httpResponse.statusCode)
            }
        } catch {
            logger.warning("Network connectivity check failed: \(error)")
            allHealthy = false
        }
        checks["network"] = .dictionary([
            "healthy": .bool(networkOk),
            "endpoint": .string("api.appstoreconnect.apple.com"),
        ])

        // 6. Check xcodebuild command-line tools.
        await progress.report(phase: "cli_tools", progress: 0.85, message: "Checking command-line tools")

        var cliToolsOk = false
        var xcodeSelectPath = ""
        do {
            let result = try await ShellExecutor.execute(
                "/usr/bin/xcode-select",
                arguments: ["-p"]
            )
            if result.succeeded {
                cliToolsOk = true
                xcodeSelectPath = result.stdout
            }
        } catch {
            logger.warning("xcode-select check failed: \(error)")
        }
        checks["cli_tools"] = .dictionary([
            "healthy": .bool(cliToolsOk),
            "developer_dir": .string(xcodeSelectPath),
        ])
        if !cliToolsOk {
            allHealthy = false
        }

        // Summary.
        logger.info("""
        Health check results:
          Xcode: \(systemInfo.xcodeVersion)
          Disk: \(systemInfo.diskFreeGB) GB free
          Keychain: \(keychainOk ? "OK" : "FAIL") (\(identityCount) identities)
          API Keys: \(apiKeyCount) key(s)
          Network: \(networkOk ? "OK" : "FAIL")
          CLI Tools: \(cliToolsOk ? "OK" : "FAIL")
          Architecture: \(systemInfo.architecture)
          Overall: \(allHealthy ? "HEALTHY" : "DEGRADED")
        """)

        await progress.report(phase: "complete", progress: 1.0, message: "Health check complete")

        return [
            "healthy": .bool(allHealthy),
            "macos_version": .string(systemInfo.macOSVersion),
            "xcode_version": .string(systemInfo.xcodeVersion),
            "architecture": .string(systemInfo.architecture),
            "hostname": .string(systemInfo.hostname),
            "disk_free_gb": .int(systemInfo.diskFreeGB),
            "cpu_usage": .double(systemInfo.cpuUsage),
            "memory_usage": .double(systemInfo.memoryUsage),
            "checks": .dictionary(checks),
        ]
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
