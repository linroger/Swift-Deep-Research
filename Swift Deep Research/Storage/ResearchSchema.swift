import Foundation
import SwiftData

// MARK: - Schema

/// All SwiftData models in one place so the ModelContainer schema list stays terse.
public enum ResearchSchema {
    public static let models: [any PersistentModel.Type] = [
        StoredSession.self,
        StoredTurn.self,
        StoredSource.self,
        StoredCitation.self,
        StoredEvent.self,
        ForecastRecord.self
    ]
}

// MARK: - Models

@Model
public final class StoredSession {
    @Attribute(.unique) public var id: UUID
    public var query: String
    public var titleSummary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var providerName: String
    public var status: String
    public var totalTokens: Int

    @Relationship(deleteRule: .cascade, inverse: \StoredTurn.session)
    public var turns: [StoredTurn] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredSource.session)
    public var sources: [StoredSource] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredEvent.session)
    public var events: [StoredEvent] = []

    public init(id: UUID = UUID(),
                query: String,
                titleSummary: String,
                providerName: String,
                createdAt: Date = .now,
                status: Status = .running,
                totalTokens: Int = 0) {
        self.id = id
        self.query = query
        self.titleSummary = titleSummary
        self.providerName = providerName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = status.rawValue
        self.totalTokens = totalTokens
    }

    public enum Status: String, Sendable, Codable, CaseIterable {
        case running, completed, failed, cancelled
    }
}

@Model
public final class StoredTurn {
    @Attribute(.unique) public var id: UUID
    public var role: String              // "user" | "assistant" | "system" | "tool"
    public var markdown: String
    public var createdAt: Date
    public var session: StoredSession?

    @Relationship(deleteRule: .cascade, inverse: \StoredCitation.turn)
    public var citations: [StoredCitation] = []

    public init(id: UUID = UUID(),
                role: String,
                markdown: String,
                createdAt: Date = .now,
                session: StoredSession? = nil) {
        self.id = id
        self.role = role
        self.markdown = markdown
        self.createdAt = createdAt
        self.session = session
    }
}

@Model
public final class StoredSource {
    @Attribute(.unique) public var id: String
    public var urlString: String
    public var title: String
    public var snippet: String
    // The extracted full text is intentionally NOT persisted: it was write-only
    // (nothing ever read it back — the live engine keeps source text in
    // `FetchedSource`, and the inspector shows only title/url/snippet), so storing
    // it just bloated the SQLite store with the largest field per source. This is a
    // @Model schema change; it relies on the destroy-and-rebuild fallback in
    // `ResearchStore.makeContainer()`.
    public var providerHint: String      // "tavily" | "exa" | "brave" | "ddg" | "reddit" | ...
    public var fetchedAt: Date
    public var session: StoredSession?

    public init(id: String,
                urlString: String,
                title: String,
                snippet: String,
                providerHint: String,
                fetchedAt: Date = .now,
                session: StoredSession? = nil) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.snippet = snippet
        self.providerHint = providerHint
        self.fetchedAt = fetchedAt
        self.session = session
    }

    public var url: URL? { URL(string: urlString) }
}

@Model
public final class StoredCitation {
    @Attribute(.unique) public var id: String
    public var claim: String
    public var exactQuote: String
    public var sourceURLString: String
    public var sourceTitle: String
    public var turn: StoredTurn?

    public init(id: String,
                claim: String,
                exactQuote: String,
                sourceURLString: String,
                sourceTitle: String,
                turn: StoredTurn? = nil) {
        self.id = id
        self.claim = claim
        self.exactQuote = exactQuote
        self.sourceURLString = sourceURLString
        self.sourceTitle = sourceTitle
        self.turn = turn
    }
}

@Model
public final class StoredEvent {
    @Attribute(.unique) public var id: String
    public var sequence: Int
    public var kind: String              // ResearchEvent case name
    public var summary: String
    public var payloadJSON: String
    /// Loss-less Codable snapshot of the full `ResearchEvent` (see
    /// `ResearchEventSnapshot`), JSON-encoded. `payloadJSON` historically carried
    /// a structured payload for only a handful of kinds and just `{kind,timestamp}`
    /// for the rest, so the persisted log could not reconstruct a run. This field
    /// captures EVERY kind's associated values so the timeline is fully replayable,
    /// and is the SOLE store of the snapshot for new rows — `payloadJSON` is left
    /// empty by `appendEvent(event:…)` rather than redundantly carrying the same
    /// JSON.
    ///
    /// Optional with a `nil` default so SwiftData performs a lightweight,
    /// data-preserving migration: rows written before this field existed simply
    /// decode it as `nil`, and `decodedSnapshot` returns `nil` for them — old
    /// history is never lost and never crashes on read.
    public var eventPayloadJSON: String? = nil
    public var occurredAt: Date
    public var session: StoredSession?

    public init(id: String,
                sequence: Int,
                kind: String,
                summary: String,
                payloadJSON: String,
                eventPayloadJSON: String? = nil,
                occurredAt: Date = .now,
                session: StoredSession? = nil) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.summary = summary
        self.payloadJSON = payloadJSON
        self.eventPayloadJSON = eventPayloadJSON
        self.occurredAt = occurredAt
        self.session = session
    }

    /// The loss-less event snapshot for this row, if one was persisted. Falls back
    /// to nothing for legacy rows (whose only payload was the lossy `payloadJSON`),
    /// so callers can branch on `nil` rather than crashing. Decoding failures are
    /// swallowed and surface as `nil` — a corrupt payload must never break the
    /// timeline read path.
    public var decodedSnapshot: ResearchEventSnapshot? {
        guard let eventPayloadJSON,
              let data = eventPayloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResearchEventSnapshot.self, from: data)
    }
}
