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
        // Cap LLM round-trips against an LLM that keeps "thinking" without
        // finishing. Derive the cap from the per-worker tool-call budget plus
        // headroom for thinking/summary hops, so the hop cap never binds BEFORE
        // the tool budget is spent — a fixed 32 cut thorough workers (36 tool
        // calls) off early (engine-hops-cap-decoupled-from-budget). With tool
        // calls now dispatched concurrently per hop, hops needed ≤ tool budget.
        let maxHops = await budget.toolCallBudget + 8
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
                // Charge-before-use: gate the next billable completion on the token
                // cap. A worker that crossed its budget while charging the previous
                // hop's tool payloads stops HERE rather than issuing (and being
                // billed for) another full completion first. chargeTokens(0) is a
                // pure cap check (engine-no-budget-charge-on-failed-llm,
                // research-tools-charge-after-budget).
                try await budget.chargeTokens(0)

                // No artificial maxTokens cap — workers may need to summarize
                // long tool outputs, and 1500 was clipping richer responses.
                let req = LLMRequest(messages: messages, tools: toolSpecs, temperature: 0.3)
                // Bound the single call by the remaining wall-clock budget so one
                // hung provider stream can't run past the run's cap (checkWallClock
                // only fires between hops). On timeout this throws and the worker
                // stops gracefully like any other budget bust.
                let llm = self.llm
                let remaining = await budget.remainingWallClock
                let completion: LLMCompletion
                do {
                    completion = try await withTimeout(remaining) { try await llm.complete(req) }
                } catch {
                    // A provider call that partially streamed (or timed out) before
                    // failing still bills the input tokens, but `complete()` can't
                    // hand back the partial usage on a throw — so charge a
                    // conservative estimate of the prompt we sent. Otherwise a
                    // failed-but-billed call reads as free and the meter drifts below
                    // real spend (engine-no-budget-charge-on-failed-llm). Skip on
                    // cancellation (user stop — nothing provider-billed to account)
                    // and ignore a cap throw from the estimate since we're about to
                    // stop this worker regardless.
                    if !(error is CancellationError) && !Task.isCancelled {
                        try? await budget.chargeTokens(Self.estimatedPromptTokens(messages))
                    }
                    throw error
                }
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

                // Reserve a tool-call budget slot for each call IN ORDER, stopping
                // at the per-worker cap. Hitting the cap is a normal stop for this
                // worker (keep the sources gathered so far), not a fatal run error.
                var reserved: [ToolInvocation] = []
                var capHit = false
                for call in completion.toolCalls {
                    let invocation = ToolInvocation(id: call.id,
                                                   name: call.name,
                                                   argumentsJSON: call.argumentsJSON)
                    emit(.toolInvoked(id, invocation))
                    do {
                        try await budget.registerToolCall(by: id)
                    } catch {
                        capHit = true
                        break
                    }
                    reserved.append(invocation)
                }

                // Run the reserved tool calls CONCURRENTLY. They are independent
                // network/IO operations and the SourceCache dedupes in-flight
                // fetches, so serializing them was pure latency — a worker reading
                // 6 URLs took ~6× a single fetch (research-tools-serial-toolcalls).
                // Results are collected by index so tool_result messages append in
                // the SAME order as the assistant's tool_calls, which several
                // providers require. Genuine cancellation propagates out of the
                // group; any other tool error becomes a .failed outcome.
                let toolsByName = tools
                let workerID = id
                let workerSession = session
                let workerEmit = emit
                let workerBudget = budget
                let workerCache = cache
                let outcomes: [ToolOutcome] = try await withThrowingTaskGroup(of: (Int, ToolOutcome).self) { group in
                    for (index, invocation) in reserved.enumerated() {
                        let tool = toolsByName[invocation.name]
                        let argumentsJSON = invocation.argumentsJSON
                        let toolName = invocation.name
                        group.addTask {
                            let outcome: ToolOutcome
                            if let tool {
                                let context = ToolContext(
                                    workerID: workerID,
                                    session: workerSession,
                                    emit: workerEmit,
                                    charge: { tokens in try? await workerBudget.chargeTokens(tokens) },
                                    budget: workerBudget,
                                    cache: workerCache
                                )
                                do {
                                    outcome = try await tool.call(argumentsJSON: argumentsJSON, context: context)
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    outcome = .failed(message: "Tool \(toolName) threw: \(error.localizedDescription)")
                                }
                            } else {
                                outcome = .failed(message: "Unknown tool: \(toolName)")
                            }
                            return (index, outcome)
                        }
                    }
                    var collected = [ToolOutcome?](repeating: nil, count: reserved.count)
                    for try await (index, outcome) in group {
                        collected[index] = outcome
                    }
                    return collected.map { $0 ?? .failed(message: "Tool produced no outcome") }
                }

                // Process results in original order: emit, thread the tool_result
                // back into the conversation, and collect any new sources.
                for (index, invocation) in reserved.enumerated() {
                    let outcome = outcomes[index]
                    emit(.toolResult(id, invocation, outcome))
                    let output: String = switch outcome {
                    case .ok(_, let payload): payload
                    case .failed(let m): "ERROR: \(m)"
                    }
                    // Clip the copy threaded back into the conversation. The full
                    // message array — every prior tool result included — is re-sent
                    // to the provider on EVERY hop, so an un-clipped 20–40k-char
                    // fetch is re-billed multiplicatively across the worker's hops
                    // (research-tools-charge-after-budget). A generous excerpt is
                    // ample for the worker to extract facts; the FULL extracted text
                    // still reaches synthesis and citations via `collectedSources`,
                    // so no evidence is lost.
                    messages.append(.toolResult(callID: invocation.id,
                                                name: invocation.name,
                                                output: Self.clipForHistory(output)))

                    for fetched in Self.fetchedSources(from: outcome)
                        where !collectedSources.contains(where: { $0.id == fetched.id || $0.url == fetched.url }) {
                        collectedSources.append(fetched)
                    }
                }
                if capHit { break toolLoop }
                // Tools charge tokens through the non-throwing `ToolContext.charge`
                // (try? swallows the cap throw), so a tool-heavy hop can cross the
                // budget silently. The charge-before-use gate at the TOP of the next
                // iteration re-asserts the token cap and stops the worker before its
                // next completion, so no explicit re-check is needed here.
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

        // Surface weak triangulation. The source target is prompt-only — nothing
        // forces the LLM to actually read sources — so a worker that ignored the
        // instruction and read 0–1 sources still returns successfully. Emit a
        // warning so a thinly-sourced (or sourceless) worker is visible in the
        // activity log and its `sourcesRead` lets synthesis/reflection down-weight
        // it, instead of being silently accepted as grounded
        // (engine-source-target-unenforced).
        let sourceFloor = min(2, sourceTarget)
        if collectedSources.count < sourceFloor {
            emit(.warning("Worker \(id.raw) read only \(collectedSources.count) source(s) (target \(sourceTarget)) — its findings are weakly triangulated."))
        }

        emit(.workerCompleted(id, summary: Clip.clip(lastText, to: 200)))
        return WorkerOutput(workerID: id,
                            subtask: subtask,
                            summary: lastText,
                            sources: collectedSources)
    }

    /// Rough prompt-size estimate (~4 chars/token — the same proxy the tools use
    /// to charge their output) for the messages about to be sent. Charged when a
    /// provider call fails mid-stream so a failed-but-billed request isn't counted
    /// as free to the meter (engine-no-budget-charge-on-failed-llm).
    private static func estimatedPromptTokens(_ messages: [LLMMessage]) -> Int {
        var chars = 0
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let t): chars += t.count
                case .toolCall(_, let name, let args): chars += name.count + args.count
                case .toolResult(_, let name, let output): chars += name.count + output.count
                }
            }
        }
        return chars / 4
    }

    /// Cap on a single tool result's size when re-injected into the worker's
    /// message history. The full array is re-sent every hop, so an un-clipped
    /// 20–40k-char fetch is re-billed multiplicatively; a 12k-char excerpt is
    /// ample for the worker to extract facts (research-tools-charge-after-budget).
    private static let maxToolResultCharsInHistory = 12_000
    private static func clipForHistory(_ output: String) -> String {
        guard output.count > maxToolResultCharsInHistory else { return output }
        let omitted = output.count - maxToolResultCharsInHistory
        return String(output.prefix(maxToolResultCharsInHistory))
            + "\n\n[… \(omitted) characters omitted to bound re-send cost; the full text was kept for synthesis and citations.]"
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

    /// Distinct sources this worker actually read. Lets the synthesizer and
    /// reflector down-weight or target workers that triangulated thinly, and is
    /// the structured signal `engine-source-target-unenforced` asked for.
    public var sourcesRead: Int { sources.count }

    /// A worker that exhausted its hops/tool-calls without ever emitting a final
    /// summary returns `summary == ""`. Such outputs must not be rendered as
    /// answered sections in synthesis or listed as covered by the reflector
    /// (engine-empty-worker-summary-pollutes-synthesis) — their sources still
    /// feed the citation/source table separately.
    public var hasFindings: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
