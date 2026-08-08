import Foundation

enum Config {
    /// Point the client at a local `npm run dev` instead of production.
    static let useLocalServer = false

    static let productionHost = "joels-world.com"
    /// `npm run dev` in `server/` binds port 80 unless `PORT` is set.
    static let localHost = "localhost"

    /// Set at runtime by the macOS admin editor, which chooses its server from the UI rather
    /// than from a compile-time flag. `host` may carry a `:port` suffix.
    static var hostOverride: String?

    static var host: String { hostOverride ?? (useLocalServer ? localHost : productionHost) }

    /// Loopback servers are plain HTTP; anything else is assumed to be TLS-terminated.
    private static var isLoopback: Bool {
        host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]")
    }

    /// `-noshadows` / `-nossao` switch the Phase 3 passes off, so a screenshot can isolate
    /// which stage a parity difference comes from.
    static var shadowsEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-noshadows")
    }

    static var ssaoEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-nossao")
    }
    static var httpScheme: String { isLoopback ? "http" : "https" }
    static var wsScheme: String { isLoopback ? "ws" : "wss" }

    /// Base URL for streamed assets (map chunk tiles, clip masks).
    static var assetBaseURL: URL {
        URL(string: "\(httpScheme)://\(host)")!
    }

    /// Presented on the socket handshake by the macOS admin editor, which has no browser
    /// session to carry the server's `isAdmin` flag. See `grantsAdmin` in `server/websocket.js`:
    /// the key must match `ADMIN_KEY`, or — when the server has none set — come from loopback.
    static var adminKey: String?

    static func websocketURL(state: String, token: String?) -> URL {
        var components = URLComponents()
        components.scheme = wsScheme
        if let colon = host.firstIndex(of: ":") {
            components.host = String(host[host.startIndex..<colon])
            components.port = Int(host[host.index(after: colon)...])
        } else {
            components.host = host
        }
        var items = [URLQueryItem(name: "state", value: state)]
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        if let adminKey, !adminKey.isEmpty {
            items.append(URLQueryItem(name: "adminKey", value: adminKey))
        }
        components.queryItems = items
        return components.url!
    }
}
