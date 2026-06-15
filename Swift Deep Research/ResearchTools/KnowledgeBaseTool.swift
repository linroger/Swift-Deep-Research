import Foundation

/// Lets worker agents query the user's uploaded documents via pyseekdb.
///
/// Only added to the worker tool list when `EngineConfiguration.useKnowledgeBase`
/// is true. When the sidecar is down the tool returns a soft failure so the
/// worker can fall back to web search instead of blowing up the whole run.
public struct KnowledgeBaseTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "knowledge_base",
        description: "Search the user's uploaded documents (PDFs, notes, papers) using semantic vector search. Use this BEFORE web search when the question may already be answered by the user's private knowledge base.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["query"],
          "properties": {
            "query": { "type": "string", "description": "Natural-language search query." },
            "k": { "type": "integer", "default": 6, "description": "Max passages to return (1–20)." },
            "min_score": { "type": "number", "default": 0.30, "description": "Minimum relevance score (0–1, on the 1/(1+distance) scale) a passage must meet to be returned. Lower to surface weaker matches; raise to keep only strong ones." }
          }
        }
        """#
    )

    private let client: SeekDBClient
    public init(client: SeekDBClient = SeekDBClient()) {
        self.client = client
    }

    /// Default relevance floor on the 1/(1+distance) score scale. Conservative
    /// on purpose: 0.30 corresponds to a distance of ~2.33, so only clearly
    /// off-topic chunks are dropped and genuine (even weak) small-KB hits survive
    /// (kb-relevance-floor). Overridable per-call via the `min_score` argument.
    static let defaultMinScore = 0.30

    /// Max chunks returned from any single document, so one long document can't
    /// monopolise the result set and starve the worker of cross-document
    /// diversity (kb-relevance-floor).
    static let maxChunksPerDocument = 2

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let query: String; let k: Int?; let min_score: Double? }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "knowledge_base: invalid arguments")
        }
        let trimmed = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(message: "knowledge_base: empty query") }

        let k = max(1, min(args.k ?? 6, 20))
        // Clamp the relevance floor to [0, 1] so a stray argument can't invert
        // the filter or accept everything; default stays conservative.
        let minScore = max(0.0, min(args.min_score ?? Self.defaultMinScore, 1.0))
        do {
            let rawHits = try await queryWithRecovery(trimmed, k: k)
            // Apply the relevance floor + per-document diversity cap before we
            // surface anything to the worker (kb-relevance-floor). A nil score
            // (distance the backend couldn't convert) is treated as failing the
            // floor — we only keep passages we can vouch for as relevant.
            let hits = Self.applyRelevanceFloorAndDiversity(rawHits, minScore: minScore)
            let fetchedSources = hits.compactMap(Self.fetchedSource)
            // Emit each hit as a discovered source so the UI surfaces them in
            // the inspector under "discovered". We use a synthetic URL scheme
            // `kb://` so the source panel can distinguish them from web hits.
            for source in fetchedSources {
                let d = DiscoveredSource(
                    id: source.id,
                    title: source.title,
                    url: source.url,
                    snippet: String(source.extractedText.prefix(220)),
                    provider: "knowledge_base"
                )
                context.emit(.sourceDiscovered(context.workerID, d))
                context.emit(.sourceFetched(context.workerID, source))
            }
            // Build a single combined "passage" for the worker, with each hit
            // labelled so the worker can cite specifically.
            let combined = hits.enumerated().map { idx, hit in
                let score = hit.score.map { String(format: "%.2f", $0) } ?? "?"
                return """
                ### Passage \(idx + 1) — \(hit.title) (score \(score))
                \(hit.text)
                """
            }.joined(separator: "\n\n")
            await context.charge(combined.count / 4)
            // On zero hits, distinguish "the knowledge base is empty" from "the
            // KB has documents but none matched" so the worker doesn't falsely
            // claim it consulted private docs that don't exist — and knows to
            // fall through to web search. The worker reads the payload JSON, so
            // the signal must live there, not only in the UI summary.
            var note: String? = nil
            if hits.isEmpty && !rawHits.isEmpty {
                // The KB returned matches but all fell below the relevance floor
                // (or were de-duplicated to nothing). Treat this like empty-KB:
                // tell the worker to fall through to web_search rather than
                // claiming it consulted private docs that weren't actually
                // relevant (kb-relevance-floor). No health round-trip needed —
                // we already know documents exist.
                note = "matches were below the relevance threshold — rely on web_search"
            } else if hits.isEmpty {
                // Distinguish three cases, not two: a failed/unavailable health
                // check (docCount == nil) must NOT be reported as "the KB is
                // empty" — the documents may well exist but the sidecar was
                // transiently unreachable, and telling the worker the KB is empty
                // would wrongly suppress a retry/relevance the user expects.
                let docCount: Int?
                do { docCount = try await client.health().documents } catch { docCount = nil }
                switch docCount {
                case .some(let n) where n > 0:
                    note = "No passages matched this query, but the knowledge base has \(n) document(s) indexed — try rephrasing, or rely on web_search."
                case .some:
                    note = "The knowledge base is empty (no documents indexed). Use web_search instead."
                case .none:
                    note = "No passages matched, and the knowledge base status is currently unavailable — rely on web_search."
                }
            }
            let payload = Payload(
                query: trimmed,
                results: hits.map {
                    HitPayload(id: $0.id,
                               docID: $0.docID,
                               title: $0.title,
                               score: $0.score,
                               text: $0.text)
                },
                fetchedSources: fetchedSources,
                note: note
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payloadData = try encoder.encode(payload)
            let summarySuffix = note.map { " — \($0)" } ?? ""
            return .ok(summary: "Knowledge base: \(hits.count) hits for '\(Clip.clip(trimmed, to: 60))'\(summarySuffix)",
                       payloadJSON: String(decoding: payloadData, as: UTF8.self))
        } catch SeekDBClient.SeekDBError.unreachable(let url) {
            return .failed(message: "Knowledge base sidecar offline at \(url.absoluteString). It auto-starts at app launch; open Settings → Knowledge → Start / repair, or disable the knowledge-base toggle.")
        } catch {
            return .failed(message: "knowledge_base error: \(error.localizedDescription)")
        }
    }

    /// Query the sidecar, recovering from the common cold-start failure modes:
    /// the sidecar isn't up yet (`unreachable`), or it's up but still
    /// initializing its collection (`HTTP 5xx`). In both cases we ask
    /// `SidecarSupervisor` to bring it up and retry a few times with short
    /// backoff. Crucially we do NOT require `ensureRunning` to report `.running`
    /// before retrying — it can legitimately return `.launching` while the
    /// server finishes binding, so the query itself is the real readiness test.
    /// This keeps a research run alive instead of failing the whole KB lookup.
    private func queryWithRecovery(_ query: String, k: Int) async throws -> [SeekDBClient.QueryHit] {
        do {
            return try await client.query(query, k: k)
        } catch let error as SeekDBClient.SeekDBError {
            switch error {
            case .unreachable:
                _ = await SidecarSupervisor.shared.ensureRunning(host: client.host)
            case .httpStatus(let code, _) where code >= 500:
                _ = await SidecarSupervisor.shared.ensureRunning(host: client.host)
            default:
                throw error   // 4xx / decode errors won't be fixed by a relaunch
            }
            var lastError: Error = error
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                do {
                    return try await client.query(query, k: k)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    /// Filter the raw query hits to those meeting the relevance floor, then cap
    /// the number of chunks kept per source document for diversity
    /// (kb-relevance-floor). Input order is preserved (the sidecar already sorts
    /// by descending relevance), so the per-document cap keeps each document's
    /// strongest chunks. A hit with no score (`nil`) fails the floor — we only
    /// keep passages whose relevance we can actually vouch for.
    static func applyRelevanceFloorAndDiversity(
        _ hits: [SeekDBClient.QueryHit],
        minScore: Double
    ) -> [SeekDBClient.QueryHit] {
        var perDocCount: [String: Int] = [:]
        var kept: [SeekDBClient.QueryHit] = []
        for hit in hits {
            guard let score = hit.score, score >= minScore else { continue }
            let docID = hit.docID
            let count = perDocCount[docID, default: 0]
            guard count < maxChunksPerDocument else { continue }
            perDocCount[docID] = count + 1
            kept.append(hit)
        }
        return kept
    }

    private static func fetchedSource(for hit: SeekDBClient.QueryHit) -> FetchedSource? {
        let safeDoc = hit.docID.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? hit.docID
        let safeChunk = hit.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? hit.id
        guard let url = URL(string: "kb://\(safeDoc)/\(safeChunk)") else { return nil }
        return FetchedSource(id: hit.id,
                             url: url,
                             title: hit.title,
                             extractedText: hit.text,
                             strategy: .knowledgeBase,
                             relevanceScore: hit.score)
    }

    private struct Payload: Encodable {
        let query: String
        let results: [HitPayload]
        let fetchedSources: [FetchedSource]
        let note: String?
    }

    private struct HitPayload: Encodable {
        let id: String
        let docID: String
        let title: String
        let score: Double?
        let text: String
    }
}
