import os

enum Log {
    private static let netLogger = Logger(subsystem: "com.allr.joelsworld", category: "net")
    private static let renderLogger = Logger(subsystem: "com.allr.joelsworld", category: "render")
    private static let worldLogger = Logger(subsystem: "com.allr.joelsworld", category: "world")

    static func net(_ message: String) {
        netLogger.info("\(message, privacy: .public)")
        #if DEBUG
        print("[Net] \(message)")
        #endif
    }

    static func render(_ message: String) {
        renderLogger.info("\(message, privacy: .public)")
        #if DEBUG
        print("[Render] \(message)")
        #endif
    }

    static func world(_ message: String) {
        worldLogger.info("\(message, privacy: .public)")
        #if DEBUG
        print("[World] \(message)")
        #endif
    }
}
