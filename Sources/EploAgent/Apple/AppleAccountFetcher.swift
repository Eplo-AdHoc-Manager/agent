import Foundation

/// A minimal view of an Apple account synced from the control plane.
struct AppleAccountRemote: Decodable, Sendable {
    let id: String
    let teamId: String
    let teamName: String
    let keyId: String
    let issuerId: String
    let status: String
}

/// Fetches Apple accounts from the control plane using the agent's pairing token.
enum AppleAccountFetcher {
    static func fetch(config: AgentConfig) async throws -> [AppleAccountRemote] {
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/agent/apple-accounts") else {
            throw FetcherError.invalidURL(config.serverURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("eplo-agent/\(AgentVersion.current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetcherError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetcherError.httpError(status: http.statusCode, body: body)
        }

        return try JSONDecoder().decode([AppleAccountRemote].self, from: data)
    }

    enum FetcherError: Error, CustomStringConvertible {
        case invalidURL(String)
        case invalidResponse
        case httpError(status: Int, body: String)

        var description: String {
            switch self {
            case .invalidURL(let s): return "Invalid server URL: \(s)"
            case .invalidResponse: return "Unexpected response from control plane"
            case .httpError(let status, let body):
                return "Control plane returned \(status): \(body.prefix(200))"
            }
        }
    }
}
