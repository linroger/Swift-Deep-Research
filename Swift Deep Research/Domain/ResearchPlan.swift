import Foundation

/// What the orchestrator emits after decomposing the user query.
///
/// `ResearchPlan` is the contract between the orchestrator's planner stage
/// and the worker fan-out stage. It is *also* the structured-output shape
/// the planner LLM is asked to emit, so it must be JSON-clean and total.
public struct ResearchPlan: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let userQuery: String
    public let restatement: String
    public let strategy: Strategy
    public let subtasks: [Subtask]
    public let estimatedComplexity: Complexity
    public let estimatedTokenBudget: Int
    public let producedAt: Date

    public init(id: UUID = UUID(),
                userQuery: String,
                restatement: String,
                strategy: Strategy,
                subtasks: [Subtask],
                estimatedComplexity: Complexity,
                estimatedTokenBudget: Int,
                producedAt: Date = .now) {
        self.id = id
        self.userQuery = userQuery
        self.restatement = restatement
        self.strategy = strategy
        self.subtasks = subtasks
        self.estimatedComplexity = estimatedComplexity
        self.estimatedTokenBudget = estimatedTokenBudget
        self.producedAt = producedAt
    }

    public enum Strategy: String, Sendable, Codable {
        /// Direct answer from one or two searches — small queries.
        case direct
        /// Parallel decomposition into independent sub-questions — typical case.
        case parallelDecomposition
        /// Sequential drill-down where later sub-questions depend on earlier results.
        case sequentialDrillDown
        /// Comparative analysis across multiple entities (e.g. "compare A vs B vs C").
        case comparative
    }

    public enum Complexity: String, Sendable, Codable, CaseIterable, Comparable {
        case trivial, moderate, complex, expansive

        public static func < (lhs: Complexity, rhs: Complexity) -> Bool {
            let order: [Complexity] = [.trivial, .moderate, .complex, .expansive]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public struct Subtask: Sendable, Codable, Identifiable, Equatable {
        public let id: UUID
        public let question: String
        public let rationale: String
        public let suggestedQueries: [String]
        public let dependsOn: [UUID]

        public init(id: UUID = UUID(),
                    question: String,
                    rationale: String,
                    suggestedQueries: [String],
                    dependsOn: [UUID] = []) {
            self.id = id
            self.question = question
            self.rationale = rationale
            self.suggestedQueries = suggestedQueries
            self.dependsOn = dependsOn
        }
    }
}

/// JSON schema for prompting LLMs to emit a `ResearchPlan`.
///
/// We don't rely on provider-specific structured-output APIs because providers
/// disagree on the schema dialect. Instead we instruct the model to emit
/// matching JSON and parse it ourselves. This is robust across all 5 cloud
/// providers and Foundation Models (via `@Generable` later if available).
public enum ResearchPlanJSON {
    public static let schema = #"""
    {
      "type": "object",
      "required": ["restatement", "strategy", "subtasks", "estimatedComplexity", "estimatedTokenBudget"],
      "properties": {
        "restatement": { "type": "string", "description": "Restate the user query in your own words." },
        "strategy": {
          "type": "string",
          "enum": ["direct", "parallelDecomposition", "sequentialDrillDown", "comparative"]
        },
        "subtasks": {
          "type": "array",
          "minItems": 1,
          "maxItems": 6,
          "items": {
            "type": "object",
            "required": ["question", "rationale", "suggestedQueries"],
            "properties": {
              "question": { "type": "string" },
              "rationale": { "type": "string" },
              "suggestedQueries": { "type": "array", "items": { "type": "string" } }
            }
          }
        },
        "estimatedComplexity": { "type": "string", "enum": ["trivial", "moderate", "complex", "expansive"] },
        "estimatedTokenBudget": { "type": "integer", "minimum": 1000, "maximum": 500000 }
      }
    }
    """#

    /// Wire format the planner LLM emits; we map it onto `ResearchPlan`.
    public struct Wire: Codable, Sendable {
        public let restatement: String
        public let strategy: String
        public let subtasks: [WireSubtask]
        public let estimatedComplexity: String
        public let estimatedTokenBudget: Int
    }

    public struct WireSubtask: Codable, Sendable {
        public let question: String
        public let rationale: String
        public let suggestedQueries: [String]
    }

    public static func decode(_ json: String, userQuery: String) throws -> ResearchPlan {
        guard let data = json.data(using: .utf8) else {
            throw EngineFailure(kind: .planningFailed, message: "Plan JSON not UTF-8")
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw EngineFailure(kind: .planningFailed,
                                message: "Plan JSON did not match schema",
                                underlying: error.localizedDescription)
        }
        let strategy = ResearchPlan.Strategy(rawValue: wire.strategy) ?? .parallelDecomposition
        let complexity = ResearchPlan.Complexity(rawValue: wire.estimatedComplexity) ?? .moderate
        let subtasks = wire.subtasks.map {
            ResearchPlan.Subtask(question: $0.question,
                                 rationale: $0.rationale,
                                 suggestedQueries: $0.suggestedQueries)
        }
        // Schema-valid JSON can still be degenerate: an empty `"subtasks": []`
        // (the schema's minItems is advisory to the LLM, not enforced by our
        // decoder) or subtasks whose questions are all blank/whitespace yield a
        // plan no worker can act on. Fall back to the single-subtask direct plan
        // so the run still produces grounded output instead of fanning out zero
        // workers (engine-empty-planner-output).
        let hasActionableSubtask = subtasks.contains {
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasActionableSubtask else {
            return ResearchPlanJSON.fallback(query: userQuery)
        }
        return ResearchPlan(
            userQuery: userQuery,
            restatement: wire.restatement,
            strategy: strategy,
            subtasks: subtasks,
            estimatedComplexity: complexity,
            estimatedTokenBudget: wire.estimatedTokenBudget
        )
    }

    /// A bare-minimum fallback plan used when planner output can't be parsed.
    public static func fallback(query: String) -> ResearchPlan {
        ResearchPlan(
            userQuery: query,
            restatement: query,
            strategy: .direct,
            subtasks: [
                .init(question: query,
                      rationale: "Direct search; planner output unavailable.",
                      suggestedQueries: [query])
            ],
            estimatedComplexity: .moderate,
            estimatedTokenBudget: 50_000
        )
    }
}
