import Foundation

// MARK: - JSON:API Response Wrappers

/// Generic App Store Connect API response wrapping a `data` array.
struct ASCResponse<T: Codable>: Codable {
    let data: [T]
    let links: ASCPageLinks?
}

/// Generic App Store Connect API response wrapping a single `data` object.
struct ASCSingleResponse<T: Codable>: Codable {
    let data: T
}

/// Pagination links in ASC responses.
struct ASCPageLinks: Codable {
    let next: String?
    let `self`: String?
}

// MARK: - ASCDevice

struct ASCDevice: Codable, Sendable {
    let type: String
    let id: String
    let attributes: Attributes

    struct Attributes: Codable, Sendable {
        let name: String?
        let udid: String?
        let platform: String?
        let status: String?
        let deviceClass: String?
        let model: String?
    }
}

// MARK: - ASCProfile

struct ASCProfile: Codable, Sendable {
    let type: String
    let id: String
    let attributes: Attributes

    struct Attributes: Codable, Sendable {
        let name: String?
        let profileType: String?
        let profileState: String?
        let profileContent: String? // base64-encoded .mobileprovision
        let expirationDate: String?
        let uuid: String?
    }
}

// MARK: - ASCCertificate

struct ASCCertificate: Codable, Sendable {
    let type: String
    let id: String
    let attributes: Attributes

    struct Attributes: Codable, Sendable {
        let name: String?
        let certificateType: String?
        let expirationDate: String?
        let serialNumber: String?
    }
}

// MARK: - ASCBundleId

struct ASCBundleId: Codable, Sendable {
    let type: String
    let id: String
    let attributes: Attributes

    struct Attributes: Codable, Sendable {
        let identifier: String?
        let name: String?
        let platform: String?
    }
}

// MARK: - ASC Error Response

struct ASCErrorResponse: Codable, Sendable {
    let errors: [ASCErrorDetail]
}

struct ASCErrorDetail: Codable, Sendable {
    let status: String?
    let code: String?
    let title: String?
    let detail: String?
}

// MARK: - ASC Request Bodies (JSON:API format)

/// Request body for creating/registering a device.
struct ASCDeviceCreateRequest: Encodable {
    let data: DataBody

    struct DataBody: Encodable {
        let type: String = "devices"
        let attributes: Attributes
    }

    struct Attributes: Encodable {
        let name: String
        let udid: String
        let platform: String
    }

    init(name: String, udid: String, platform: String) {
        self.data = DataBody(attributes: Attributes(name: name, udid: udid, platform: platform))
    }
}

/// Request body for creating a provisioning profile.
struct ASCProfileCreateRequest: Encodable {
    let data: DataBody

    struct DataBody: Encodable {
        let type: String = "profiles"
        let attributes: Attributes
        let relationships: Relationships
    }

    struct Attributes: Encodable {
        let name: String
        let profileType: String
    }

    struct Relationships: Encodable {
        let bundleId: RelationshipData
        let certificates: RelationshipDataArray
        let devices: RelationshipDataArray
    }

    struct RelationshipData: Encodable {
        let data: ResourceIdentifier
    }

    struct RelationshipDataArray: Encodable {
        let data: [ResourceIdentifier]
    }

    struct ResourceIdentifier: Encodable {
        let id: String
        let type: String
    }

    init(name: String, profileType: String, bundleIdResourceId: String, certificateIds: [String], deviceIds: [String]) {
        self.data = DataBody(
            attributes: Attributes(name: name, profileType: profileType),
            relationships: Relationships(
                bundleId: RelationshipData(data: ResourceIdentifier(id: bundleIdResourceId, type: "bundleIds")),
                certificates: RelationshipDataArray(data: certificateIds.map {
                    ResourceIdentifier(id: $0, type: "certificates")
                }),
                devices: RelationshipDataArray(data: deviceIds.map {
                    ResourceIdentifier(id: $0, type: "devices")
                })
            )
        )
    }
}

// MARK: - App Store Connect Client Errors

enum ASCClientError: Error, CustomStringConvertible {
    case jwtGenerationFailed(String)
    case httpError(statusCode: Int, body: String)
    case apiError(errors: [ASCErrorDetail])
    case noKeyAvailable
    case invalidResponse
    case deviceAlreadyRegistered(ASCDevice)

    var description: String {
        switch self {
        case .jwtGenerationFailed(let reason):
            return "JWT generation failed: \(reason)"
        case .httpError(let statusCode, let body):
            return "HTTP error \(statusCode): \(body)"
        case .apiError(let errors):
            let details = errors.map { $0.detail ?? $0.title ?? "unknown" }.joined(separator: ", ")
            return "App Store Connect API error: \(details)"
        case .noKeyAvailable:
            return "No Apple API key (.p8) available in Keychain"
        case .invalidResponse:
            return "Invalid response from App Store Connect API"
        case .deviceAlreadyRegistered(let device):
            return "Device already registered with ID \(device.id)"
        }
    }
}
