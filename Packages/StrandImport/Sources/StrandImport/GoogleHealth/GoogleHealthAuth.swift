import Foundation
import CryptoKit
#if os(macOS)
import Network
import AppKit
#endif

/// Loopback OAuth 2.0 + PKCE sign-in for the Google Health API, reusing a Google
/// Cloud **Desktop** OAuth client (redirect `http://localhost:<port>`).
///
/// `authorize()` opens the system browser to Google's consent screen, catches the
/// redirect on a one-shot local listener, exchanges the code for tokens, and
/// returns them. The refresh token is what `GoogleHealthClient` needs; the app
/// stores it (e.g. in the Keychain) so sign-in is one-time.
public struct GoogleHealthAuth: Sendable {

    public struct Tokens: Sendable {
        public let accessToken: String
        public let refreshToken: String
    }

    public enum AuthError: Error, CustomStringConvertible {
        case unsupportedPlatform
        case listenerFailed(String)
        case noCode(String)
        case tokenExchange(Int, String)
        case noRefreshToken

        public var description: String {
            switch self {
            case .unsupportedPlatform: return "Loopback sign-in is macOS-only"
            case .listenerFailed(let m): return "Could not start local listener: \(m)"
            case .noCode(let m): return "Authorization was not completed: \(m)"
            case .tokenExchange(let c, let b): return "Token exchange failed (HTTP \(c)): \(b)"
            case .noRefreshToken: return "Google did not return a refresh token (consent may already be granted; revoke and retry)"
            }
        }
    }

    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.profile.readonly",
        "https://www.googleapis.com/auth/googlehealth.settings.readonly",
    ].joined(separator: " ")

    private let clientId: String
    private let clientSecret: String
    let port: UInt16
    private let session: URLSession

    public init(clientId: String, clientSecret: String, port: UInt16 = 8080,
                session: URLSession = .shared) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.port = port
        self.session = session
    }

    /// The Google consent URL for a given PKCE challenge. Exposed for testing.
    func consentURL(challenge: String) -> URL {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: "http://localhost:\(port)"),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return comps.url!
    }

    /// Run the full interactive flow and return tokens.
    public func authorize() async throws -> Tokens {
        #if os(macOS)
        let (verifier, challenge) = Self.pkce()
        let url = consentURL(challenge: challenge)
        let code = try await withLoopbackListener {
            NSWorkspace.shared.open(url)
        }
        return try await exchange(code: code, verifier: verifier)
        #else
        throw AuthError.unsupportedPlatform
        #endif
    }

    // MARK: - PKCE

    static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return (verifier, challenge)
    }

    // MARK: - Token exchange

    func exchange(code: String, verifier: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": clientId, "client_secret": clientSecret, "code": code,
            "code_verifier": verifier, "grant_type": "authorization_code",
            "redirect_uri": "http://localhost:\(port)",
        ]
        req.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchange(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let refresh = json["refresh_token"] as? String else { throw AuthError.noRefreshToken }
        return Tokens(accessToken: json["access_token"] as? String ?? "", refreshToken: refresh)
    }
}

extension Data {
    /// Base64URL without padding (RFC 7636 PKCE).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
