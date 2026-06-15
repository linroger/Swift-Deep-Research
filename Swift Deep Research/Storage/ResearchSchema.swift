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
    public var fullText: String
    public var providerHint: String      // "tavily" | "exa" | "brave" | "ddg" | "reddit" | ...
    public var fetchedAt: Date
    public var session: StoredSession?

    public init(id: String,
                urlString: String,
                title: String,
                snippet: String,
                fullText: String,
                providerHint: String,
                fetchedAt: Date = .now,
                session: StoredSession? = nil) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.snippet = snippet
        self.fullText = fullText
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
    public var occurredAt: Date
    public var session: StoredSession?

    public init(id: String,
                sequence: Int,
                kind: String,
                summary: String,
                payloadJSON: String,
                occurredAt: Date = .now,
                session: StoredSession? = nil) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.summary = summary
        self.payloadJSON = payloadJSON
        self.occurredAt = occurredAt
        self.session = session
    }
}
