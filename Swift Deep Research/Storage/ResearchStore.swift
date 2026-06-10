import Foundation
import SwiftData

/// Persistence façade. Pure synchronous SwiftData; isolated to the main actor
/// because the app's `ModelContainer.mainContext` is main-actor bound on macOS 26.
@MainActor
public final class ResearchStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    public static func makeContainer() throws -> ModelContainer {
        let schema = Schema(ResearchSchema.models)
        let config = ModelConfiguration("DeepResearch.v2",
                                        schema: schema,
                                        isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Session lifecycle

    @discardableResult
    public func startSession(query: String, providerName: String) throws -> StoredSession {
        let title = String(query.prefix(80))
        let session = StoredSession(query: query, titleSummary: title, providerName: providerName)
        context.insert(session)
        try context.save()
        return session
    }

    public func markSession(_ session: StoredSession,
                            status: StoredSession.Status,
                            totalTokens: Int) throws {
        session.status = status.rawValue
        session.totalTokens = totalTokens
        session.updatedAt = .now
        try context.save()
    }

    public func deleteSession(_ session: StoredSession) throws {
        context.delete(session)
        try context.save()
    }

    public func allSessions() throws -> [StoredSession] {
        let descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Turns

    @discardableResult
    public func appendTurn(to session: StoredSession,
                           role: LLMMessage.Role,
                           markdown: String) throws -> StoredTurn {
        let turn = StoredTurn(role: role.rawValue, markdown: markdown, session: session)
        context.insert(turn)
        session.updatedAt = .now
        try context.save()
        return turn
    }

    public func updateTurnMarkdown(_ turn: StoredTurn, markdown: String) throws {
        turn.markdown = markdown
        try context.save()
    }

    // MARK: - Sources

    @discardableResult
    public func upsertSource(_ fetched: FetchedSource,
                             snippet: String?,
                             providerHint: String,
                             session: StoredSession) throws -> StoredSource {
        let target = fetched.id
        let descriptor = FetchDescriptor<StoredSource>(
            predicate: #Predicate<StoredSource> { $0.id == target }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.fullText = fetched.extractedText
            existing.fetchedAt = fetched.extractedAt
            if let snippet, existing.snippet.isEmpty { existing.snippet = snippet }
            try context.save()
            return existing
        }
        let source = StoredSource(
            id: fetched.id,
            urlString: fetched.url.absoluteString,
            title: fetched.title,
            snippet: snippet ?? "",
            fullText: fetched.extractedText,
            providerHint: providerHint,
            fetchedAt: fetched.extractedAt,
            session: session
        )
        context.insert(source)
        try context.save()
        return source
    }

    // MARK: - Citations

    public func attachCitations(_ citations: [Citation], to turn: StoredTurn) throws {
        for c in citations {
            let stored = StoredCitation(
                id: c.id,
                claim: c.claim,
                exactQuote: c.exactQuote,
                sourceURLString: c.sourceURL.absoluteString,
                sourceTitle: c.sourceTitle,
                turn: turn
            )
            context.insert(stored)
        }
        try context.save()
    }

    // MARK: - Forecasts (DeerFlow × MiroFish pipeline runs)

    @discardableResult
    public func createForecast(pipelineID: String,
                               prompt: String,
                               mode: String,
                               depth: String) throws -> ForecastRecord {
        let record = ForecastRecord(pipelineID: pipelineID, prompt: prompt, mode: mode, depth: depth)
        context.insert(record)
        try context.save()
        return record
    }

    /// Persist mutations the caller made directly on `@Model` objects.
    public func saveChanges() throws {
        try context.save()
    }

    public func deleteForecast(_ record: ForecastRecord) throws {
        context.delete(record)
        try context.save()
    }

    public func allForecasts() throws -> [ForecastRecord] {
        let descriptor = FetchDescriptor<ForecastRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// The local record for a MiroFish pipeline, if it was ever imported/started
    /// from this app. Used to dedupe the backend pipeline browser.
    public func findForecast(pipelineID: String) throws -> ForecastRecord? {
        var descriptor = FetchDescriptor<ForecastRecord>(
            predicate: #Predicate { $0.pipelineID == pipelineID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Events

    public func appendEvent(kind: String,
                            summary: String,
                            payloadJSON: String,
                            sequence: Int,
                            session: StoredSession) throws {
        let event = StoredEvent(
            id: UUID().uuidString,
            sequence: sequence,
            kind: kind,
            summary: summary,
            payloadJSON: payloadJSON,
            session: session
        )
        context.insert(event)
        try context.save()
    }
}
