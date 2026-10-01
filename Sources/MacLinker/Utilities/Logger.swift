import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: K.bundleID, category: "maclinker")

    static func info(_ message: @autoclosure () -> String) {
        let m = message()
        logger.info("\(m, privacy: .public)")
        fputs("[MacLinker] \(m)\n", stderr)
    }

    static func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        fputs("[MacLinker][error] \(m)\n", stderr)
    }
}
