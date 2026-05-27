import Foundation
import OSLog

/// Module-level logger handles. Use the subsystem reverse-DNS for filtering in Console.app.
public enum Log {
    public static let subsystem = "com.aryamirsepasi.Swift-Deep-Research"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let tool = Logger(subsystem: subsystem, category: "tool")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let net = Logger(subsystem: subsystem, category: "net")
}

/// Small helpers we use everywhere.
public enum Clip {
    /// Truncate to ~n chars, marking the cut so callers don't think the source ended.
    public static func clip(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        let prefix = s.prefix(n)
        return "\(prefix)…[clipped \(s.count - n) chars]"
    }
}

public enum HTTPClientCommon {
    public static let defaultUserAgent =
        "SwiftDeepResearch/2.0 (macOS) URLSession"

    public static func defaultSession(timeout: TimeInterval = 30) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpAdditionalHeaders = ["User-Agent": defaultUserAgent]
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }
}
