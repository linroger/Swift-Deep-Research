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
    /// Reference wrapper for an in-flight fetch. `Task` is a value type with no
    /// identity, so to tell "is the slot still MY task vs a sibling's fresher
    /// one?" we compare boxes by `===`.
    private final class InFlightBox: Sendable {
        let task: Task<FetchedSource, Error>
        init(_ task: Task<FetchedSource, Error>) { self.task = task }
    }

    private var cached: [String: FetchedSource] = [:]
    private var inFlight: [String: InFlightBox] = [:]
    /// Insertion order of `cached` keys, for FIFO eviction.
    private var order: [String] = []
    /// Cap on retained results. Each `FetchedSource` can hold tens of KB of
    /// extracted text (≤40k chars for PDFs), so an unbounded cache could grow to
    /// tens of MB across a long, source-heavy run. Evicting the oldest entry
    /// only costs an occasional re-fetch.
    private let maxEntries: Int

    public init(maxEntries: Int = 300) {
        self.maxEntries = max(16, maxEntries)
    }

    /// Fetch the URL or hand back a cached/in-flight version. The closure runs
    /// at most once per normalized URL per session.
    ///
    /// `wasCached` reports whether the result was served *without* running the
    /// extractor — true for both a completed-cache hit and an in-flight dedup
    /// (where another worker is already fetching the same URL). Callers use this
    /// to avoid double-charging the per-worker source budget and token budget on
    /// a URL that incurred no new network fetch, and to surface the dedup to the
    /// UI via `.sourceCacheHit`. Only a genuine miss returns `wasCached: false`.
    public func fetch(_ url: URL,
                      using extractor: @Sendable @escaping (URL) async throws -> FetchedSource) async throws -> (source: FetchedSource, wasCached: Bool) {
        let key = Self.normalize(url)
        if let cached = cached[key] { return (cached, true) }

        // Join an in-flight fetch for this URL when one exists, but isolate this
        // caller's outcome from the shared task's *failure* and from this
        // caller's *own* cancellation:
        //  • If the shared task throws (e.g. a transient network blip the first
        //    worker hit), a joining waiter does NOT inherit that failure — it
        //    falls through to its own fresh attempt below. Previously one
        //    transient error failed every concurrent requester of the URL.
        //  • If THIS caller is cancelled while awaiting, that's our problem
        //    alone; the shared task keeps running for its other waiters. The
        //    `Task {}` we create is unstructured, so it never inherits a
        //    caller's cancellation in the first place.
        if let box = inFlight[key] {
            do {
                return (try await box.task.value, true)
            } catch is CancellationError {
                // Our await was cancelled (not the shared work) — propagate so the
                // worker stops; don't fall through and start more work.
                throw CancellationError()
            } catch {
                // Shared task failed for the first awaiter. Re-check the caches:
                // the completed task may already have populated `cached`, or a
                // newer in-flight task may have replaced the failed one.
                if let cached = cached[key] { return (cached, true) }
                if let newer = inFlight[key], newer !== box {
                    return (try await newer.task.value, true)
                }
                // Otherwise fall through and make our own fresh attempt.
            }
        }

        let box = InFlightBox(Task { try await extractor(url) })
        inFlight[key] = box
        // Clear the slot only if it still points at *our* task, so we don't wipe
        // out a fresher in-flight task started by a sibling after ours failed.
        defer { if inFlight[key] === box { inFlight[key] = nil } }
        let result = try await box.task.value
        store(key: key, value: result)
        return (result, false)
    }

    /// Seed the result cache with sources already fetched in earlier turns of
    /// this session, in ONE actor hop instead of one `fetch()` await per source.
    ///
    /// Only the most-recent `maxEntries` sources are seeded: anything beyond the
    /// cap would be evicted by `store`'s FIFO trim before a later worker could
    /// hit it, so seeding it is pure overhead. We take the *tail* of `sources`
    /// (callers pass them oldest-first) so the entries most likely to be re-read
    /// survive. Already-cached keys are left untouched so a fresher in-run result
    /// isn't clobbered by a stale cross-turn copy.
    public func seed(_ sources: [FetchedSource]) {
        let recent = sources.suffix(maxEntries)
        for source in recent {
            let key = Self.normalize(source.url)
            guard cached[key] == nil else { continue }
            store(key: key, value: source)
        }
    }

    private func store(key: String, value: FetchedSource) {
        if cached[key] == nil { order.append(key) }
        cached[key] = value
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            cached[oldest] = nil
        }
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
