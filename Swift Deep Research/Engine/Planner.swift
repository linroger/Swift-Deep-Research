import Foundation

/// Stage 1 — turn the user query into a `ResearchPlan`.
/// Uses the lightweight orchestrator LLM and asks for strict JSON output.
/// When a `ConversationContext` is supplied (follow-up turns), the planner
/// also sees prior turns and known domains so it doesn't duplicate work.
public struct Planner: Sendable {
    public let llm: any LLMClient
    public let retry: RetryPolicy
    public let instructions: String
    public let knowledgeBaseAvailable: Bool

    public init(llm: any LLMClient,
                instructions: String = "",
                knowledgeBaseAvailable: Bool = false,
                retry: RetryPolicy = .networkDefault) {
        self.llm = llm
        self.instructions = instructions
        self.knowledgeBaseAvailable = knowledgeBaseAvailable
        self.retry = retry
    }

    public func plan(query: String,
                     context: ConversationContext = ConversationContext()) async throws -> ResearchPlan {
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendix = extra.isEmpty ? "" : "\n\n# User instructions (honor unless they conflict with safety)\n\(extra)"
        let kbHint = knowledgeBaseAvailable
            ? "\n\nThe user has uploaded private documents to a vector knowledge base. When the question may already be answered by their materials, tell workers to call `knowledge_base` FIRST before web search."
            : ""
        let system = """
        You are the planning brain of a deep-research agent. Your job is to take the
        user's question and decompose it into 1–4 independent sub-tasks that worker
        agents can research in parallel.\(kbHint)

        Choose strategy:
        - "direct" — tiny lookups solvable with one search.
        - "parallelDecomposition" — typical multi-aspect questions.
        - "sequentialDrillDown" — later questions depend on earlier results.
        - "comparative" — comparing distinct entities (X vs Y vs Z).

        Each subtask should:
        - Be answerable by a small focused set of web searches and reads.
        - Be independent of the others when possible (so they run in parallel).
        - Carry 1–3 suggested queries that prime the worker.
        - Have a rationale tying it back to what the user actually asked for.

        Reply with JSON ONLY matching this schema:
        \(ResearchPlanJSON.schema)\(appendix)
        """
        let user = """
        User question: \(query)
        \(context.plannerPreamble())
        """
        // No artificial maxTokens cap — let the model use its full output
        // budget. Plans almost never run long, but we don't want to
        // accidentally truncate a strategy on complex prompts.
        let req = LLMRequest(
            messages: [.system(system), .user(user)],
            temperature: 0.2
        )
        let completion = try await retry.run({
            try await llm.complete(req)
        }, label: "planner")

        let json = Self.extractJSON(completion.text)
        do {
            return try ResearchPlanJSON.decode(json, userQuery: query)
        } catch {
            Log.engine.warning("Planner JSON parse failed; using fallback. Raw: \(completion.text, privacy: .public)")
            return ResearchPlanJSON.fallback(query: query)
        }
    }

    private static func extractJSON(_ text: String) -> String {
        var s = text
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
            s = s.replacingOccurrences(of: "```", with: "")
        }
        if let first = s.firstIndex(of: "{"), let last = s.lastIndex(of: "}") {
            return String(s[first...last])
        }
        return s
    }
}
