import Foundation

/// Extract citations from a draft using a separate LLM pass.
///
/// We deliberately split citation extraction from synthesis: the synthesizer's
/// job is to write prose; the extractor's job is to enforce exact-quote grounding.
/// The extractor receives the draft + all source texts and is asked to emit a
/// strict JSON array of citations whose `exactQuote` strings appear verbatim
/// in one of the supplied sources.
public struct CitationExtractor: Sendable {
    public let llm: any LLMClient

    public init(llm: any LLMClient) {
        self.llm = llm
    }

    public func extract(draft: String,
                        sources: [FetchedSource]) async throws -> [Citation] {
        let sourceCorpus = sources.enumerated().map { idx, src in
            """
            <source index="\(idx)" url="\(src.url.absoluteString)" title="\(src.title)">
            \(Clip.clip(src.extractedText, to: 4_000))
            </source>
            """
        }.joined(separator: "\n\n")

        let prompt = """
        You are a citation auditor. Given a draft answer and the source corpus, identify
        the most important claims in the draft and pair each with one EXACT quote from
        a single source that supports it.

        Rules:
        - Pick at most 12 claims.
        - The "exactQuote" must appear verbatim (whitespace tolerant) in the indicated source.
        - "claim" is your one-sentence paraphrase of the supported sentence.
        - Use the source's url and title from the metadata.

        Reply with JSON ONLY in this exact shape:
        { "citations": [
            { "claim": "...", "exactQuote": "...", "sourceURL": "...", "sourceTitle": "..." }
          ] }

        # Draft
        \(Clip.clip(draft, to: 6_000))

        # Sources
        \(sourceCorpus)
        """
        let req = LLMRequest(messages: [
            .system("You audit drafts and extract grounded citations as strict JSON."),
            .user(prompt)
        ], temperature: 0.1)

        let completion = try await llm.complete(req)
        let json = stripCodeFences(completion.text)
        struct Wire: Decodable {
            struct C: Decodable {
                let claim: String
                let exactQuote: String
                let sourceURL: String
                let sourceTitle: String
            }
            let citations: [C]
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: json.data(using: .utf8) ?? Data())
            return wire.citations.compactMap { c in
                guard let url = URL(string: c.sourceURL) else { return nil }
                return Citation(sourceURL: url,
                                sourceTitle: c.sourceTitle,
                                exactQuote: c.exactQuote,
                                claim: c.claim)
            }
        } catch {
            Log.tool.warning("Citation extraction failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func stripCodeFences(_ s: String) -> String {
        var out = s
        if out.contains("```") {
            out = out.replacingOccurrences(of: "```json", with: "")
            out = out.replacingOccurrences(of: "```", with: "")
        }
        // Trim to outermost {...}
        if let first = out.firstIndex(of: "{"), let last = out.lastIndex(of: "}") {
            return String(out[first...last])
        }
        return out
    }
}
