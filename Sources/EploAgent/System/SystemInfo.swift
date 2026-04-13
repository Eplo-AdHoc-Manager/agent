import Foundation

/// Gathers hardware and software information about the current Mac.
struct SystemInfo: Sendable {
    let macOSVersion: String
    let xcodeVersion: String
    let architecture: String
    let diskFreeGB: Int
    let hostname: String
    let cpuUsage: Double
    let memoryUsage: Double

    /// Gathers system information from the current machine.
    static func gather() async -> SystemInfo {
        async let macOS = getMacOSVersion()
        async let xcode = getXcodeVersion()
        async let disk = getDiskFreeGB()
        async let cpu = getCPUUsage()
        async let memory = getMemoryUsage()

        return await SystemInfo(
            macOSVersion: macOS,
            xcodeVersion: xcode,
            architecture: getArchitecture(),
            diskFreeGB: disk,
            hostname: ProcessInfo.processInfo.hostName,
            cpuUsage: cpu,
            memoryUsage: memory
        )
    }

    // MARK: - macOS Version

    private static func getMacOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - Xcode Version

    private static func getXcodeVersion() async -> String {
        do {
            let output = try await runProcess("/usr/bin/xcodebuild", arguments: ["-version"])
            // Output is like "Xcode 16.2\nBuild version 16C5032a"
            let lines = output.components(separatedBy: .newlines)
            if let firstLine = lines.first,
               firstLine.hasPrefix("Xcode") {
                return firstLine
                    .replacingOccurrences(of: "Xcode ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            return "Not installed"
        } catch {
            return "Not installed"
        }
    }

    // MARK: - Architecture

    private static func getArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Disk Space

    private static func getDiskFreeGB() async -> Int {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            )
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                return Int(freeSize / (1024 * 1024 * 1024))
            }
        } catch {
            // Fall through.
        }
        return 0
    }

    // MARK: - CPU Usage

    private static func getCPUUsage() async -> Double {
        // Simplified CPU usage approximation using host_statistics.
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    intPtr,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }

        let userTicks = Double(loadInfo.cpu_ticks.0) // CPU_STATE_USER
        let systemTicks = Double(loadInfo.cpu_ticks.1) // CPU_STATE_SYSTEM
        let idleTicks = Double(loadInfo.cpu_ticks.2) // CPU_STATE_IDLE
        let niceTicks = Double(loadInfo.cpu_ticks.3) // CPU_STATE_NICE

        let totalTicks = userTicks + systemTicks + idleTicks + niceTicks
        guard totalTicks > 0 else { return 0.0 }

        let usedTicks = userTicks + systemTicks + niceTicks
        return (usedTicks / totalTicks) * 100.0
    }

    // MARK: - Memory Usage

    private static func getMemoryUsage() async -> Double {
        let totalMemory = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    intPtr,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let activeMemory = UInt64(stats.active_count) * pageSize
        let wiredMemory = UInt64(stats.wire_count) * pageSize
        let compressedMemory = UInt64(stats.compressor_page_count) * pageSize

        let usedMemory = activeMemory + wiredMemory + compressedMemory
        return (Double(usedMemory) / Double(totalMemory)) * 100.0
    }

    // MARK: - Process Helper

    private static func runProcess(_ path: String, arguments: [String] = []) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SystemInfo", code: Int(process.terminationStatus))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
