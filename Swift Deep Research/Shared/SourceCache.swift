import Foundation

/// Session-scoped shared cache so parallel workers don't re-fetch the same URL.
///
/// Two layers:
/// 1. **In-flight dedup** — when worker A starts fetching `https://x.com`,
///    worker B asking for the same URL awaits A's result instead of issuing
///    a second HTTP request.
/// 2. **Result cache** — once a URL is fetched, the resolved `FetchedSource`
///    is held for the lifetime of the session. The cache hands the same
///    instance back to anyone who asks.
///
/// Cache keys normalize the URL: trailing slash removed, fragment stripped,
/// common tracking query parameters dropped.
public actor SourceCache {
    private var cached: [String: FetchedSource] = [:]
    private var inFlight: [String: Task<FetchedSource, Error>] = [:]

    public init() {}

    /// Fetch the URL or hand back a cached/in-flight version. The closure runs
    /// at most once per normalized URL per session.
    public func fetch(_ url: URL,
                      using extractor: @Sendable @escaping (URL) async throws -> FetchedSource) async throws -> FetchedSource {
        let key = Self.normalize(url)
        if let cached = cached[key] { return cached }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await extractor(url) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        cached[key] = result
        return result
    }

    public func snapshot() -> [FetchedSource] { Array(cached.values) }

    public var size: Int { cached.count }

    public static func normalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        let trackingPrefixes: Set<String> = [
            "utm_", "gclid", "fbclid", "mc_eid", "_hsenc", "_hsmi", "ref_", "ref"
        ]
        components.queryItems = components.queryItems?.filter { item in
            let lower = item.name.lowercased()
            return !trackingPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0) })
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        // Lowercase ONLY scheme + host (case-insensitive by spec). Path and
        // query are case-sensitive on many servers — lowercasing them made
        // `/Page` and `/page` collide, so one worker could be handed another
        // worker's *different* page from the cache.
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var s = components.url?.absoluteString ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
