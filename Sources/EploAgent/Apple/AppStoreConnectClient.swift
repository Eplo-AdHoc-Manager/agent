import Foundation
import Crypto
import Logging

/// HTTP client for Apple's App Store Connect API v1.
///
/// Uses a .p8 private key (ES256) to generate JWT tokens for authentication.
/// All API calls go through `https://api.appstoreconnect.apple.com/v1/`.
actor AppStoreConnectClient {
    private static let baseURL = "https://api.appstoreconnect.apple.com/v1"
    private static let jwtAudience = "appstoreconnect-v1"
    private static let jwtLifetime: TimeInterval = 20 * 60 // 20 minutes

    private let keyId: String
    private let issuerId: String
    private let privateKey: P256.Signing.PrivateKey
    private let logger: Logger
    private let session: URLSession

    // Cache the JWT to avoid regenerating on every request.
    private var cachedJWT: String?
    private var jwtExpiry: Date = .distantPast

    // MARK: - Init

    /// Creates a client from the raw .p8 key data.
    ///
    /// - Parameters:
    ///   - keyId: The Key ID from App Store Connect (10-character identifier).
    ///   - issuerId: The Issuer ID from App Store Connect.
    ///   - privateKeyData: The raw .p8 file contents (PEM-encoded PKCS#8 EC key).
    ///   - logger: Logger instance.
    init(keyId: String, issuerId: String, privateKeyData: Data, logger: Logger) throws {
        self.keyId = keyId
        self.issuerId = issuerId
        self.logger = logger
        self.session = URLSession.shared

        guard let pemString = String(data: privateKeyData, encoding: .utf8) else {
            throw ASCClientError.jwtGenerationFailed("Cannot decode .p8 key data as UTF-8")
        }

        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pemString)
    }

    // MARK: - Devices

    /// Registers a new device with Apple.
    func registerDevice(name: String, udid: String, platform: String) async throws -> ASCDevice {
        let body = ASCDeviceCreateRequest(name: name, udid: udid, platform: platform)
        let data = try JSONEncoder().encode(body)

        do {
            let responseData = try await post(path: "/devices", body: data)
            let response = try makeDecoder().decode(ASCSingleResponse<ASCDevice>.self, from: responseData)
            return response.data
        } catch let error as ASCClientError {
            // If the device is already registered, Apple returns 409.
            // Try to find it in the existing list.
            if case .httpError(let code, _) = error, code == 409 {
                let devices = try await listDevices()
                if let existing = devices.first(where: { $0.attributes.udid == udid }) {
                    throw ASCClientError.deviceAlreadyRegistered(existing)
                }
            }
            throw error
        }
    }

    /// Lists all registered devices.
    func listDevices() async throws -> [ASCDevice] {
        try await getPaginated(path: "/devices?limit=200")
    }

    // MARK: - Profiles

    /// Lists all provisioning profiles.
    func listProfiles() async throws -> [ASCProfile] {
        try await getPaginated(path: "/profiles?limit=200")
    }

    /// Creates a new provisioning profile.
    func createProfile(
        name: String,
        type: String,
        bundleIdResourceId: String,
        certificateIds: [String],
        deviceIds: [String]
    ) async throws -> ASCProfile {
        let body = ASCProfileCreateRequest(
            name: name,
            profileType: type,
            bundleIdResourceId: bundleIdResourceId,
            certificateIds: certificateIds,
            deviceIds: deviceIds
        )
        let data = try JSONEncoder().encode(body)
        let responseData = try await post(path: "/profiles", body: data)
        let response = try makeDecoder().decode(ASCSingleResponse<ASCProfile>.self, from: responseData)
        return response.data
    }

    /// Deletes a provisioning profile by its resource ID.
    func deleteProfile(id: String) async throws {
        try await delete(path: "/profiles/\(id)")
    }

    /// Downloads a profile's content (base64-encoded .mobileprovision).
    /// The content is available in the `profileContent` attribute.
    func downloadProfile(id: String) async throws -> Data {
        let responseData = try await get(path: "/profiles/\(id)?fields[profiles]=profileContent")
        let response = try makeDecoder().decode(ASCSingleResponse<ASCProfile>.self, from: responseData)

        guard let base64Content = response.data.attributes.profileContent,
              let profileData = Data(base64Encoded: base64Content) else {
            throw ASCClientError.invalidResponse
        }

        return profileData
    }

    // MARK: - Certificates

    /// Lists all signing certificates.
    func listCertificates() async throws -> [ASCCertificate] {
        try await getPaginated(path: "/certificates?limit=200")
    }

    // MARK: - Bundle IDs

    /// Lists all registered bundle IDs.
    func listBundleIds() async throws -> [ASCBundleId] {
        try await getPaginated(path: "/bundleIds?limit=200")
    }

    /// Finds a bundle ID resource by its identifier string (e.g., "com.example.app").
    func getBundleId(identifier: String) async throws -> ASCBundleId? {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? identifier
        let items: [ASCBundleId] = try await getPaginated(
            path: "/bundleIds?filter[identifier]=\(encoded)&limit=1"
        )
        return items.first
    }

    // MARK: - JWT Generation

    /// Generates or returns a cached JWT for API authentication.
    private func getJWT() throws -> String {
        // Return cached JWT if still valid (with 60s margin).
        if let cached = cachedJWT, jwtExpiry.timeIntervalSinceNow > 60 {
            return cached
        }

        let now = Date()
        let expiry = now.addingTimeInterval(Self.jwtLifetime)

        // Header: {"alg":"ES256","kid":"<keyId>","typ":"JWT"}
        let headerDict: [String: String] = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
        let headerData = try JSONSerialization.data(withJSONObject: headerDict, options: .sortedKeys)
        let headerBase64 = headerData.base64URLEncoded()

        // Payload: {"iss":"<issuerId>","iat":<now>,"exp":<expiry>,"aud":"appstoreconnect-v1"}
        let payloadDict: [String: Any] = [
            "iss": issuerId,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(expiry.timeIntervalSince1970),
            "aud": Self.jwtAudience,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict, options: .sortedKeys)
        let payloadBase64 = payloadData.base64URLEncoded()

        // Sign with ES256.
        let signingInput = "\(headerBase64).\(payloadBase64)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))

        // Apple expects raw signature (r || s), not DER.
        let signatureBase64 = signature.rawRepresentation.base64URLEncoded()

        let jwt = "\(signingInput).\(signatureBase64)"

        cachedJWT = jwt
        jwtExpiry = expiry

        logger.debug("Generated new JWT for App Store Connect (expires \(expiry))")

        return jwt
    }

    // MARK: - HTTP Helpers

    private func get(path: String) async throws -> Data {
        let url = URL(string: "\(Self.baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try getJWT())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    private func post(path: String, body: Data) async throws -> Data {
        let url = URL(string: "\(Self.baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try getJWT())", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    private func delete(path: String) async throws {
        let url = URL(string: "\(Self.baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try getJWT())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        // DELETE returns 204 No Content on success.
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
            return
        }
        try validateResponse(response, data: data)
    }

    /// Fetches all pages of a paginated ASC response.
    private func getPaginated<T: Codable>(path: String) async throws -> [T] {
        var allItems: [T] = []
        var currentPath: String? = path

        while let fetchPath = currentPath {
            let data: Data
            if fetchPath.hasPrefix("http") {
                // Absolute URL from pagination link.
                let url = URL(string: fetchPath)!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(try getJWT())", forHTTPHeaderField: "Authorization")
                let (responseData, response) = try await session.data(for: request)
                try validateResponse(response, data: responseData)
                data = responseData
            } else {
                data = try await get(path: fetchPath)
            }

            let response = try makeDecoder().decode(ASCResponse<T>.self, from: data)
            allItems.append(contentsOf: response.data)
            currentPath = response.links?.next
        }

        return allItems
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASCClientError.invalidResponse
        }

        let statusCode = httpResponse.statusCode
        guard (200..<300).contains(statusCode) else {
            // Try to parse ASC error response.
            if let errorResponse = try? makeDecoder().decode(ASCErrorResponse.self, from: data) {
                throw ASCClientError.apiError(errors: errorResponse.errors)
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ASCClientError.httpError(statusCode: statusCode, body: bodyStr)
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Factory

extension AppStoreConnectClient {
    /// Creates an AppStoreConnectClient using the first available .p8 key from the Keychain.
    static func fromKeychain(logger: Logger) throws -> AppStoreConnectClient {
        let keychainManager = KeychainManager()
        let keys = try keychainManager.listAppleKeys()

        guard let keyInfo = keys.first else {
            throw ASCClientError.noKeyAvailable
        }

        let keyData = try keychainManager.loadP8Key(keyId: keyInfo.keyId)

        return try AppStoreConnectClient(
            keyId: keyInfo.keyId,
            issuerId: keyInfo.issuerId,
            privateKeyData: keyData,
            logger: logger
        )
    }

    /// Creates an AppStoreConnectClient for a specific key ID.
    static func fromKeychain(keyId: String, logger: Logger) throws -> AppStoreConnectClient {
        let keychainManager = KeychainManager()
        let keys = try keychainManager.listAppleKeys()

        guard let keyInfo = keys.first(where: { $0.keyId == keyId }) else {
            throw ASCClientError.noKeyAvailable
        }

        let keyData = try keychainManager.loadP8Key(keyId: keyId)

        return try AppStoreConnectClient(
            keyId: keyInfo.keyId,
            issuerId: keyInfo.issuerId,
            privateKeyData: keyData,
            logger: logger
        )
    }
}

// MARK: - Base64URL Encoding

extension Data {
    /// Encodes data to base64url (RFC 4648 Section 5) without padding.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
