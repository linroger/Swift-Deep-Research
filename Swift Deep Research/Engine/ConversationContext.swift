import Foundation

/// Carries state across follow-up turns within the same research session.
///
/// A session can have multiple turns: the user asks the original question,
/// gets a draft, asks "can you go deeper on point 3?", and the engine reuses
/// the accumulated sources + prior draft as context instead of starting from
/// scratch. The orchestrator passes this into planner/workers/synthesizer.
public struct ConversationContext: Sendable, Codable {
    public var priorTurns: [Turn]
    public var accumulatedSources: [FetchedSource]
    public var accumulatedCitations: [Citation]

    public init(priorTurns: [Turn] = [],
                accumulatedSources: [FetchedSource] = [],
                accumulatedCitations: [Citation] = []) {
        self.priorTurns = priorTurns
        self.accumulatedSources = accumulatedSources
        self.accumulatedCitations = accumulatedCitations
    }

    public struct Turn: Sendable, Codable, Identifiable {
        public let id: UUID
        public let role: Role
        public let content: String
        public let createdAt: Date

        public init(id: UUID = UUID(),
                    role: Role,
                    content: String,
                    createdAt: Date = .now) {
            self.id = id; self.role = role
            self.content = content; self.createdAt = createdAt
        }

        public enum Role: String, Sendable, Codable { case user, assistant }
    }

    public var isFirstTurn: Bool { priorTurns.isEmpty }

    public mutating func appendUserTurn(_ text: String) {
        priorTurns.append(Turn(role: .user, content: text))
    }
    public mutating func appendAssistantTurn(_ text: String) {
        priorTurns.append(Turn(role: .assistant, content: text))
    }

    /// Compact summary the planner sees so the new sub-tasks build on prior work
    /// instead of duplicating it.
    public func plannerPreamble() -> String {
        guard !isFirstTurn else { return "" }
        let history = priorTurns.suffix(6).map { turn in
            let label = turn.role == .user ? "User asked" : "Assistant answered"
            return "- \(label): \(Clip.clip(turn.content, to: 240))"
        }.joined(separator: "\n")
        let knownDomains = Set(accumulatedSources.compactMap { $0.url.host }).sorted().prefix(8)
        let domainsLine = knownDomains.isEmpty ? "" :
            "Already researched domains: \(knownDomains.joined(separator: ", "))"
        return """

        # Prior conversation context
        \(history)
        \(domainsLine)
        Build on what's already known. Don't re-research what we already have unless
        the new question explicitly requires fresh info.
        """
    }

    /// What the worker sees: lets it skip pages already cached.
    public var seenURLs: Set<URL> {
        Set(accumulatedSources.map(\.url))
    }

    /// Compact "already-seen sources" note for the worker context on follow-up
    /// turns. Listing the exact URLs already fetched in prior turns lets a worker
    /// prefer *new* sources rather than re-issuing the same fetches — and any URL
    /// it does fetch again is served from the pre-seeded `SourceCache` at no
    /// network cost (engine-cache-not-used-for-cross-turn). Empty on the first
    /// turn (no prior sources) so it never bloats the round-1 worker prompt.
    public func seenSourcesNote(limit: Int = 30) -> String {
        guard !accumulatedSources.isEmpty else { return "" }
        // De-dupe while preserving order; prefer breadth across distinct URLs.
        var seen = Set<String>()
        var lines: [String] = []
        for source in accumulatedSources {
            let url = source.url.absoluteString
            if !seen.insert(url).inserted { continue }
            let title = source.title.isEmpty ? url : Clip.clip(source.title, to: 100)
            lines.append("- \(title) — \(url)")
            if lines.count >= limit { break }
        }
        guard !lines.isEmpty else { return "" }
        return """
        These sources were already fetched in earlier turns of this session and \
        are cached (re-reading them is free, but prefer finding NEW sources unless \
        a known one is essential):
        \(lines.joined(separator: "\n"))
        """
    }
}
