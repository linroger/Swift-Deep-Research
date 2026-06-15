import Foundation

/// A single worker agent: takes one subtask, decides which tools to call,
/// invokes them, gathers source content, and produces a focused mini-summary.
///
/// Tool calls are routed through the worker (not the underlying LLM's native
/// tool calling alone) so the same loop works across providers that disagree
/// on tool-call wire formats.
public actor WorkerAgent {
    public let id: WorkerID
    private let llm: any LLMClient
    private let tools: [String: any ResearchTool]
    private let session: SessionDescriptor
    private let budget: BudgetMeter
    private let cache: SourceCache
    private let instructions: String
    /// How many distinct sources the worker should try to fetch and read in
    /// this subtask. Drives a concrete instruction in the system prompt so
    /// the LLM doesn't default to "2–4 most promising URLs" regardless of
    /// budget mode. Capped per-budget in BudgetMeter.
    private let sourceTarget: Int
    private let emit: @Sendable (ResearchEvent) -> Void

    public init(id: WorkerID,
                llm: any LLMClient,
                tools: [any ResearchTool],
                session: SessionDescriptor,
                budget: BudgetMeter,
                cache: SourceCache,
                instructions: String = "",
                sourceTarget: Int = 4,
                emit: @escaping @Sendable (ResearchEvent) -> Void) {
        self.id = id
        self.llm = llm
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) })
        self.session = session
        self.budget = budget
        self.cache = cache
        self.instructions = instructions
        self.sourceTarget = max(2, sourceTarget)
        self.emit = emit
    }

    /// Run the worker loop until it produces a summary or hits a tool-call limit.
    ///
    /// `extraContext` carries observations from earlier (sequential) steps so a
    /// DeerFlow-style step can build on what previous steps found instead of
    /// re-researching it. Empty for the native parallel fan-out flow.
    public func run(subtask: ResearchPlan.Subtask,
                    parentQuery: String,
                    extraContext: String = "") async throws -> WorkerOutput {
        emit(.workerStarted(WorkerDescriptor(id: id, task: subtask.question, rationale: subtask.rationale)))

        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendix = extra.isEmpty ? "" : "\n\n# User instructions (honor unless they conflict with safety)\n\(extra)"
        let knowledgeInstruction = tools["knowledge_base"] == nil ? "" : """
        0. If the user's private knowledge base could contain the answer, call
           `knowledge_base` FIRST. Treat returned passages as primary source
           evidence. Even when knowledge_base returns results, ALSO run a
           `web_search` to corroborate and extend with publicly available data —
           do not stop at the knowledge base alone unless the question is
           explicitly about private documents.
        """
        // Scale the source-fetching target with the per-worker budget. Stating
        // an explicit integer in the prompt keeps the LLM from defaulting to
        // a conservative "2–4 URLs" regardless of mode.
        let minFetches = max(3, sourceTarget - 2)
        let maxFetches = sourceTarget
        let system = """
        You are a research sub-agent. Your specific job is: \(subtask.question)

        # Strategy
        \(knowledgeInstruction)
        1. Pick the right tool. For most questions start with `web_search`; use
           `wikipedia` for reference/biographical lookups, `arxiv_search` for
           scientific papers, `reddit` for user opinions, `current_datetime` when
           the question depends on "now", `calculator` for arithmetic.
        2. Use the suggested queries if helpful: \(subtask.suggestedQueries.joined(separator: " | "))
           Consider issuing 2 separate `web_search` calls with different phrasings
           to widen coverage (e.g. one technical, one news-oriented).
        3. From the search results, call `fetch_url` (or `read_pdf` for PDFs) on
           AT LEAST \(minFetches) and ideally UP TO \(maxFetches) distinct URLs.
           Prioritize diversity of sources — primary docs, technical writeups,
           and independent commentary — not three blog posts from the same site.
           Skipping this step is a failure: a worker that only reads 1–2 sources
           cannot triangulate claims.
        4. After reading the sources, synthesize a thorough markdown answer
           (aim for 400–800 words, longer if the subtask warrants it) with inline
           markdown links [text](url) pointing at the URLs you actually used as
           evidence. Quote or paraphrase specific facts/numbers; do not stop at
           generalities.
        5. Do NOT answer the broader user question; stay scoped to your subtask.
        6. If a fetched page is paywalled, empty, or off-topic, fetch another
           URL from the original search results rather than giving up.

        When you are done, reply with your final markdown summary and stop calling tools.\(appendix)
        """
        let contextBlock = extraContext.isEmpty
            ? ""
            : "\n\n# Findings from earlier steps (build on these — do not re-research them)\n\(extraContext)"
        var messages: [LLMMessage] = [
            .system(system),
            .user("Subtask: \(subtask.question)\n\nParent question for context: \(parentQuery)\(contextBlock)")
        ]
        let toolSpecs = tools.values.map { $0.spec }

        var hops = 0
        // Cap LLM round-trips. The real ceiling on tool calls is enforced by
        // BudgetMeter.maxToolCallsPerWorker per budget mode (6 fast, 12
        // standard, 24 thorough); maxHops here is a safety net against an LLM
        // that keeps "thinking" without producing a final answer.
        let maxHops = 32
        var collectedSources: [FetchedSource] = []
        var lastText = ""

        // A worker must NEVER abort the whole research run. Budget caps
        // (per-worker tool-call / token / wall-clock limits) and transient
        // provider/network failures are normal stopping conditions for *this*
        // worker: we break out and return whatever evidence we have gathered so
        // far. Only genuine cancellation (user stopped the run) propagates.
        toolLoop: while hops < maxHops {
            hops += 1
            do {
                try Task.checkCancellation()
                try await budget.checkWallClock()

                // No artificial maxTokens cap — workers may need to summarize
                // long tool outputs, and 1500 was clipping richer responses.
                let req = LLMRequest(messages: messages, tools: toolSpecs, temperature: 0.3)
                // Bound the single call by the remaining wall-clock budget so one
                // hung provider stream can't run past the run's cap (checkWallClock
                // only fires between hops). On timeout this throws and the worker
                // stops gracefully like any other budget bust.
                let llm = self.llm
                let remaining = await budget.remainingWallClock
                let completion = try await withTimeout(remaining) { try await llm.complete(req) }
                try await budget.chargeTokens(completion.totalTokens)

                if !completion.text.isEmpty {
                    lastText = completion.text
                    emit(.reasoningDelta(id, completion.text))
                }

                if completion.toolCalls.isEmpty {
                    break toolLoop
                }

                // Append the assistant turn (with its tool calls) and run each call.
                messages.append(LLMMessage(role: .assistant, content: completion.toolCalls.map { call in
                    .toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)
                } + (completion.text.isEmpty ? [] : [.text(completion.text)])))

                for call in completion.toolCalls {
                    let invocation = ToolInvocation(id: call.id,
                                                   name: call.name,
                                                   argumentsJSON: call.argumentsJSON)
                    emit(.toolInvoked(id, invocation))
                    // Per-worker tool-call cap. Hitting it is a normal stop for
                    // this worker, not a fatal run error — end the loop and keep
                    // the sources collected so far.
                    do {
                        try await budget.registerToolCall(by: id)
                    } catch {
                        break toolLoop
                    }

                    let outcome: ToolOutcome
                    if let tool = tools[call.name] {
                        let context = ToolContext(
                            workerID: id,
                            session: session,
                            emit: emit,
                            charge: { tokens in try? await self.budget.chargeTokens(tokens) },
                            budget: budget,
                            cache: cache
                        )
                        do {
                            outcome = try await tool.call(argumentsJSON: call.argumentsJSON, context: context)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            outcome = .failed(message: "Tool \(call.name) threw: \(error.localizedDescription)")
                        }
                    } else {
                        outcome = .failed(message: "Unknown tool: \(call.name)")
                    }
                    emit(.toolResult(id, invocation, outcome))

                    let output: String = switch outcome {
                    case .ok(_, let payload): payload
                    case .failed(let m): "ERROR: \(m)"
                    }
                    messages.append(.toolResult(callID: call.id, name: call.name, output: output))

                    for fetched in Self.fetchedSources(from: outcome)
                        where !collectedSources.contains(where: { $0.id == fetched.id || $0.url == fetched.url }) {
                        collectedSources.append(fetched)
                    }
                }
                // Tools charge tokens through the non-throwing `ToolContext.charge`
                // (try? swallows the cap throw). Re-assert the token cap here so a
                // tool-heavy hop that crossed the budget stops the worker now
                // instead of running another full completion.
                try await budget.chargeTokens(0)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Cancellation can surface as a provider error (e.g. URLError
                // .cancelled) rather than CancellationError — honor it.
                if Task.isCancelled { throw CancellationError() }
                // Budget bust or transient provider/network failure that already
                // exhausted client-level retries. Stop this worker gracefully.
                emit(.warning("Worker \(id.raw) stopped early: \(error.localizedDescription)"))
                break toolLoop
            }
        }

        emit(.workerCompleted(id, summary: Clip.clip(lastText, to: 200)))
        return WorkerOutput(workerID: id,
                            subtask: subtask,
                            summary: lastText,
                            sources: collectedSources)
    }

    /// Tool payloads are intentionally heterogeneous: `fetch_url`, `read_pdf`,
    /// `wikipedia.summary`, and `reddit.thread` return a single `FetchedSource`,
    /// while the knowledge-base tool returns several synthetic `kb://` sources.
    /// Normalize those shapes here so every evidence-producing tool feeds the
    /// synthesizer and citation extractor.
    private static func fetchedSources(from outcome: ToolOutcome) -> [FetchedSource] {
        guard case .ok(_, let payload) = outcome,
              let data = payload.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(FetchedSource.self, from: data) {
            return [single]
        }
        if let many = try? decoder.decode([FetchedSource].self, from: data) {
            return many
        }
        if let envelope = try? decoder.decode(FetchedSourceEnvelope.self, from: data) {
            return envelope.fetchedSources ?? envelope.sources ?? []
        }
        return []
    }

    private struct FetchedSourceEnvelope: Decodable {
        let fetchedSources: [FetchedSource]?
        let sources: [FetchedSource]?
    }
}

public struct WorkerOutput: Sendable {
    public let workerID: WorkerID
    public let subtask: ResearchPlan.Subtask
    public let summary: String
    public let sources: [FetchedSource]
}

public extension WorkerOutput {
    /// Compact digest of prior worker findings, threaded into later-round (native
    /// engine) and sequential (DeerFlow) workers as `extraContext` so they build
    /// on earlier evidence instead of restarting cold.
    static func digest(of outputs: [WorkerOutput]) -> String {
        outputs.map { "## \($0.subtask.question)\n\(Clip.clip($0.summary, to: 2_000))" }
               .joined(separator: "\n\n")
    }
}
