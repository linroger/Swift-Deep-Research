import Foundation

/// SSRF guard for URLs that originate from untrusted content — search results,
/// pages the agent decides to read, and LLM tool arguments. A deep-research agent
/// fetches whatever the model (steered by web content it just read) asks it to,
/// so indirect prompt injection can otherwise make it hit `http://localhost`,
/// `file:///etc/...`, the cloud metadata endpoint (`169.254.169.254`), or the
/// app's own unauthenticated local backends. Every fetch tool runs its target
/// through `blockReason(for:)` before issuing the request.
///
/// This blocks the literal cases (loopback/private/link-local IPs and
/// localhost-style hostnames) plus non-http(s) schemes. It does NOT yet resolve
/// DNS names to defend against rebinding (a name that resolves to a private IP);
/// that requires resolving before connecting and pinning the address, tracked as
/// a follow-up. The literal guard already closes the common, directly-reachable
/// vectors.
enum URLSafety {
    /// Returns `nil` when `url` is safe to fetch, otherwise a short reason it was
    /// rejected (suitable for surfacing to the agent as a tool failure).
    static func blockReason(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return "missing URL scheme" }
        guard scheme == "http" || scheme == "https" else {
            return "scheme '\(scheme)' is not allowed (only http/https)"
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return "missing host" }
        // Strip brackets from IPv6 literals.
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }

        // Loopback / internal hostnames.
        if host == "localhost" || host.hasSuffix(".localhost") || host == "ip6-localhost" {
            return "loopback host '\(host)'"
        }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return "internal host '\(host)'"
        }

        if let octets = parseIPv4(host) {
            if isPrivateIPv4(octets) { return "private/loopback IPv4 \(host)" }
            return nil
        }
        if host.contains(":"), isBlockedIPv6(host) {
            return "private/loopback IPv6 \(host)"
        }
        return nil
    }

    static func isFetchable(_ url: URL) -> Bool { blockReason(for: url) == nil }

    // MARK: - IPv4

    private static func parseIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            guard let v = Int(p), (0...255).contains(v), String(v) == p else { return nil }
            octets.append(v)
        }
        return octets
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _): return true                       // 0.0.0.0/8 "this network"
        case (10, _): return true                      // 10.0.0.0/8 private
        case (127, _): return true                     // 127.0.0.0/8 loopback
        case (169, 254): return true                   // 169.254.0.0/16 link-local (incl. metadata)
        case (172, 16...31): return true               // 172.16.0.0/12 private
        case (192, 168): return true                   // 192.168.0.0/16 private
        case (100, 64...127): return true              // 100.64.0.0/10 CGNAT
        default: return o[0] >= 224                    // 224+ multicast/reserved
        }
    }

    // MARK: - IPv6

    private static func isBlockedIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "::" { return true }          // loopback / unspecified
        if host.hasPrefix("fe80") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") {
            return true                                            // fe80::/10 link-local
        }
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }  // fc00::/7 unique-local
        if host.hasPrefix("ff") { return true }                   // ff00::/8 multicast
        if host.hasPrefix("::ffff:") {                            // IPv4-mapped
            if let v4 = parseIPv4(String(host.dropFirst(7))) { return isPrivateIPv4(v4) }
        }
        return false
    }
}
