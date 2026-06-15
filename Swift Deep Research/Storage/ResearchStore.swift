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
        // One-shot retention sweep at startup so the store can't grow without
        // bound across the app's lifetime. Runs synchronously on the MainActor
        // (this initializer is MainActor-isolated, matching the context), and a
        // failure is logged but never blocks launch. Manual deletes are unaffected.
        pruneSessions()
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
            // A first failure can be transient — e.g. another process (a lingering
            // app instance, Spotlight/Time Machine, or a crash-recovery sweep) is
            // momentarily holding the store/WAL lock. Destroying the store on that
            // would discard recoverable history needlessly, so retry once after a
            // short delay before deciding the store is genuinely incompatible.
            Log.engine.error("SwiftData store open failed (\(error.localizedDescription, privacy: .public)); retrying once before rebuild.")
            Thread.sleep(forTimeInterval: 0.25)
            if let retried = try? ModelContainer(for: schema, configurations: [config]) {
                Log.engine.notice("SwiftData store opened on retry; no rebuild needed.")
                return retried
            }

            // Still failing: the on-disk store is incompatible with the current
            // schema — i.e. a @Model changed with no migration plan. Without a
            // rebuild, the very next schema edit would crash the app on launch for
            // every existing install (an unrecoverable brick). Make the rebuild
            // RECOVERABLE first: copy the store + WAL/SHM sidecars to a timestamped
            // backup so the prior history can be inspected or restored manually,
            // then recreate the store empty so the app launches. A VersionedSchema
            // + SchemaMigrationPlan that PRESERVES data is the follow-up once the
            // schema stabilizes.
            if let backupURL = Self.backupStore(at: config.url) {
                Log.engine.error("SwiftData store incompatible; backed up to \(backupURL.path, privacy: .public) before rebuilding empty store.")
            } else {
                Log.engine.error("SwiftData store incompatible; backup failed, rebuilding empty store anyway.")
            }
            Self.destroyStore(at: config.url)
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    /// Copy the SQLite store and its WAL/SHM sidecars to a sibling backup named
    /// `<store>.corrupt-<epoch>` so the about-to-be-destroyed history is recoverable.
    /// Returns the backup store URL on success (so the path can be logged/surfaced),
    /// or `nil` if the primary store file could not be copied. Sidecar copy failures
    /// are tolerated — a missing/locked WAL must not abort the backup of the store.
    private static func backupStore(at url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let epoch = Int(Date().timeIntervalSince1970)
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(epoch)")
        do {
            try fm.copyItem(at: url, to: backupURL)
        } catch {
            Log.engine.error("Failed to back up SwiftData store: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        for suffix in ["-shm", "-wal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try? fm.copyItem(at: sidecar,
                             to: URL(fileURLWithPath: backupURL.path + suffix))
        }
        return backupURL
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

    /// Recreate a session from an exported JSON dump (decoded by
    /// `SessionExporter.importJSON`) so an export round-trips back into a stored,
    /// browsable session. Fresh UUIDs are minted for the session and its turns —
    /// the originals aren't carried in the export and `.unique` ids must never
    /// collide with an existing row. Citation ids are likewise regenerated, and
    /// source ids reuse the `sessionID|url` composite convention from
    /// `upsertSource` so an imported session de-dupes/cascades exactly like a
    /// natively-created one.
    ///
    /// Durability boundary: the import is a discrete user action whose result
    /// must survive immediately, so it flushes synchronously (also draining any
    /// pending coalesced save).
    @discardableResult
    public func importSession(_ imported: SessionExporter.ImportedSession) throws -> StoredSession {
        let session = StoredSession(
            query: imported.query,
            titleSummary: String(imported.query.prefix(80)),
            providerName: imported.providerName,
            createdAt: imported.createdAt,
            status: StoredSession.Status(rawValue: imported.status) ?? .completed,
            totalTokens: imported.totalTokens
        )
        context.insert(session)
        // The export sorts turns oldest-first; preserve that order and keep each
        // turn's recorded createdAt so the timeline reads identically.
        for t in imported.turns {
            let turn = StoredTurn(
                role: t.role,
                markdown: t.markdown,
                createdAt: t.createdAt,
                session: session
            )
            context.insert(turn)
            for c in t.citations {
                let citation = StoredCitation(
                    id: UUID().uuidString,
                    claim: c.claim,
                    exactQuote: c.exactQuote,
                    sourceURLString: c.url,
                    sourceTitle: c.title,
                    turn: turn
                )
                context.insert(citation)
            }
        }
        for s in imported.sources {
            let source = StoredSource(
                id: "\(session.id.uuidString)|\(s.url)",
                urlString: s.url,
                title: s.title,
                snippet: s.snippet,
                providerHint: s.providerHint,
                fetchedAt: s.fetchedAt,
                session: session
            )
            context.insert(source)
        }
        session.updatedAt = .now
        isDirty = true
        flushNow()
        return session
    }

    /// Cap the stored history at the `keepingMostRecent` newest sessions, deleting
    /// the older ones (their turns/sources/events/citations follow via the cascade
    /// delete rules) so the SQLite store can't grow without bound over the app's
    /// lifetime. Sessions are ordered newest-first by `updatedAt` (the indexed
    /// sort column), so we fetch only the overflow past the cap and delete it,
    /// then flush once. The default (200) is deliberately generous — this is a
    /// safety valve against pathological growth, not an aggressive trimmer, and it
    /// is independent of the user's manual `deleteSession`.
    ///
    /// Best-effort by design: a fetch/save failure is logged and swallowed so it
    /// can never block startup (where this runs once from `init`).
    public func pruneSessions(keepingMostRecent cap: Int = 200) {
        guard cap >= 0 else { return }
        var descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        // Skip the newest `cap` rows; everything fetched after that is overflow.
        descriptor.fetchOffset = cap
        do {
            let overflow = try context.fetch(descriptor)
            guard !overflow.isEmpty else { return }
            for session in overflow {
                context.delete(session)
            }
            isDirty = true
            flushNow()
            Log.engine.notice("Pruned \(overflow.count, privacy: .public) old session(s) beyond retention cap \(cap, privacy: .public).")
        } catch {
            Log.engine.error("Session retention prune failed: \(error.localizedDescription, privacy: .public)")
        }
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
    /// The canonical loss-less snapshot is stored ONCE in `eventPayloadJSON` (which
    /// `StoredEvent.decodedSnapshot` reads); `payloadJSON` is left empty for new
    /// rows. Previously the identical JSON was encoded and written to BOTH fields,
    /// doubling the encode cost and on-disk size of every event for a reconstruction
    /// path that has no consumers (replay isn't implemented). `decodedSnapshot`
    /// never reads `payloadJSON`, so the empty value is harmless, and legacy rows —
    /// which carry their own `payloadJSON`/`eventPayloadJSON` — still decode exactly
    /// as before.
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
            payloadJSON: "",
            eventPayloadJSON: json,
            session: session
        )
        context.insert(stored)
        scheduleSave()
    }
}
