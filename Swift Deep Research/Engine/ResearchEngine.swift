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
        let registry = self.registry
        let config = self.config
        let iteration = self.iteration
        return AsyncThrowingStream<ResearchEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                let start = ContinuousClock().now
                let budget = BudgetMeter(budget: config.budget)
                let cache = SourceCache()
                var conversation = context
                let providerName = config.workerProvider.displayName +
                    (config.workerModel.map { " — \($0)" } ?? "")
                let session = SessionDescriptor(id: sessionID,
                                               query: query,
                                               providerName: providerName)

                let emit: @Sendable (ResearchEvent) -> Void = { event in
                    continuation.yield(event)
                }
                emit(.sessionStarted(session))

                do {
                    let orchestratorLLM = try await registry.makeClient(
                        provider: config.orchestratorProvider,
                        model: config.orchestratorModel,
                        ollamaHost: config.ollamaHost,
                        lmStudioHost: config.lmStudioHost,
                        customBaseURL: config.customEndpointBaseURL
                    )
                    let workerLLM = try await registry.makeClient(
                        provider: config.workerProvider,
                        model: config.workerModel,
                        ollamaHost: config.ollamaHost,
                        lmStudioHost: config.lmStudioHost,
                        customBaseURL: config.customEndpointBaseURL
                    )
                    let synthesisLLM = try await registry.makeClient(
                        provider: config.synthesisProvider,
                        model: config.synthesisModel,
                        ollamaHost: config.ollamaHost,
                        lmStudioHost: config.lmStudioHost,
                        customBaseURL: config.customEndpointBaseURL
                    )

                    let planner = Planner(llm: orchestratorLLM,
                                          instructions: config.systemPromptAddendum,
                                          knowledgeBaseAvailable: config.useKnowledgeBase)
                    let synthesizer = Synthesizer(llm: synthesisLLM,
                                                  instructions: config.systemPromptAddendum)
                    let reflector = Reflector(llm: orchestratorLLM)

                    let tools = await Self.makeTools(cache: cache, config: config)
                    let perWorkerSourceTarget = config.budget.maxSourcesPerWorker

                    // --- Round 1: initial plan + workers + synthesis
                    conversation.appendUserTurn(query)
                    emit(.iterationStarted(round: 1, of: iteration.maxRounds))

                    var plan = try await planner.plan(query: query, context: conversation)
                    emit(.planEmitted(plan))

                    var accumulatedOutputs: [WorkerOutput] = []
                    let firstRound = try await Self.runWorkers(
                        subtasks: Array(plan.subtasks.prefix(config.budget.maxWorkers)),
                        parentQuery: query,
                        workerLLM: workerLLM,
                        tools: tools,
                        session: session,
                        budget: budget,
                        cache: cache,
                        instructions: config.systemPromptAddendum,
                        sourceTarget: perWorkerSourceTarget,
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
                        var round = 1
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

                            emit(.reflectionStarted(round: round))
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
                            // from being a no-op.
                            if newSubtasks.isEmpty {
                                newSubtasks = Self.synthesizeDeepeningSubtasks(
                                    plan: plan,
                                    workerOutputs: accumulatedOutputs,
                                    round: round + 1
                                )
                            }
                            // Drop duplicates of questions already explored.
                            let asked = Set(plan.subtasks.map { $0.question.lowercased() })
                            newSubtasks = newSubtasks.filter { !asked.contains($0.question.lowercased()) }
                            if newSubtasks.isEmpty {
                                // Genuinely nothing new to ask — end the loop
                                // gracefully rather than spin.
                                emit(.reflectionConcluded(continuing: false, remainingGaps: 0))
                                break
                            }

                            round += 1
                            emit(.reflectionConcluded(continuing: true, remainingGaps: newSubtasks.count))
                            emit(.iterationStarted(round: round, of: iteration.maxRounds))

                            plan = ResearchPlan(
                                userQuery: plan.userQuery,
                                restatement: plan.restatement,
                                strategy: plan.strategy,
                                subtasks: plan.subtasks + newSubtasks,
                                estimatedComplexity: plan.estimatedComplexity,
                                estimatedTokenBudget: plan.estimatedTokenBudget
                            )
                            let refinementOutputs = try await Self.runWorkers(
                                subtasks: Array(newSubtasks.prefix(config.budget.maxWorkers)),
                                parentQuery: query,
                                workerLLM: workerLLM,
                                tools: tools,
                                session: session,
                                budget: budget,
                                cache: cache,
                                instructions: config.systemPromptAddendum,
                                sourceTarget: perWorkerSourceTarget,
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
                    emit(.error(failure))
                    continuation.finish(throwing: failure)
                } catch {
                    let wrapped = EngineFailure(kind: .unknown,
                                                message: error.localizedDescription,
                                                underlying: String(describing: error))
                    emit(.error(wrapped))
                    continuation.finish(throwing: wrapped)
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
                                   emit: @escaping @Sendable (ResearchEvent) -> Void) async throws -> [WorkerOutput] {
        try await withThrowingTaskGroup(of: WorkerOutput.self) { group in
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
                group.addTask { try await worker.run(subtask: subtask, parentQuery: parentQuery) }
            }
            var outs: [WorkerOutput] = []
            for try await out in group { outs.append(out) }
            return outs
        }
    }

    private static func makeTools(cache: SourceCache,
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
    /// deterministically from the existing plan + worker outputs so we never
    /// blow a round on an empty critique. Targets the three angles a deep
    /// research analyst typically opens up next: cross-verification,
    /// quantitative specifics, and adjacent context.
    private static func synthesizeDeepeningSubtasks(plan: ResearchPlan,
                                                    workerOutputs: [WorkerOutput],
                                                    round: Int) -> [ResearchPlan.Subtask] {
        let userQuery = plan.userQuery
        return [
            ResearchPlan.Subtask(
                question: "What are the most recent (last 30-90 days) updates, releases, or developments related to: \(userQuery)?",
                rationale: "Engine-injected deepening round \(round): keep the answer current; the original plan may miss late-breaking information.",
                suggestedQueries: [
                    "\(userQuery) latest update",
                    "\(userQuery) news 2026",
                    "\(userQuery) recent release"
                ]
            ),
            ResearchPlan.Subtask(
                question: "Find independent or contrarian sources that critique, contradict, or qualify the main claims so far about: \(userQuery).",
                rationale: "Engine-injected deepening round \(round): cross-verify load-bearing claims and surface counter-evidence.",
                suggestedQueries: [
                    "\(userQuery) criticism",
                    "\(userQuery) limitations",
                    "\(userQuery) benchmark comparison"
                ]
            ),
            ResearchPlan.Subtask(
                question: "What technical specifics, exact numbers, benchmarks, datasets, or quantitative comparisons would sharpen the analysis of: \(userQuery)?",
                rationale: "Engine-injected deepening round \(round): replace generic descriptions with hard numbers.",
                suggestedQueries: [
                    "\(userQuery) benchmark",
                    "\(userQuery) performance numbers",
                    "\(userQuery) technical specifications"
                ]
            )
        ]
    }
}
