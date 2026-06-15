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

    /// Flush any pending coalesced save before the store is deallocated so the
    /// final draft / events written during the last debounce window are never
    /// lost on teardown. `isolated deinit` (Swift 6.2) runs on the MainActor
    /// executor, so it may safely touch the MainActor-bound context and cancel
    /// the pending-save task.
    isolated deinit {
        saveTask?.cancel()
        saveTask = nil
        flushIfDirty()
    }

    // MARK: - Save coalescing
    //
    // Streaming a run drives a high-frequency write stream — every persisted
    // `ResearchEvent` (appendEvent), each `sourceFetched` (upsertSource), plus
    // per-draft turn/citation writes. Calling `context.save()` on every one of
    // those ran a synchronous, SQLite-backed transaction on the MainActor while
    // the UI was also updating, the dominant cause of jank on long runs. Instead
    // of saving per mutation, the chatty mutators mark the context dirty and a
    // single coalescing task performs at most one save per `saveDebounce`.
    // Durability-critical boundaries (session create/finish, deletes, explicit
    // `saveChanges`) still flush synchronously so nothing is lost on completion.

    /// Maximum delay before a coalesced save reaches disk. Short enough that a
    /// crash loses at most this window of streaming events, long enough to absorb
    /// a burst of token/tool writes into one transaction.
    private static let saveDebounce: Duration = .milliseconds(400)

    /// True when uncommitted inserts/changes are waiting for the next flush.
    private var isDirty = false

    /// The in-flight coalescing task, if a flush is already scheduled. Held so it
    /// can be cancelled (and superseded) and so the `deinit` can guarantee a final
    /// flush. Not `@Observable`, so no `@ObservationIgnored` is required.
    private var saveTask: Task<Void, Never>?

    /// Monotonic token identifying the currently-scheduled debounce. A task only
    /// clears `saveTask` / flushes if its captured token still matches — so a
    /// superseded or cancelled task that wakes up late can never null out a newer
    /// task's handle. (`Task` is a value type and can't be compared by identity,
    /// hence the token.)
    private var saveGeneration = 0

    /// Record a mutation that should reach disk soon and ensure a single coalesced
    /// flush is scheduled. Cheap and non-blocking: the actual `context.save()`
    /// happens once per debounce window on the MainActor.
    private func scheduleSave() {
        isDirty = true
        guard saveTask == nil else { return }
        saveGeneration += 1
        let generation = saveGeneration
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard let self, !Task.isCancelled,
                  self.saveGeneration == generation else { return }
            self.saveTask = nil
            self.flushIfDirty()
        }
    }

    /// Persist pending changes immediately and cancel any scheduled debounce, used
    /// at durability-critical boundaries. Safe to call when nothing is dirty.
    /// Bumping the generation invalidates any in-flight debounce so it can't fire
    /// a duplicate save after this synchronous flush.
    private func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration += 1
        flushIfDirty()
    }

    /// Save the context iff there are pending changes, clearing the dirty flag.
    /// A failed save keeps the flag set so the next boundary retries rather than
    /// silently dropping the batch.
    private func flushIfDirty() {
        guard isDirty else { return }
        do {
            try context.save()
            isDirty = false
        } catch {
            Log.engine.error("Coalesced SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
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
        // Durability boundary: the returned session anchors the whole run; persist
        // it (and any coalesced writes ahead of it) synchronously.
        isDirty = true
        flushNow()
        return session
    }

    public func markSession(_ session: StoredSession,
                            status: StoredSession.Status,
                            totalTokens: Int) throws {
        session.status = status.rawValue
        session.totalTokens = totalTokens
        session.updatedAt = .now
        // Run-finish durability boundary: flush synchronously so the terminal
        // status AND every coalesced event/draft written during the run are on
        // disk before completion is recorded.
        isDirty = true
        flushNow()
    }

    public func deleteSession(_ session: StoredSession) throws {
        context.delete(session)
        isDirty = true
        flushNow()
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
        // The returned turn is valid in-context immediately; coalesce the save.
        // The draft it carries is made durable at the next run-finish flush
        // (markSession) and by the debounce in between.
        scheduleSave()
        return turn
    }

    public func updateTurnMarkdown(_ turn: StoredTurn, markdown: String) throws {
        turn.markdown = markdown
        scheduleSave()
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
            scheduleSave()
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
        scheduleSave()
        return source
    }

    // MARK: - Citations

    public func attachCitations(_ citations: [Citation], to turn: StoredTurn) throws {
        insertCitations(citations, into: turn)
        scheduleSave()
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
        scheduleSave()
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
        // Durability boundary: the returned record is the local handle for a
        // backend pipeline; persist it synchronously.
        isDirty = true
        flushNow()
        return record
    }

    /// Persist mutations the caller made directly on `@Model` objects. This is the
    /// explicit synchronous-flush contract callers rely on, so it also drains any
    /// pending coalesced save.
    public func saveChanges() throws {
        isDirty = true
        flushNow()
    }

    public func deleteForecast(_ record: ForecastRecord) throws {
        context.delete(record)
        isDirty = true
        flushNow()
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
        // High-frequency during streaming — coalesce. The run-finish flush in
        // markSession guarantees the full event log is durable on completion.
        scheduleSave()
    }

    /// Loss-less event persistence: stores a full `ResearchEventSnapshot` for the
    /// event so the timeline can be reconstructed for ANY kind — not just the
    /// three (`planEmitted`/`draftReady`/`citationAdded`) the lossy string envelope
    /// historically captured. `kind`/`summary` are derived from the event so call
    /// sites need only supply the event, its sequence, and the session.
    ///
    /// `payloadJSON` is filled with the same Codable snapshot for backward
    /// compatibility (legacy readers expect a non-empty payload string), and the
    /// new `eventPayloadJSON` carries the canonical loss-less snapshot that
    /// `StoredEvent.decodedSnapshot` reads.
    public func appendEvent(event: ResearchEvent,
                            summary: String,
                            sequence: Int,
                            session: StoredSession) throws {
        let snapshot = ResearchEventSnapshot(event: event)
        let json = (try? JSONEncoder().encode(snapshot))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stored = StoredEvent(
            id: UUID().uuidString,
            sequence: sequence,
            kind: snapshot.kind,
            summary: summary,
            payloadJSON: json,
            eventPayloadJSON: json,
            session: session
        )
        context.insert(stored)
        scheduleSave()
    }
}
