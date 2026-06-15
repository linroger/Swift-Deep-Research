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
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // The on-disk store is incompatible with the current schema — i.e. a
            // @Model changed with no migration plan. Without this fallback, the
            // very next schema edit would crash the app on launch for every
            // existing install (an unrecoverable brick). Destroy the store and
            // recreate it empty: local research history is lost, but the app
            // launches. A VersionedSchema + SchemaMigrationPlan that PRESERVES
            // data is the follow-up once the schema stabilizes.
            Log.engine.error("SwiftData store incompatible (\(error.localizedDescription, privacy: .public)); rebuilding empty store.")
            Self.destroyStore(at: config.url)
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    /// Remove the SQLite store and its WAL/SHM sidecar files so a fresh,
    /// schema-current container can be created in their place.
    private static func destroyStore(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        for suffix in ["-shm", "-wal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
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
        // Scope source identity to the session. `StoredSource.id` is globally
        // `.unique`, so keying it on the URL alone meant re-researching an
        // overlapping URL in a different session OVERWROTE the other session's
        // stored source text — and deleting either session cascade-deleted a row
        // the other still referenced. A `sessionID|url` composite gives each
        // session its own row while still de-duping within a session.
        let target = "\(session.id.uuidString)|\(fetched.id)"
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
            id: target,
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
        insertCitations(citations, into: turn)
        try context.save()
    }

    /// Replace a turn's citations wholesale. Used on a re-draft: multi-round
    /// reflection emits a fresh `.draftReady` for the SAME turn, and
    /// `CitationExtractor` mints a new UUID per run so the `.unique` ids never
    /// collide with the prior round's rows. Calling `attachCitations` again would
    /// therefore APPEND a second full set, so a turn that went through N rounds
    /// accumulated N× its citations (duplicated in exports and the inspector).
    /// Deleting the existing cascade-related rows before inserting the new set —
    /// in one save — keeps exactly one set per turn.
    public func replaceCitations(_ citations: [Citation], on turn: StoredTurn) throws {
        for existing in turn.citations {
            context.delete(existing)
        }
        insertCitations(citations, into: turn)
        try context.save()
    }

    /// Insert citation rows for `turn` without saving, so callers can batch the
    /// insert with related deletes into a single `context.save()`.
    private func insertCitations(_ citations: [Citation], into turn: StoredTurn) {
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
