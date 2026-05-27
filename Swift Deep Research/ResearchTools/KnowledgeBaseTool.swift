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
            "k": { "type": "integer", "default": 6, "description": "Max passages to return (1–20)." }
          }
        }
        """#
    )

    private let client: SeekDBClient
    public init(client: SeekDBClient = SeekDBClient()) {
        self.client = client
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let query: String; let k: Int? }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "knowledge_base: invalid arguments")
        }
        let trimmed = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(message: "knowledge_base: empty query") }

        let k = max(1, min(args.k ?? 6, 20))
        do {
            let hits = try await client.query(trimmed, k: k)
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
            let payload = Payload(
                query: trimmed,
                results: hits.map {
                    HitPayload(id: $0.id,
                               docID: $0.docID,
                               title: $0.title,
                               score: $0.score,
                               text: $0.text)
                },
                fetchedSources: fetchedSources
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payloadData = try encoder.encode(payload)
            return .ok(summary: "Knowledge base: \(hits.count) hits for '\(Clip.clip(trimmed, to: 60))'",
                       payloadJSON: String(decoding: payloadData, as: UTF8.self))
        } catch SeekDBClient.SeekDBError.unreachable(let url) {
            return .failed(message: "Knowledge base sidecar offline at \(url.absoluteString). Start it with `python3 sidecar/seekdb_sidecar.py` or disable the toggle.")
        } catch {
            return .failed(message: "knowledge_base error: \(error.localizedDescription)")
        }
    }

    private static func fetchedSource(for hit: SeekDBClient.QueryHit) -> FetchedSource? {
        let safeDoc = hit.docID.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? hit.docID
        let safeChunk = hit.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? hit.id
        guard let url = URL(string: "kb://\(safeDoc)/\(safeChunk)") else { return nil }
        return FetchedSource(id: hit.id,
                             url: url,
                             title: hit.title,
                             extractedText: hit.text,
                             strategy: .knowledgeBase)
    }

    private struct Payload: Encodable {
        let query: String
        let results: [HitPayload]
        let fetchedSources: [FetchedSource]
    }

    private struct HitPayload: Encodable {
        let id: String
        let docID: String
        let title: String
        let score: Double?
        let text: String
    }
}
