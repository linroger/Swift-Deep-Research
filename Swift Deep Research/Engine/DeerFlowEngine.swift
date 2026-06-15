import Foundation

/// DeerFlow-style plan-and-execute research flow, adapted natively to this app
/// and augmented with the SeekDB private knowledge base.
///
/// Mirrors the LangGraph pipeline of bytedance/deer-flow:
///
///     background investigation (web search + knowledge base)
///     → planner (structured plan: title/thought/hasEnoughContext/steps)
///     → research team (steps executed SEQUENTIALLY, each step sees the
///       observations of every earlier step)
///     → re-plan loop (planner reviews observations; emits follow-up steps
///       or declares the context sufficient), up to N plan iterations
///     → reporter (final cited markdown synthesis)
///
/// Differences from the native `ResearchEngine` flow: steps run sequentially
/// with observation threading (DeerFlow's defining trait) instead of as a
/// parallel fan-out, and planning happens against an explicit background
/// investigation rather than from the bare query. The SeekDB augmentation
/// runs the knowledge base BOTH as a background-investigation source feeding
/// the planner and as the `knowledge_base` tool inside each research step.
///
/// Emits the exact same `ResearchEvent` stream as `ResearchEngine`, so the
/// UI, persistence, and follow-up conversation machinery work unchanged.
public struct DeerFlowEngine: Sendable {
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
                    (config.workerModel.map { " — \($0)" } ?? "") + " · DeerFlow"
                let session = SessionDescriptor(id: sessionID,
                                                query: query,
                                                providerName: providerName)
                let emit: @Sendable (ResearchEvent) -> Void = { event in
                    continuation.yield(event)
                }
                emit(.sessionStarted(session))

                do {
                    let orchestratorLLM = try await registry.makeClient(role: .orchestrator, config: config)
                    let workerLLM = try await registry.makeClient(role: .worker, config: config)
                    let synthesisLLM = try await registry.makeClient(role: .synthesis, config: config)
                    let synthesizer = Synthesizer(llm: synthesisLLM,
                                                  instructions: config.systemPromptAddendum)
                    let tools = await ResearchEngine.makeTools(cache: cache, config: config)

                    conversation.appendUserTurn(query)

                    // --- Stage 0: background investigation (web + knowledge base).
                    // DeerFlow grounds the planner in a quick first look at the
                    // landscape so the plan targets real gaps, not guesses.
                    let investigation = await Self.backgroundInvestigation(
                        query: query,
                        tools: tools,
                        config: config,
                        session: session,
                        budget: budget,
                        cache: cache,
                        emit: emit
                    )

                    var allOutputs: [WorkerOutput] = [investigation.asWorkerOutput]
                    var executedSubtasks: [ResearchPlan.Subtask] = []
                    var aggregatePlan: ResearchPlan?
                    // DeerFlow's max_plan_iterations, scaled by the iteration
                    // preset: fast = 1 (single plan), standard = 2, thorough = 3.
                    let maxPlanIterations = max(1, min(iteration.maxRounds, 3))
                    let maxSteps = max(1, min(4, config.budget.maxWorkers))
                    var planIteration = 0

                    planning: while planIteration < maxPlanIterations {
                        planIteration += 1
                        try Task.checkCancellation()
                        do {
                            try await budget.checkWallClock()
                        } catch {
                            emit(.reflectionConcluded(continuing: false, remainingGaps: 0))
                            break planning
                        }
                        emit(.iterationStarted(round: planIteration, of: maxPlanIterations))

                        let dfPlan = try await Self.plan(
                            llm: orchestratorLLM,
                            query: query,
                            investigation: planIteration == 1 ? investigation.markdown : "",
                            priorObservations: allOutputs.dropFirst().map(\.summary),
                            conversation: conversation,
                            knowledgeBaseDocs: investigation.knowledgeBaseDocTitles,
                            maxSteps: maxSteps,
                            instructions: config.systemPromptAddendum,
                            budget: budget,
                            isReplan: planIteration > 1
                        )

                        let newSubtasks = dfPlan.steps.map { step in
                            ResearchPlan.Subtask(
                                question: step.title,
                                rationale: step.description,
                                suggestedQueries: step.suggestedQueries
                            )
                        }
                        executedSubtasks.append(contentsOf: newSubtasks)
                        let plan = ResearchPlan(
                            userQuery: query,
                            restatement: dfPlan.thought.isEmpty ? dfPlan.title : dfPlan.thought,
                            strategy: .sequentialDrillDown,
                            subtasks: executedSubtasks,
                            estimatedComplexity: executedSubtasks.count > 2 ? .complex : .moderate,
                            estimatedTokenBudget: config.budget.maxTokens
                        )
                        aggregatePlan = plan
                        emit(.planEmitted(plan))

                        if dfPlan.hasEnoughContext || newSubtasks.isEmpty {
                            // Planner judged the gathered context sufficient —
                            // hand off to the reporter.
                            emit(.reflectionConcluded(continuing: false, remainingGaps: 0))
                            break planning
                        }

                        // --- Research team: execute the steps SEQUENTIALLY, each
                        // step building on the observations of the ones before it.
                        for (index, subtask) in newSubtasks.enumerated() {
                            try Task.checkCancellation()
                            do {
                                try await budget.checkWallClock()
                            } catch {
                                emit(.warning("Wall-clock budget reached — stopping after step \(index) of \(newSubtasks.count)."))
                                break planning
                            }
                            let stepKind = dfPlan.steps[index].stepType
                            let stepTools = stepKind == .processing
                                ? tools.filter { ["calculator", "current_datetime", "knowledge_base"].contains($0.spec.name) }
                                : tools
                            let observations = WorkerOutput.digest(of: allOutputs)
                            let worker = WorkerAgent(
                                id: WorkerID.make(subtask.question),
                                llm: workerLLM,
                                tools: stepTools,
                                session: session,
                                budget: budget,
                                cache: cache,
                                instructions: config.systemPromptAddendum,
                                sourceTarget: config.budget.maxSourcesPerWorker,
                                emit: emit
                            )
                            do {
                                let output = try await worker.run(subtask: subtask,
                                                                  parentQuery: query,
                                                                  extraContext: observations)
                                allOutputs.append(output)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                emit(.warning("Step \(index + 1) failed: \(error.localizedDescription)"))
                            }
                        }

                        if planIteration < maxPlanIterations {
                            // Tell the UI we're heading back to the planner with
                            // the new observations in hand.
                            emit(.reflectionStarted(round: planIteration))
                            emit(.reflectionConcluded(continuing: true, remainingGaps: 0))
                        }
                    }

                    // --- Reporter: synthesize the cited final report from every
                    // observation (background investigation + all steps).
                    let finalPlan = aggregatePlan ?? ResearchPlanJSON.fallback(query: query)
                    let draft = try await synthesizer.synthesize(
                        plan: finalPlan,
                        workerOutputs: allOutputs,
                        conversation: conversation,
                        budget: budget,
                        emit: emit
                    )

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

    // MARK: - Background investigation

    struct Investigation: Sendable {
        let workerID: WorkerID
        let markdown: String
        let sources: [FetchedSource]
        let knowledgeBaseDocTitles: [String]

        var asWorkerOutput: WorkerOutput {
            WorkerOutput(
                workerID: workerID,
                subtask: ResearchPlan.Subtask(
                    question: "Background investigation",
                    rationale: "Quick first look (web search + private knowledge base) that grounds the plan.",
                    suggestedQueries: []
                ),
                summary: markdown,
                sources: sources
            )
        }
    }

    /// Quick pre-planning sweep: one web search on the raw query plus, when the
    /// knowledge base is enabled, a semantic query against the user's private
    /// documents. Both run as a visible pseudo-worker so the activity log and
    /// source panel show where the planner's grounding came from.
    private static func backgroundInvestigation(query: String,
                                                tools: [any ResearchTool],
                                                config: EngineConfiguration,
                                                session: SessionDescriptor,
                                                budget: BudgetMeter,
                                                cache: SourceCache,
                                                emit: @escaping @Sendable (ResearchEvent) -> Void) async -> Investigation {
        let id = WorkerID(rawValue: "df-investigate-\(UUID().uuidString.prefix(6))")
        emit(.workerStarted(WorkerDescriptor(
            id: id,
            task: "Background investigation",
            rationale: "DeerFlow grounds the planner in a quick first look before committing to a plan."
        )))
        let context = ToolContext(
            workerID: id,
            session: session,
            emit: emit,
            charge: { tokens in try? await budget.chargeTokens(tokens) },
            budget: budget,
            cache: cache
        )

        var sections: [String] = []
        var sources: [FetchedSource] = []
        var kbDocTitles: [String] = []

        // Private knowledge base first — DeerFlow's RAG-resources precedence.
        if config.useKnowledgeBase {
            let kbClient = SeekDBClient(host: config.seekdbHost)
            if let docs = try? await kbClient.listDocuments() {
                kbDocTitles = docs.map(\.title)
            }
            if let kbTool = tools.first(where: { $0.spec.name == "knowledge_base" }) {
                let args = #"{"query": \#(LLMJSON.quoted(query)), "k": 6}"#
                let invocation = ToolInvocation(name: "knowledge_base", argumentsJSON: args)
                emit(.toolInvoked(id, invocation))
                let outcome: ToolOutcome
                do {
                    outcome = try await kbTool.call(argumentsJSON: args, context: context)
                } catch {
                    outcome = .failed(message: error.localizedDescription)
                }
                emit(.toolResult(id, invocation, outcome))
                if case .ok(let summary, let payload) = outcome {
                    sections.append("## Private knowledge base (\(summary))\n\(Clip.clip(payload, to: 6_000))")
                    sources.append(contentsOf: Self.decodeFetchedSources(payload))
                }
            }
        }

        // One broad web search on the raw query.
        if let search = tools.first(where: { $0.spec.name == "web_search" }) {
            let args = #"{"query": \#(LLMJSON.quoted(query))}"#
            let invocation = ToolInvocation(name: "web_search", argumentsJSON: args)
            emit(.toolInvoked(id, invocation))
            let outcome: ToolOutcome
            do {
                outcome = try await search.call(argumentsJSON: args, context: context)
            } catch {
                outcome = .failed(message: error.localizedDescription)
            }
            emit(.toolResult(id, invocation, outcome))
            if case .ok(let summary, let payload) = outcome {
                sections.append("## Web search (\(summary))\n\(Clip.clip(payload, to: 6_000))")
                // Turn the search hits into lightweight FetchedSources too. Without
                // this, the background sweep's web findings only lived in the
                // planner's markdown context and were never citable in the final
                // report — DeerFlow's whole point is a *cited* report, so a
                // short-circuiting query could rest entirely on uncitable snippets.
                sources.append(contentsOf: Self.decodeSearchAsSources(payload))
            }
        }

        let markdown = sections.isEmpty
            ? "No background results were available (search backends and knowledge base unreachable or empty)."
            : sections.joined(separator: "\n\n")
        emit(.workerCompleted(id, summary: Clip.clip(markdown, to: 200)))
        return Investigation(workerID: id,
                             markdown: markdown,
                             sources: sources,
                             knowledgeBaseDocTitles: kbDocTitles)
    }

    // MARK: - Planner

    struct DFStep: Sendable {
        enum StepType: String, Sendable { case research, processing }
        let title: String
        let description: String
        let stepType: StepType
        let suggestedQueries: [String]
    }

    struct DFPlan: Sendable {
        let title: String
        let thought: String
        let hasEnoughContext: Bool
        let steps: [DFStep]
    }

    private static let planSchema = #"""
    {
      "type": "object",
      "required": ["title", "thought", "hasEnoughContext", "steps"],
      "properties": {
        "title": { "type": "string", "description": "Title for the research." },
        "thought": { "type": "string", "description": "Your reasoning about what the user needs and how the steps cover it." },
        "hasEnoughContext": { "type": "boolean", "description": "true ONLY if the already-gathered context fully answers the question — then steps must be []." },
        "steps": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["title", "description", "stepType"],
            "properties": {
              "title": { "type": "string", "description": "Short imperative step name." },
              "description": { "type": "string", "description": "Exactly what data to collect or compute, and why." },
              "stepType": { "type": "string", "enum": ["research", "processing"] },
              "suggestedQueries": { "type": "array", "items": { "type": "string" } }
            }
          }
        }
      }
    }
    """#

    private struct DFPlanWire: Decodable {
        let title: String?
        let thought: String?
        let hasEnoughContext: Bool?
        let steps: [StepWire]?
        struct StepWire: Decodable {
            let title: String
            let description: String?
            let stepType: String?
            let suggestedQueries: [String]?
        }
    }

    private static func plan(llm: any LLMClient,
                             query: String,
                             investigation: String,
                             priorObservations: [String],
                             conversation: ConversationContext,
                             knowledgeBaseDocs: [String],
                             maxSteps: Int,
                             instructions: String,
                             budget: BudgetMeter,
                             isReplan: Bool) async throws -> DFPlan {
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendix = extra.isEmpty ? "" : "\n\n# User instructions (honor unless they conflict with safety)\n\(extra)"
        let kbNote = knowledgeBaseDocs.isEmpty ? "" : """

        # Private knowledge base resources
        The user has uploaded private documents the research steps can search with the \
        `knowledge_base` tool: \(knowledgeBaseDocs.prefix(20).joined(separator: " | ")). \
        When a step may be answered by these documents, say so in its description and \
        instruct the researcher to query the knowledge base FIRST, then corroborate on the web.
        """
        let system = """
        You are a professional Deep Research planner following the DeerFlow methodology. \
        Study the question and the context gathered so far, then either declare the context \
        sufficient or plan the research steps that will close the remaining gaps.\(kbNote)

        # Context assessment — be STRICT
        Set "hasEnoughContext": true ONLY when the gathered information already answers every \
        aspect of the question with reliable, current, mutually consistent sources. When in \
        doubt, plan more research. If true, "steps" MUST be [].

        # Step rules
        - At most \(maxSteps) steps; each step gathers ONE distinct slice of the answer.
        - "research" steps search and read (web, papers, the private knowledge base).
        - "processing" steps compute or analyze data the earlier steps already gathered \
          (calculations, comparisons, tabulations) — they do not search.
        - Steps run in order and each one sees all earlier findings, so later steps may \
          depend on earlier results.
        - Each step's description must say exactly what data to collect and why.

        Reply with JSON ONLY matching this schema:
        \(planSchema)\(appendix)
        """
        let observationBlock = priorObservations.isEmpty ? "" : """

        # Findings from the steps executed so far
        \(priorObservations.enumerated().map { "## Step \($0.offset + 1) findings\n\(Clip.clip($0.element, to: 2_500))" }.joined(separator: "\n\n"))
        """
        let investigationBlock = investigation.isEmpty ? "" : """

        # Background investigation
        \(Clip.clip(investigation, to: 8_000))
        """
        let replanNote = isReplan ? """

        The steps above already ran. Decide whether their findings make the context \
        sufficient. If not, plan ONLY the additional steps still needed (do not repeat \
        completed work).
        """ : ""
        let user = """
        User question: \(query)
        \(conversation.plannerPreamble())\(investigationBlock)\(observationBlock)\(replanNote)
        """
        let req = LLMRequest(messages: [.system(system), .user(user)], temperature: 0.2)
        let completion = try await RetryPolicy.networkDefault.run({
            try await llm.complete(req)
        }, label: "deerflow-planner")
        try? await budget.chargeTokens(completion.totalTokens)

        let json = LLMJSON.extractObject(completion.text)
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(DFPlanWire.self, from: data) else {
            Log.engine.warning("DeerFlow planner JSON parse failed; falling back to a single direct step. Raw: \(completion.text, privacy: .public)")
            return DFPlan(
                title: query,
                thought: "Planner output could not be parsed — researching the question directly.",
                hasEnoughContext: false,
                steps: isReplan ? [] : [DFStep(title: query,
                                               description: "Research the user's question directly.",
                                               stepType: .research,
                                               suggestedQueries: [query])]
            )
        }
        let steps = (wire.steps ?? []).prefix(maxSteps).map { s in
            DFStep(title: s.title,
                   description: s.description ?? "",
                   stepType: DFStep.StepType(rawValue: s.stepType ?? "research") ?? .research,
                   suggestedQueries: s.suggestedQueries ?? [])
        }
        return DFPlan(title: wire.title ?? query,
                      thought: wire.thought ?? "",
                      hasEnoughContext: wire.hasEnoughContext ?? false,
                      steps: Array(steps))
    }

    // MARK: - Helpers

    /// Digest of everything found so far, threaded into the next step's prompt.
    /// Clipped per-step so a long run doesn't blow the context window.
    private static func decodeFetchedSources(_ payload: String) -> [FetchedSource] {
        guard let data = payload.data(using: .utf8) else { return [] }
        struct Envelope: Decodable { let fetchedSources: [FetchedSource]? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.fetchedSources ?? []
    }

    /// Decode a `web_search` payload into lightweight `FetchedSource`s (snippet as
    /// extractedText) so the background sweep's web hits are citable. The id is
    /// the URL string, so a later `fetch_url` of the same URL upserts richer text
    /// under the same identity rather than duplicating the source.
    private static func decodeSearchAsSources(_ payload: String) -> [FetchedSource] {
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SearchResultsPayload.self, from: data) else { return [] }
        return parsed.results.map { r in
            FetchedSource(id: r.url.absoluteString,
                          url: r.url,
                          title: r.title,
                          extractedText: r.snippet ?? r.title,
                          strategy: .staticHTML)
        }
    }


    /// JSON-escape a string (with surrounding quotes) for tool arguments.
}
