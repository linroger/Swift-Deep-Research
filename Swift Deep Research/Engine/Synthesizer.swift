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
        // Aggregate worker findings. Skip workers that produced no final summary
        // (exhausted hops/tool-calls without prose): rendering an empty
        // "## Worker … — <question>" section injects noise and implies the
        // sub-question was answered when it wasn't. Their sources still flow into
        // the numbered source table below via flatMap(\.sources), so nothing
        // citable is lost (engine-empty-worker-summary-pollutes-synthesis).
        let workerSection = workerOutputs.filter(\.hasFindings).map { o in
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

        // Synthesis is the single longest operation in a run. Two failure modes
        // must be bounded: (1) a stream that flows but runs long, and (2) a stream
        // that HANGS (stops yielding). The periodic in-loop token check handles (1);
        // racing consumption against the remaining wall-clock budget handles (2),
        // since the old per-chunk wall-clock poll never re-fired once chunks stopped
        // arriving (budget-wallclock-not-monotonic-check-14). We also charge token
        // estimates INCREMENTALLY as text accumulates instead of once at stream end:
        // many providers emit usage only on the final chunk, so the old end-of-stream
        // charge let a long synthesis fully generate (and bill) before the cap could
        // fire (engine-no-budget-charge-on-failed-llm).
        let state = SynthesisStreamState()
        let remaining = await budget.remainingWallClock
        let llm = self.llm

        enum StreamOutcome: Sendable { case completed, deadline }
        let outcome: StreamOutcome = try await withThrowingTaskGroup(of: StreamOutcome.self) { group in
            group.addTask {
                do {
                    var chunkCount = 0
                    // Create and consume the stream entirely within this task so no
                    // iterator/stream value crosses the task boundary.
                    for try await chunk in llm.stream(req) {
                        chunkCount += 1
                        switch chunk {
                        case .text(let t):
                            state.draft += t
                            emit(.tokenDelta(stage: .synthesis, text: t))
                        case .usage(let p, let c):
                            // Last-wins, not summed: Gemini emits CUMULATIVE usage on
                            // every SSE event, so summing over-charged 2-3×; this
                            // matches `complete()`'s assignment semantics.
                            state.lastPrompt = p
                            state.lastCompletion = c
                        default:
                            break
                        }
                        // Charge the delta between the running estimate (~4 chars/
                        // token) and what's already charged, every 48 chunks (a
                        // per-token actor hop would be wasteful). Stop the moment the
                        // run crosses its token cap, keeping the draft so far.
                        if chunkCount % 48 == 0 {
                            let estimate = state.draft.count / 4
                            let delta = estimate - state.charged
                            if delta > 0 {
                                state.charged += delta
                                do {
                                    try await budget.chargeTokens(delta)
                                } catch {
                                    state.budgetBust = true
                                    emit(.warning("Token budget exhausted; returning the synthesis draft produced so far."))
                                    break
                                }
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A provider failure mid-synthesis: keep the partial draft, flag
                    // the bust so the (billed) citation pass is skipped, and surface a
                    // warning rather than aborting the run with an empty answer.
                    state.budgetBust = true
                    emit(.warning("Synthesis stream failed (\(error.localizedDescription)); returning the draft produced so far."))
                }
                return .completed
            }
            group.addTask {
                try await Task.sleep(for: remaining)
                return .deadline
            }
            // Whichever finishes first decides; cancel the loser. Crucially we then
            // DRAIN the cancelled task so the stream consumer's writes to `state` are
            // complete before we read it — `cancelAll()` returns without awaiting the
            // loser, which would otherwise race the partial draft.
            let first = try await group.next() ?? .completed
            group.cancelAll()
            _ = try? await group.next()
            return first
        }

        if outcome == .deadline {
            state.budgetBust = true
            emit(.warning("Synthesis exceeded the wall-clock budget; returning the draft produced so far."))
        }

        // True-up the incremental estimate against the provider's authoritative
        // usage when it arrived; never refund below what we already charged.
        let authoritative = state.lastPrompt + state.lastCompletion
        if authoritative > state.charged {
            try? await budget.chargeTokens(authoritative - state.charged)
        }
        let draft = state.draft
        let budgetBust = state.budgetBust

        // Skip the citation pass (another LLM round-trip) when a budget (wall-clock
        // or token) is already spent — return the draft we have rather than overrun.
        let citations: [Citation]
        if budgetBust {
            emit(.warning("Synthesis reached a budget limit; returning the draft without a citation pass."))
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

/// Mutable accumulator for the synthesis stream. Written ONLY by the single
/// stream-consuming child task and read after that task is awaited to completion
/// (the task group drains the consumer before `synthesize` reads it), so the
/// `@unchecked Sendable` is sound — there is never concurrent access.
private final class SynthesisStreamState: @unchecked Sendable {
    var draft = ""
    var lastPrompt = 0
    var lastCompletion = 0
    /// Completion tokens already charged incrementally during the stream.
    var charged = 0
    var budgetBust = false
}
