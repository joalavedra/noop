#if os(macOS)
import Foundation
import Network

/// One-shot guard so a checked continuation resumes exactly once across the
/// listener's connection and state callbacks.
final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension GoogleHealthAuth {

    /// Start a one-shot loopback listener on `port`, invoke `onReady` once it is
    /// listening (the caller opens the browser there), and resume with the
    /// `code` from the OAuth redirect.
    func withLoopbackListener(onReady: @escaping @Sendable () -> Void) async throws -> String {
        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw AuthError.listenerFailed("port \(port) unavailable — \(error.localizedDescription)")
        }

        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let code = Self.extractCode(request)
                    let body = code != nil
                        ? "<h2>NOOP is connected to Google Health.</h2><p>You can close this tab.</p>"
                        : "<h2>Authorization did not complete.</h2><p>You can close this tab and retry.</p>"
                    let http = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                    guard once.claim() else { return }
                    listener.cancel()
                    if let code {
                        cont.resume(returning: code)
                    } else {
                        cont.resume(throwing: AuthError.noCode("redirect carried no authorization code"))
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    onReady()
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: AuthError.listenerFailed(err.localizedDescription)) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Pull `code` out of the first request line: `GET /?code=…&… HTTP/1.1`.
    static func extractCode(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }
}
#endif
