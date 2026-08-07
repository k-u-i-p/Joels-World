import Foundation

enum Config {
    /// Point the client at a local `npm run dev` instead of production.
    static let useLocalServer = false

    static let productionHost = "joels-world.com"
    /// `npm run dev` in `server/` binds port 80 unless `PORT` is set.
    static let localHost = "localhost"

    static var host: String { useLocalServer ? localHost : productionHost }

    /// `-noshadows` / `-nossao` switch the Phase 3 passes off, so a screenshot can isolate
    /// which stage a parity difference comes from.
    static var shadowsEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-noshadows")
    }

    static var ssaoEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-nossao")
    }
    static var httpScheme: String { useLocalServer ? "http" : "https" }
    static var wsScheme: String { useLocalServer ? "ws" : "wss" }

    /// Base URL for streamed assets (map chunk tiles, clip masks).
    static var assetBaseURL: URL {
        URL(string: "\(httpScheme)://\(host)")!
    }

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
