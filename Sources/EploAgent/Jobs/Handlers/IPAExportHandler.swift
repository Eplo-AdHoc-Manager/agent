import Foundation
import Logging
import Crypto
import EploProtocol

/// Exports an IPA for ad-hoc distribution using xcodebuild.
struct IPAExportHandler: Sendable {
    let logger: Logger
    let config: AgentConfig

    func execute(job: JobDispatchPayload, progress: ProgressReporter) async throws -> [String: AnyCodableValue] {
        await progress.report(phase: "preparing", progress: 0.0, message: "Preparing IPA export")

        guard case .string(let archivePath) = job.parameters["archive_path"] else {
            throw JobHandlerError.missingParameter("archive_path")
        }

        guard case .string(let exportMethod) = job.parameters["export_method"] else {
            throw JobHandlerError.missingParameter("export_method")
        }

        // Optional parameters.
        let teamId = job.parameters["team_id"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        let signingCertificate = job.parameters["signing_certificate"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        let provisioningProfileName = job.parameters["provisioning_profile_name"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        let bundleId = job.parameters["bundle_id"]
            .flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        // Verify archive exists.
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw JobHandlerError.executionFailed("Archive not found at path: \(archivePath)")
        }

        logger.info("Exporting IPA from archive: \(archivePath)")

        // Step 1: Generate ExportOptions.plist.
        await progress.report(phase: "export_options", progress: 0.1, message: "Generating export options plist")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eplo-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let exportOptionsPath = tempDir.appendingPathComponent("ExportOptions.plist").path
        let exportPath = tempDir.appendingPathComponent("output").path
        try FileManager.default.createDirectory(atPath: exportPath, withIntermediateDirectories: true)

        let exportOptionsPlist = buildExportOptionsPlist(
            method: exportMethod,
            teamId: teamId,
            signingCertificate: signingCertificate,
            bundleId: bundleId,
            provisioningProfileName: provisioningProfileName
        )

        try exportOptionsPlist.write(toFile: exportOptionsPath, atomically: true, encoding: .utf8)
        logger.info("Export options written to: \(exportOptionsPath)")

        try Task.checkCancellation()

        // Step 2: Run xcodebuild -exportArchive.
        await progress.report(phase: "exporting", progress: 0.2, message: "Running xcodebuild -exportArchive")

        let xcodebuildArgs = [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportPath,
            "-exportOptionsPlist", exportOptionsPath,
        ]

        let xcodebuildResult = try await ShellExecutor.executeWithStreaming(
            "/usr/bin/xcodebuild",
            arguments: xcodebuildArgs
        ) { line in
            // xcodebuild progress lines can be parsed for status reporting.
            // We log them for diagnostics.
            if line.contains("Export") || line.contains("Signing") || line.contains("Processing") {
                Task {
                    await progress.report(
                        phase: "exporting",
                        progress: 0.4,
                        message: line.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        guard xcodebuildResult.succeeded else {
            // Include relevant stderr in the error message.
            let errorOutput = xcodebuildResult.stderr.isEmpty
                ? xcodebuildResult.stdout
                : xcodebuildResult.stderr
            let truncated = String(errorOutput.suffix(500))
            throw JobHandlerError.executionFailed(
                "xcodebuild -exportArchive failed (exit \(xcodebuildResult.exitCode)): \(truncated)"
            )
        }

        logger.info("xcodebuild export completed successfully")

        try Task.checkCancellation()

        // Step 3: Find the generated .ipa file.
        await progress.report(phase: "verifying", progress: 0.7, message: "Locating IPA file")

        let outputContents = try FileManager.default.contentsOfDirectory(atPath: exportPath)
        guard let ipaFilename = outputContents.first(where: { $0.hasSuffix(".ipa") }) else {
            throw JobHandlerError.executionFailed("No .ipa file found in export output directory")
        }

        let ipaPath = "\(exportPath)/\(ipaFilename)"
        let ipaData = try Data(contentsOf: URL(fileURLWithPath: ipaPath))

        // Step 4: Calculate SHA-256 hash.
        let sha256Hash = SHA256.hash(data: ipaData)
        let hashString = sha256Hash.compactMap { String(format: "%02x", $0) }.joined()
        let ipaSize = ipaData.count

        logger.info("IPA: \(ipaFilename), size: \(ipaSize) bytes, SHA-256: \(hashString)")

        try Task.checkCancellation()

        // Step 5: Upload IPA to control plane via presigned URL.
        await progress.report(phase: "uploading", progress: 0.8, message: "Uploading IPA to control plane")

        let uploadResult = try await uploadIPA(
            ipaData: ipaData,
            filename: ipaFilename,
            sha256: hashString,
            jobId: job.jobId
        )

        try Task.checkCancellation()

        // Step 6: Notify control plane of completion.
        await progress.report(phase: "finalizing", progress: 0.95, message: "Notifying control plane")

        try await notifyUploadComplete(
            jobId: job.jobId,
            sha256: hashString,
            size: ipaSize,
            downloadURL: uploadResult.downloadURL
        )

        // Clean up temp files (best-effort).
        try? FileManager.default.removeItem(at: tempDir)

        await progress.report(phase: "complete", progress: 1.0, message: "IPA exported and uploaded successfully")

        return [
            "ipa_filename": .string(ipaFilename),
            "ipa_size": .int(ipaSize),
            "sha256": .string(hashString),
            "download_url": .string(uploadResult.downloadURL),
        ]
    }

    // MARK: - Export Options Plist

    private func buildExportOptionsPlist(
        method: String,
        teamId: String?,
        signingCertificate: String?,
        bundleId: String?,
        provisioningProfileName: String?
    ) -> String {
        var plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>method</key>
            <string>\(method)</string>
            <key>signingStyle</key>
            <string>manual</string>
            <key>stripSwiftSymbols</key>
            <true/>
            <key>uploadSymbols</key>
            <false/>
        """

        if let teamId = teamId {
            plist += """

                <key>teamID</key>
                <string>\(teamId)</string>
            """
        }

        if let cert = signingCertificate {
            plist += """

                <key>signingCertificate</key>
                <string>\(cert)</string>
            """
        }

        if let bundleId = bundleId, let profileName = provisioningProfileName {
            plist += """

                <key>provisioningProfiles</key>
                <dict>
                    <key>\(bundleId)</key>
                    <string>\(profileName)</string>
                </dict>
            """
        }

        plist += """

        </dict>
        </plist>
        """

        return plist
    }

    // MARK: - IPA Upload

    private struct UploadURLResponse: Codable {
        let uploadURL: String
        let downloadURL: String

        private enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case downloadURL = "download_url"
        }
    }

    private func uploadIPA(
        ipaData: Data,
        filename: String,
        sha256: String,
        jobId: String
    ) async throws -> UploadURLResponse {
        // Step 1: Request a presigned upload URL from the control plane.
        let serverURL = config.serverURL.hasSuffix("/")
            ? String(config.serverURL.dropLast())
            : config.serverURL

        let uploadURLEndpoint = URL(string: "\(serverURL)/internal/ota/upload-url")!
        var uploadURLRequest = URLRequest(url: uploadURLEndpoint)
        uploadURLRequest.httpMethod = "POST"
        uploadURLRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        uploadURLRequest.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let requestBody: [String: Any] = [
            "job_id": jobId,
            "filename": filename,
            "size": ipaData.count,
            "sha256": sha256,
        ]
        uploadURLRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await URLSession.shared.data(for: uploadURLRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw JobHandlerError.executionFailed(
                "Failed to get upload URL (HTTP \(statusCode)): \(body)"
            )
        }

        let uploadURLResponse = try JSONDecoder().decode(UploadURLResponse.self, from: responseData)

        // Step 2: PUT the IPA to the presigned URL.
        var putRequest = URLRequest(url: URL(string: uploadURLResponse.uploadURL)!)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = ipaData

        let (_, putResponse) = try await URLSession.shared.data(for: putRequest)
        guard let putHttpResponse = putResponse as? HTTPURLResponse,
              (200..<300).contains(putHttpResponse.statusCode) else {
            let statusCode = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw JobHandlerError.executionFailed("Failed to upload IPA (HTTP \(statusCode))")
        }

        logger.info("IPA uploaded successfully")
        return uploadURLResponse
    }

    private func notifyUploadComplete(
        jobId: String,
        sha256: String,
        size: Int,
        downloadURL: String
    ) async throws {
        let serverURL = config.serverURL.hasSuffix("/")
            ? String(config.serverURL.dropLast())
            : config.serverURL

        let completeEndpoint = URL(string: "\(serverURL)/internal/ota/complete")!
        var request = URLRequest(url: completeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "job_id": jobId,
            "sha256": sha256,
            "size": size,
            "download_url": downloadURL,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            logger.warning("Failed to notify upload completion (HTTP \(httpResponse.statusCode))")
        }
    }
}
