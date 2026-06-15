import Foundation

/// Top-level entry point for a research run.
///
/// Drives the iterative agent loop:
///
///     plan(query, context)
///     → fan out workers (TaskGroup, shared SourceCache)
///     → synthesize draft (streaming)
///     → for each remaining round:
///         reflect (gap-finding for round 2-3, deepening for round 4+)
///         → fall back to engine-generated deepening subtasks if reflector
///           returns nothing
///         → fan out follow-up workers → re-synthesize
///     → done after maxRounds OR budget exhaustion
///
/// The engine commits to running all configured rounds. Earlier versions
/// bailed out the moment the reflector said "ready" — which collapsed the
/// difference between fast/standard/thorough modes. Each round now adds
/// either new gap-filling subtasks or new deepening directions, so a 6-round
/// thorough run produces materially more depth than a 1-round fast run.
public struct ResearchEngine: Sendable {
    private let registry: ProviderRegistry
    private let config: EngineConfiguration
    private let iteration: IterationController

    public init(registry: ProviderRegistry = .init(),
                config: EngineConfiguration) {
        self.registry = registry
        self.config = config
        self.iteration = config.iteration
    }

    public func run(query: String,
                    sessionID: UUID = UUID(),
                    context: ConversationContext = ConversationContext()) -> AsyncThrowingStream<ResearchEvent, Error> {
        // The DeerFlow flow is a separate methodology (background investigation →
        // structured plan → sequential steps → re-plan → report) but speaks the
        // same ResearchEvent stream, so the UI is unchanged.
        if config.researchFlow == .deerflow {
            return DeerFlowEngine(registry: registry, config: config)
                .run(query: query, sessionID: sessionID, context: context)
        }
        let registry = self.registry
        let config = self.config
        let iteration = self.iteration
        // Bounded backpressure instead of .unbounded: the synthesizer emits one
        // .tokenDelta per chunk and workers emit per-completion/per-tool events,
        // while the consumer runs on @MainActor doing SwiftData persistence per
        // event. If the MainActor stalls under heavy streaming, an unbounded buffer
        // grows without limit (engine-unbounded-stream-buffer-leak). 8192 is far
        // above any normal run's in-flight backlog (the UI drains continuously and
        // already trims token/activity logs downstream), so normal runs never drop
        // an event; only a pathological stall bounds memory by discarding the
        // oldest buffered deltas rather than spiking.
        return AsyncThrowingStream<ResearchEvent, Error>(bufferingPolicy: .bufferingNewest(8192)) { continuation in
            let task = Task {
                let start = ContinuousClock().now
                let budget = BudgetMeter(budget: config.budget)
                let cache = SourceCache()
                var conversation = context
                // Pre-warm the per-run cache with sources fetched in earlier turns
                // of this session so a follow-up turn doesn't re-fetch the same URLs
                // cold (engine-cache-not-used-for-cross-turn). We seed through the
                // public fetch() API (extractor just returns the known source), which
                // populates the result cache under the same normalized key a later
                // worker fetch will hit. Cheap: no network, just an in-memory insert.
                for source in conversation.accumulatedSources {
                    let known = source
                    _ = try? await cache.fetch(source.url) { _ in known }
                }
                let providerName = config.workerProvider.displayName +
                    (config.workerModel.map { " — \($0)" } ?? "")
                let session = SessionDescriptor(id: sessionID,
                                               query: query,
                                               providerName: providerName)

                // A single @Sendable emit shared by all parallel workers and the
                // synthesis loop. `AsyncThrowingStream.Continuation.yield` is itself
                // thread-safe, so concurrent yields from N workers never race — they
                // only INTERLEAVE in a non-deterministic order. That is intentional
                // and safe: every consumer keys events by `WorkerID`
                // (LiveSession.ingest does `workers[id]?…`), and `toolResult` is
                // matched within a single worker's history by the provider-minted
                // unique tool-call id — never by global arrival order. Do NOT add any
                // logic here that assumes a total ordering across workers; if strict
                // ordering is ever required, route emits through a serializing actor
                // rather than relying on yield order (concurrency-emit-closure-reentrancy-ordering).
                let emit: @Sendable (ResearchEvent) -> Void = { event in
                    continuation.yield(event)
                }
                emit(.sessionStarted(session))

                do {
                    // Resolve every role through the single role-based factory
                    // (the same one DeerFlowEngine uses) so provider/model/endpoint
                    // resolution lives in exactly one place — the native engine
                    // previously repeated all six config args per role.
                    let orchestratorLLM = try await registry.makeClient(role: .orchestrator, config: config)
                    let workerLLM = try await registry.makeClient(role: .worker, config: config)
                    let synthesisLLM = try await registry.makeClient(role: .synthesis, config: config)

                    let planner = Planner(llm: orchestratorLLM,
                                          instructions: config.systemPromptAddendum,
                                          knowledgeBaseAvailable: config.useKnowledgeBase,
                                          budget: budget)
                    let synthesizer = Synthesizer(llm: synthesisLLM,
                                                  instructions: config.systemPromptAddendum)
                    let reflector = Reflector(llm: orchestratorLLM, budget: budget)

                    let tools = await Self.makeTools(cache: cache, config: config)
                    let perWorkerSourceTarget = config.budget.maxSourcesPerWorker

                    // --- Round 1: initial plan + workers + synthesis
                    conversation.appendUserTurn(query)
                    emit(.iterationStarted(round: 1, of: iteration.maxRounds))

                    var plan = try await planner.plan(query: query, context: conversation)
                    emit(.planEmitted(plan))

                    var accumulatedOutputs: [WorkerOutput] = []
                    // Track the questions actually DISPATCHED to workers (not the
                    // full accumulated plan). The old dedup keyed off plan.subtasks,
                    // which included subtasks queued-but-never-run beyond the worker
                    // cap — so those were marked "asked" and never researched, even
                    // in later rounds. A separate dispatched-set + an overflow queue
                    // keeps unran subtasks eligible (engine-plan-truncation-silent).
                    var dispatchedQuestions = Set<String>()
                    var pendingSubtasks: [ResearchPlan.Subtask] = []

                    // Defense-in-depth against a degenerate plan reaching this far
                    // (the decoder already falls back on empty/blank subtasks, but a
                    // future planner path could hand us an empty `plan.subtasks`): if
                    // the first batch is empty, seed it from the single-subtask
                    // fallback so at least one worker always runs and the run never
                    // silently fans out zero workers (engine-empty-planner-output).
                    var round1Batch = Array(plan.subtasks.prefix(config.budget.maxWorkers))
                    if round1Batch.isEmpty {
                        round1Batch = Array(ResearchPlanJSON.fallback(query: query).subtasks.prefix(config.budget.maxWorkers))
                    }
                    let round1Overflow = Array(plan.subtasks.dropFirst(config.budget.maxWorkers))
                    pendingSubtasks.append(contentsOf: round1Overflow)
                    if !round1Overflow.isEmpty {
                        emit(.warning("Plan has \(plan.subtasks.count) subtasks but only \(config.budget.maxWorkers) run per round — \(round1Overflow.count) queued for later rounds."))
                    }
                    for s in round1Batch { dispatchedQuestions.insert(s.question.lowercased()) }

                    // On a follow-up turn, tell round-1 workers which URLs are
                    // already cached so they prefer new sources (and any re-read of
                    // a known URL is served from the pre-seeded cache for free).
                    let firstRound = try await Self.runWorkers(
                        subtasks: round1Batch,
                        parentQuery: query,
                        workerLLM: workerLLM,
                        tools: tools,
                        session: session,
                        budget: budget,
                        cache: cache,
                        instructions: config.systemPromptAddendum,
                        sourceTarget: perWorkerSourceTarget,
                        extraContext: conversation.seenSourcesNote(),
                        emit: emit
                    )
                    accumulatedOutputs.append(contentsOf: firstRound)

                    var draft = try await synthesizer.synthesize(
                        plan: plan,
                        workerOutputs: accumulatedOutputs,
                        conversation: conversation,
                        budget: budget,
                        emit: emit
                    )

                    // --- Subsequent rounds: reflect → workers → re-synthesize
                    // Always run all configured rounds (or until budget is
                    // exhausted). Mode flips from gap-finding to deepening
                    // after round 3 so later rounds keep producing substantive
                    // follow-up subtasks instead of bailing on "ready".
                    if iteration.reflectAfterFirstRound {
                        // Two distinct, independently-monotonic counters
                        // (engine-round-counting-mismatch):
                        //  - `round` is the RESEARCH-iteration number surfaced as
                        //    "Iteration N of M"; it advances only when a round of
                        //    workers actually runs (after dedup yields candidates).
                        //  - `reflectionPass` counts every reflection pass of this
                        //    loop, so "Reflection round R" stays monotonic even when
                        //    a pass produces no surviving subtasks and ends the loop.
                        // Previously both used `round`, so reflectionStarted reused a
                        // stale pre-increment value and diverged from iterationStarted.
                        var round = 1
                        var reflectionPass = 0
                        while round < iteration.maxRounds {
                            try Task.checkCancellation()
                            // Stop if the wall-clock budget is about to bust;
                            // a half-finished round is worse than ending here.
                            do {
                                try await budget.checkWallClock()
                            } catch {
                                emit(.reflectionConcluded(continuing: false, remainingGaps: 0))
                                break
                            }

                            reflectionPass += 1
                            emit(.reflectionStarted(round: reflectionPass))
                            // Deepening mode keys off the research-round number (the
                            // depth of researched material), not the pass count.
                            let mode: Reflector.Mode = (round >= 3) ? .deepening : .gapFinding
                            let critique = try await reflector.critique(
                                query: query,
                                plan: plan,
                                workerOutputs: accumulatedOutputs,
                                draft: draft.markdown,
                                mode: mode
                            )
                            emit(.reflectionEmitted(critique))

                            var newSubtasks = critique.subtasks()
                            // If the reflector returns nothing actionable,
                            // synthesize fallback subtasks so the round still
                            // contributes. This is what keeps "Round 4/6"
                            // from being a no-op. The fallbacks are now distinct
                            // per round (synthesizeDeepeningSubtasks rotates its
                            // angles by `round`), so a quiet reflector no longer
                            // regenerates the same three questions every round and
                            // self-filters to empty (engine-dedup-truncates-
                            // reflection-rounds).
                            if newSubtasks.isEmpty {
                                newSubtasks = Self.synthesizeDeepeningSubtasks(
                                    plan: plan,
                                    workerOutputs: accumulatedOutputs,
                                    round: round + 1
                                )
                            }

                            // Candidates = previously-queued overflow first (so
                            // deferred planned work runs before brand-new gaps),
                            // then this round's fresh subtasks. Dedup against what
                            // was actually DISPATCHED and against intra-batch
                            // repeats, preserving order.
                            let candidatesRaw = pendingSubtasks + newSubtasks
                            pendingSubtasks = []
                            var candidates: [ResearchPlan.Subtask] = []
                            var seenThisRound = Set<String>()
                            for s in candidatesRaw {
                                let key = s.question.lowercased()
                                if dispatchedQuestions.contains(key) { continue }
                                if !seenThisRound.insert(key).inserted { continue }
                                candidates.append(s)
                            }
                            if candidates.isEmpty {
                                // Genuinely nothing new to ask and nothing queued —
                                // end the loop gracefully rather than spin.
                                emit(.reflectionConcluded(continuing: false, remainingGaps: 0))
                                break
                            }

                            round += 1
                            emit(.reflectionConcluded(continuing: true, remainingGaps: candidates.count))
                            emit(.iterationStarted(round: round, of: iteration.maxRounds))

                            // Dispatch up to the worker cap; re-queue the rest for a
                            // later round instead of dropping it. Only the dispatched
                            // subtasks join the plan and the asked-set, so queued
                            // overflow stays eligible (engine-plan-truncation-silent).
                            let toRun = Array(candidates.prefix(config.budget.maxWorkers))
                            let overflow = Array(candidates.dropFirst(config.budget.maxWorkers))
                            pendingSubtasks.append(contentsOf: overflow)
                            if !overflow.isEmpty {
                                emit(.warning("\(overflow.count) follow-up subtask(s) queued for a later round (worker cap \(config.budget.maxWorkers))."))
                            }
                            for s in toRun { dispatchedQuestions.insert(s.question.lowercased()) }

                            plan = ResearchPlan(
                                userQuery: plan.userQuery,
                                restatement: plan.restatement,
                                strategy: plan.strategy,
                                subtasks: plan.subtasks + toRun,
                                estimatedComplexity: plan.estimatedComplexity,
                                estimatedTokenBudget: plan.estimatedTokenBudget
                            )
                            // Thread a digest of everything found so far into the
                            // follow-up workers so deepening/gap-filling rounds
                            // build on prior evidence instead of re-researching
                            // cold (the question-text dedup above only avoids
                            // verbatim repeats, not semantic overlap).
                            // Combine this run's worker digest with the prior-turn
                            // seen-sources note (empty on a first turn) so deepening
                            // workers build on both in-run findings and cross-turn
                            // cached sources.
                            let seenNote = conversation.seenSourcesNote()
                            let digest = WorkerOutput.digest(of: accumulatedOutputs)
                            let priorContext = seenNote.isEmpty ? digest
                                : (digest.isEmpty ? seenNote : digest + "\n\n" + seenNote)
                            let refinementOutputs = try await Self.runWorkers(
                                subtasks: toRun,
                                parentQuery: query,
                                workerLLM: workerLLM,
                                tools: tools,
                                session: session,
                                budget: budget,
                                cache: cache,
                                instructions: config.systemPromptAddendum,
                                sourceTarget: perWorkerSourceTarget,
                                extraContext: priorContext,
                                emit: emit
                            )
                            accumulatedOutputs.append(contentsOf: refinementOutputs)

                            draft = try await synthesizer.synthesize(
                                plan: plan,
                                workerOutputs: accumulatedOutputs,
                                conversation: conversation,
                                budget: budget,
                                emit: emit
                            )
                        }
                    }

                    conversation.appendAssistantTurn(draft.markdown)
                    let snapshot = await budget.snapshot
                    let elapsed = ContinuousClock().now - start
                    emit(.sessionCompleted(elapsed: elapsed, totalTokens: snapshot.tokensUsed))
                    continuation.finish()
                } catch is CancellationError {
                    emit(.error(EngineFailure(kind: .cancelled, message: "Research cancelled")))
                    continuation.finish()
                } catch let failure as EngineFailure {
                    // Surface the failure EXACTLY ONCE — via the .error event — and
                    // finish the stream cleanly. Previously this both emitted .error
                    // AND finished(throwing:), so a consumer that renders .error
                    // events and ALSO catches the stream throw showed the same
                    // failure twice (engine-double-error-and-throw). The cancelled
                    // path above already established the emit-then-finish() contract.
                    emit(.error(failure))
                    continuation.finish()
                } catch {
                    let wrapped = EngineFailure(kind: .unknown,
                                                message: error.localizedDescription,
                                                underlying: String(describing: error))
                    emit(.error(wrapped))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private static func runWorkers(subtasks: [ResearchPlan.Subtask],
                                   parentQuery: String,
                                   workerLLM: any LLMClient,
                                   tools: [any ResearchTool],
                                   session: SessionDescriptor,
                                   budget: BudgetMeter,
                                   cache: SourceCache,
                                   instructions: String,
                                   sourceTarget: Int,
                                   extraContext: String = "",
                                   emit: @escaping @Sendable (ResearchEvent) -> Void) async throws -> [WorkerOutput] {
        // Each worker is isolated: a single worker that throws (budget bust,
        // exhausted-retry network drop, etc.) must NOT abort its siblings or the
        // run. Workers already degrade gracefully internally; this task group is
        // defense-in-depth — non-cancellation throws are caught and dropped to
        // nil so the surviving workers' findings still reach synthesis. Genuine
        // cancellation propagates so a stopped run tears down promptly.
        try await withThrowingTaskGroup(of: WorkerOutput?.self) { group in
            for subtask in subtasks {
                let id = WorkerID.make(subtask.question)
                let worker = WorkerAgent(
                    id: id,
                    llm: workerLLM,
                    tools: tools,
                    session: session,
                    budget: budget,
                    cache: cache,
                    instructions: instructions,
                    sourceTarget: sourceTarget,
                    emit: emit
                )
                group.addTask {
                    do {
                        return try await worker.run(subtask: subtask, parentQuery: parentQuery, extraContext: extraContext)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        emit(.warning("Worker \(id.raw) failed: \(error.localizedDescription)"))
                        return nil
                    }
                }
            }
            var outs: [WorkerOutput] = []
            for try await out in group {
                if let out { outs.append(out) }
            }
            return outs
        }
    }

    /// Shared by both research flows (native and DeerFlow).
    static func makeTools(cache: SourceCache,
                          config: EngineConfiguration) async -> [any ResearchTool] {
        let search = await WebSearchTool.makeDefault()
        let reader = WebReaderTool()
        let wikipedia = WikipediaTool()
        let arxiv = ArXivTool()
        let pdf = PDFReaderTool()
        let reddit = RedditTool()
        let dateTime = DateTimeTool()
        let calc = CalculatorTool()
        var tools: [any ResearchTool] = [search, reader, wikipedia, arxiv, pdf, reddit, dateTime, calc]
        if config.useKnowledgeBase {
            let kbClient = SeekDBClient(host: config.seekdbHost)
            tools.insert(KnowledgeBaseTool(client: kbClient), at: 0)
        }
        return tools
    }

    /// Fallback subtasks when the reflector returns nothing usable. Generated
    /// deterministically from the existing plan so we never blow a round on an
    /// empty critique.
    ///
    /// The angles ROTATE by round. The previous version templated three fixed
    /// questions purely on `userQuery` (with `round` only in the rationale text),
    /// so a quiet reflector regenerated byte-identical questions every round —
    /// which the asked-question dedup then filtered to empty, collapsing a
    /// thorough 6-round run into far fewer effective rounds
    /// (engine-dedup-truncates-reflection-rounds). Drawing a distinct 3-angle
    /// window per round keeps later rounds producing genuinely new directions.
    private static func synthesizeDeepeningSubtasks(plan: ResearchPlan,
                                                    workerOutputs: [WorkerOutput],
                                                    round: Int) -> [ResearchPlan.Subtask] {
        let q = plan.userQuery
        // A pool of deepening angles a research analyst opens up next. Each round
        // takes a sliding window of three, so consecutive rounds are disjoint.
        let pool: [ResearchPlan.Subtask] = [
            .init(question: "What are the most recent (last 30-90 days) updates, releases, or developments related to: \(q)?",
                  rationale: "Deepening: keep the answer current; the plan may miss late-breaking information.",
                  suggestedQueries: ["\(q) latest update", "\(q) news 2026", "\(q) recent release"]),
            .init(question: "Find independent or contrarian sources that critique, contradict, or qualify the main claims so far about: \(q).",
                  rationale: "Deepening: cross-verify load-bearing claims and surface counter-evidence.",
                  suggestedQueries: ["\(q) criticism", "\(q) limitations", "\(q) controversy"]),
            .init(question: "What technical specifics, exact numbers, benchmarks, datasets, or quantitative comparisons would sharpen the analysis of: \(q)?",
                  rationale: "Deepening: replace generic descriptions with hard numbers.",
                  suggestedQueries: ["\(q) benchmark", "\(q) performance numbers", "\(q) technical specifications"]),
            .init(question: "How does \(q) compare to its main alternatives or competitors, and what are the tradeoffs?",
                  rationale: "Deepening: situate the answer against comparables the draft alludes to but doesn't develop.",
                  suggestedQueries: ["\(q) vs alternatives", "\(q) comparison", "\(q) competitors"]),
            .init(question: "What is the history, timeline, and origin of \(q), and how did it reach its current state?",
                  rationale: "Deepening: add the historical/ecosystem context that frames the present.",
                  suggestedQueries: ["\(q) history", "\(q) timeline", "\(q) origin"]),
            .init(question: "What are the known failure modes, edge cases, risks, or unresolved problems with \(q)?",
                  rationale: "Deepening: probe where it breaks down rather than only where it works.",
                  suggestedQueries: ["\(q) problems", "\(q) failure cases", "\(q) risks"]),
            .init(question: "What do domain experts, primary documentation, or original authors say about \(q) (vs secondary commentary)?",
                  rationale: "Deepening: pull toward primary and expert sources for grounding.",
                  suggestedQueries: ["\(q) documentation", "\(q) expert analysis", "\(q) original paper"]),
            .init(question: "How is \(q) actually adopted or used in practice, and what real-world results or case studies exist?",
                  rationale: "Deepening: replace theory with concrete real-world evidence.",
                  suggestedQueries: ["\(q) case study", "\(q) real world results", "\(q) adoption"]),
            .init(question: "What future trends, roadmaps, or open research questions surround \(q)?",
                  rationale: "Deepening: extend the answer forward to where the topic is heading.",
                  suggestedQueries: ["\(q) future", "\(q) roadmap", "\(q) open problems"]),
        ]
        // round is the upcoming round (>= 2). Slide a 3-wide window; disjoint for
        // the first three reflection rounds, wrapping gracefully after that (a
        // wrapped repeat is filtered by the dispatched-set and the round ends).
        let base = max(0, round - 2) * 3
        return (0..<3).map { pool[(base + $0) % pool.count] }
    }
}
