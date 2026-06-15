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
                        sources: [FetchedSource],
                        budget: BudgetMeter? = nil) async throws -> [Citation] {
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
        // Count the citation pass (large source corpus in, JSON out) against the
        // run's token cap. Non-throwing so it accounts without aborting.
        if let budget { try? await budget.chargeTokens(completion.totalTokens) }
        let json = LLMJSON.extractObject(completion.text)
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
            // Pre-normalize every source's text once so the per-citation verification
            // is O(citations × sources) on already-collapsed strings rather than
            // re-normalizing the (large) corpus for each candidate.
            let normalizedSources = sources.map { (src: $0, normalizedText: Self.normalizeWhitespace($0.extractedText)) }
            return wire.citations.compactMap { c in
                guard let url = URL(string: c.sourceURL) else { return nil }
                let normalizedQuote = Self.normalizeWhitespace(c.exactQuote)
                // Empty/whitespace-only quotes can't be grounded; drop them so a model
                // that emits "" doesn't smuggle in a citation that trivially "matches".
                guard !normalizedQuote.isEmpty else { return nil }

                // Anti-hallucination gate: the exactQuote MUST appear (whitespace-
                // tolerant, case-insensitive) in a real source's extractedText, or the
                // citation is fabricated. Prefer the source the model named (by URL,
                // then title); fall back to scanning the whole corpus so a correct
                // quote tagged with the wrong URL is repaired rather than discarded.
                let named = normalizedSources.first { $0.src.url == url }
                    ?? normalizedSources.first { $0.src.title.caseInsensitiveCompare(c.sourceTitle) == .orderedSame }
                let match: FetchedSource?
                if let named, named.normalizedText.range(of: normalizedQuote, options: .caseInsensitive) != nil {
                    match = named.src
                } else {
                    match = normalizedSources.first {
                        $0.normalizedText.range(of: normalizedQuote, options: .caseInsensitive) != nil
                    }?.src
                }
                guard let source = match else {
                    Log.tool.warning("Dropping ungrounded citation; exactQuote not found in any source: \(c.exactQuote, privacy: .public)")
                    return nil
                }
                // Repair the URL/title to whichever source actually contains the quote;
                // for a clean match against the named source these are unchanged.
                return Citation(sourceURL: source.url,
                                sourceTitle: source.title,
                                exactQuote: c.exactQuote,
                                claim: c.claim)
            }
        } catch {
            Log.tool.warning("Citation extraction failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Collapse every run of whitespace (spaces, tabs, newlines) to a single space
    /// and trim the ends, so a quote and its source text compare equal even when the
    /// LLM re-wrapped lines or normalized indentation. This is the "whitespace
    /// tolerant" half of the verbatim-grounding promise made in the prompt; the
    /// case-insensitive `range(of:)` call supplies the rest.
    private static func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

}
