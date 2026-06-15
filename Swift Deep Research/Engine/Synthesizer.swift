import Foundation

/// Stage 3 — combine worker outputs into the user-facing draft.
/// Streams tokens out as `.tokenDelta(stage: .synthesis, ...)`.
///
/// Citations are written inline as `[1]`, `[2]` markers; the SourcePanel and
/// the in-canvas chip layer cross-reference them with the source list. This
/// matches the Perplexity/ChatGPT-Search rendering pattern.
public struct Synthesizer: Sendable {
    public let llm: any LLMClient
    public let citationExtractor: CitationExtractor
    public let instructions: String

    public init(llm: any LLMClient,
                instructions: String = "") {
        self.llm = llm
        self.citationExtractor = CitationExtractor(llm: llm)
        self.instructions = instructions
    }

    public func synthesize(plan: ResearchPlan,
                           workerOutputs: [WorkerOutput],
                           conversation: ConversationContext = ConversationContext(),
                           budget: BudgetMeter,
                           emit: @escaping @Sendable (ResearchEvent) -> Void) async throws -> DraftDescriptor {
        // Aggregate worker findings.
        let workerSection = workerOutputs.map { o in
            """
            ## Worker \(o.workerID.raw) — \(o.subtask.question)
            \(o.summary)
            """
        }.joined(separator: "\n\n")

        // Deduplicate sources across workers, preserve order of first appearance.
        var seen: Set<URL> = []
        var orderedSources: [FetchedSource] = []
        for source in workerOutputs.flatMap(\.sources) where !seen.contains(source.url) {
            seen.insert(source.url)
            orderedSources.append(source)
        }
        let numberedSources = orderedSources.enumerated()
        let sourceTable = numberedSources.map { idx, src in
            "[\(idx + 1)] \(src.title) — \(src.url.absoluteString)"
        }.joined(separator: "\n")

        let conversationContext = conversation.isFirstTurn ? "" : """

        # Prior conversation context
        Previous turns of this research session — extend rather than restart:
        \(conversation.priorTurns.suffix(4).map { "- \($0.role.rawValue): \(Clip.clip($0.content, to: 240))" }.joined(separator: "\n"))
        """

        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendix = extra.isEmpty ? "" : "\n\n# User instructions (honor unless they conflict with safety)\n\(extra)"
        let system = """
        You are a senior research analyst writing the final synthesis.

        Write a comprehensive markdown answer that:
        - Opens with a 2–3 sentence direct answer (the TL;DR a busy reader needs).
        - Then expands into structured sections drawn from the worker findings.
        - Cites every load-bearing claim with inline numbered markers like `[1]`, `[2]`
          that map to the numbered source list. Multiple citations are `[1][3]`.
        - Uses tables and bullet lists where they clarify; flowing prose elsewhere.
        - Includes a `## Limitations` note when sources disagree or coverage is thin.
        - NEVER invents facts not present in the worker summaries or sources.
        - NEVER reproduces source URLs in prose; use the numbered marker form.

        At the very end, include a section titled exactly `## Sources` that lists each
        cited source on its own line as `[N] Title — URL`. Include only sources you
        actually cited.\(appendix)
        """
        let user = """
        # User question
        \(plan.userQuery)

        # Plan strategy
        \(plan.strategy.rawValue) (\(plan.subtasks.count) subtasks)

        # Worker findings
        \(workerSection)

        # Numbered sources (use [N] markers when citing)
        \(sourceTable)
        \(conversationContext)
        """
        // No artificial maxTokens cap — let the synthesizer use the model's
        // full output window. The provider client picks a sensible default
        // (e.g. AnthropicClient.modelMaxOutput) so we don't 400 on Haiku.
        let req = LLMRequest(messages: [.system(system), .user(user)],
                             temperature: 0.4)

        var draft = ""
        // Track last-seen usage and charge ONCE after the stream. Providers
        // disagree on usage semantics: OpenAI/Anthropic emit a single final
        // usage, but Gemini emits CUMULATIVE usage on every SSE event — summing
        // per-chunk (the old behavior) over-charged the budget 2-3×. Last-wins
        // matches `complete()`'s assignment semantics and is correct for both.
        var lastPrompt = 0
        var lastCompletion = 0
        var wallClockBust = false
        var chunkCount = 0
        let stream = llm.stream(req)
        for try await chunk in stream {
            // Synthesis is the single longest operation in a run, and
            // checkWallClock previously only fired at loop boundaries — so a
            // slow/hung synthesis stream could blow the whole wall-clock cap.
            // Poll periodically (not per token — that's an actor hop each token)
            // and stop streaming with whatever draft we have when time is up.
            chunkCount += 1
            if chunkCount % 48 == 0 {
                do { try await budget.checkWallClock() }
                catch { wallClockBust = true; break }
            }
            switch chunk {
            case .text(let t):
                draft += t
                emit(.tokenDelta(stage: .synthesis, text: t))
            case .usage(let p, let c):
                lastPrompt = p
                lastCompletion = c
            case .finished: break
            default: break
            }
        }
        if lastPrompt + lastCompletion > 0 {
            try? await budget.chargeTokens(lastPrompt + lastCompletion)
        }

        // Skip the citation pass (another LLM round-trip) when the wall-clock
        // budget is already spent — return the draft we have rather than overrun.
        let citations: [Citation]
        if wallClockBust {
            emit(.warning("Synthesis reached the wall-clock budget; returning the draft without a citation pass."))
            citations = []
        } else {
            citations = try await citationExtractor.extract(draft: draft,
                                                            sources: orderedSources,
                                                            budget: budget)
        }
        for c in citations { emit(.citationAdded(c)) }

        let descriptor = DraftDescriptor(markdown: draft, citations: citations)
        emit(.draftReady(descriptor))
        return descriptor
    }
}
