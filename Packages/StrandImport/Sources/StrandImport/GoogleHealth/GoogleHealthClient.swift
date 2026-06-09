import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin async client for the Google Health API. Refreshes an access token from a
/// stored refresh token and lists `dataPoints` for a data type. Networking only —
/// the app supplies credentials (e.g. from an in-app OAuth flow); mapping to the
/// normalized models lives in `GoogleHealthMapper`.
public struct GoogleHealthClient: Sendable {

    public enum ClientError: Error, CustomStringConvertible {
        case http(Int, String)
        case badResponse

        public var description: String {
            switch self {
            case .http(let code, let body): return "Google Health API HTTP \(code): \(body)"
            case .badResponse: return "Unexpected Google Health API response shape"
            }
        }
    }

    private let clientId: String
    private let clientSecret: String
    private let refreshToken: String
    private let session: URLSession

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let base = "https://health.googleapis.com/v4/users/me/dataTypes"

    public init(clientId: String, clientSecret: String, refreshToken: String,
                session: URLSession = .shared) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.session = session
    }

    /// Exchange the refresh token for a short-lived access token.
    public func accessToken() async throws -> String {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": clientId, "client_secret": clientSecret,
            "grant_type": "refresh_token", "refresh_token": refreshToken,
        ]
        req.httpBody = form.map { "\($0.key)=\(Self.escape($0.value))" }.joined(separator: "&").data(using: .utf8)
        let json = try await send(req)
        guard let token = json["access_token"] as? String else { throw ClientError.badResponse }
        return token
    }

    /// List `dataPoints` for one local day of a data type, mirroring the proven
    /// filter logic: try server-side filters, fall back to an unfiltered page.
    public func dataPoints(type: String, day: Date, token: String) async throws -> [[String: Any]] {
        for filter in Self.filters(type: type, day: day) {
            let url = "\(Self.base)/\(type)/dataPoints?pageSize=100000&filter=\(Self.escape(filter))"
            if let points = try? await get(url, token: token) { return points }
        }
        return try await get("\(Self.base)/\(type)/dataPoints?pageSize=100000", token: token)
    }

    // MARK: - HTTP

    private func get(_ url: String, token: String) async throws -> [[String: Any]] {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await send(req)
        return json["dataPoints"] as? [[String: Any]] ?? []
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }
        return json
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
