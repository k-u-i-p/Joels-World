import Foundation

enum Config {
    /// Point the client at a local `npm run dev` instead of production.
    static let useLocalServer = false

    static let productionHost = "joels-world.com"
    /// `npm run dev` in `server/` binds port 80 unless `PORT` is set.
    static let localHost = "localhost"

    /// Set at runtime by the macOS admin editor, which chooses its server from the UI rather
    /// than from a compile-time flag. `host` may carry a `:port` suffix.
    ///
    /// Seeded from `-host <host[:port]>`, so a scripted run — `-walktest` against a server
    /// started for the occasion — can pick one without editing `useLocalServer` and rebuilding.
    static var hostOverride: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-host"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }()

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

    /// `-nocull` draws every prop regardless of the frustum, the way `PropRenderer` did before
    /// the culling went in, and `-propstats` prints once a second how many each pass drew and
    /// skipped. Used together they are the only test that proves a culling change kept the
    /// picture: the numbers alone say how much was skipped, not whether any of it should have
    /// been drawn, and a screenshot alone cannot tell scenery that was culled wrongly from
    /// scenery that was never there.
    static var propCullingEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-nocull")
    }

    static var propStatsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-propstats")
    }

    static var wsScheme: String { isLoopback ? "ws" : "wss" }

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
        components.queryItems = items
        return components.url!
    }
}
