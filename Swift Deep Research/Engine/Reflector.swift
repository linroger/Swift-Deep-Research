import Foundation

/// Reads the current draft + worker findings and decides what the next round
/// of research should explore. This is the "agent loop" step that
/// distinguishes a deep-research agent from a one-shot RAG pipeline.
///
/// Two modes:
/// - **gapFinding** (rounds 2-3): hunt for unanswered sub-questions, missing
///   comparisons, claims with no source backing.
/// - **deepening** (rounds 4+): when the draft already covers the obvious
///   ground, push outward — adjacent angles, cross-verification, contrasts,
///   counter-evidence, deeper technical specifics, timeline / ecosystem
///   context. This is what keeps later rounds substantive instead of
///   short-circuiting on a "ready" verdict.
///
/// Output is a `Critique`. `verdict` is advisory: the engine always runs the
/// configured number of rounds, falling back to synthesized deepening
/// subtasks if the reflector returns nothing.
public struct Reflector: Sendable {
    public let llm: any LLMClient

    public init(llm: any LLMClient) {
        self.llm = llm
    }

    public enum Mode: Sendable {
        case gapFinding
        case deepening
    }

    public func critique(query: String,
                         plan: ResearchPlan,
                         workerOutputs: [WorkerOutput],
                         draft: String,
                         mode: Mode = .gapFinding,
                         minSubtasks: Int = 3,
                         maxSubtasks: Int = 6) async throws -> Critique {
        let workerSection = workerOutputs.map { o in
            "- **\(o.subtask.question)** → \(Clip.clip(o.summary, to: 800))"
        }.joined(separator: "\n")
        let sourceURLs = workerOutputs.flatMap(\.sources).map(\.url.absoluteString)
            .prefix(40).joined(separator: "\n- ")
        let alreadyAsked = plan.subtasks.map { "- \($0.question)" }.joined(separator: "\n")

        let system: String
        switch mode {
        case .gapFinding:
            system = """
            You are an editorial critic for a deep-research agent. Your job is NOT
            to write the answer — it is to identify what specific follow-up research
            is still needed.

            Be ruthless. Look for:
            - Claims with no source backing.
            - Sub-questions implied by the user that nobody investigated.
            - Comparisons asked for but not made.
            - Numbers/dates/names that need verification.
            - Stale information when the topic is fast-moving.
            - Single-sourced claims that deserve cross-checking.

            Return between \(minSubtasks) and \(maxSubtasks) concrete, search-friendly
            follow-up questions in the `gaps` array. Each must materially advance
            the answer. Do not repeat any question already in "Previously asked".

            Return JSON ONLY in this shape:
            \(JSONSchema.schema)
            """
        case .deepening:
            system = """
            You are an editorial critic for a deep-research agent in DEEPENING mode.
            The draft already covers the obvious ground. Your job is to push the
            research outward, not inward.

            Generate \(minSubtasks)–\(maxSubtasks) NEW research directions that:
            - Cross-verify the most load-bearing claims against independent sources.
            - Explore adjacent or related topics the answer alludes to but
              doesn't develop (ecosystem, timeline, comparables, history).
            - Dig into technical specifics that the current draft summarises
              shallowly.
            - Surface contrarian views, criticisms, or known failure modes.
            - Find the most recent updates (last 30–90 days) if the topic moves fast.
            - Identify quantitative benchmarks, datasets, or numbers that would
              sharpen the answer.

            Each question must be fresh: do NOT restate or paraphrase any item
            already in "Previously asked". Keep questions concrete and
            search-friendly.

            Return JSON ONLY in this shape:
            \(JSONSchema.schema)
            """
        }
        let user = """
        # User question
        \(query)

        # Plan strategy
        \(plan.strategy.rawValue) — \(plan.subtasks.count) subtasks so far

        # Previously asked
        \(alreadyAsked)

        # Worker findings
        \(workerSection)

        # Sources gathered (\(workerOutputs.flatMap(\.sources).count) total)
        - \(sourceURLs)

        # Current draft
        \(Clip.clip(draft, to: 8000))
        """
        let req = LLMRequest(
            messages: [.system(system), .user(user)],
            temperature: mode == .deepening ? 0.5 : 0.2
        )
        let completion = try await llm.complete(req)
        let json = JSONSchema.extract(from: completion.text)
        do {
            let wire = try JSONDecoder().decode(JSONSchema.Wire.self,
                                                from: json.data(using: .utf8) ?? Data())
            let verdict = Critique.Verdict(rawValue: wire.verdict) ?? .ready
            return Critique(
                verdict: verdict,
                rationale: wire.rationale,
                gaps: wire.gaps.map { Critique.Gap(question: $0.question, rationale: $0.rationale) },
                unsupportedClaims: wire.unsupportedClaims,
                suggestedRefinements: wire.suggestedRefinements
            )
        } catch {
            Log.engine.warning("Reflector parse failed: \(error.localizedDescription, privacy: .public). Returning empty critique.")
            return Critique(verdict: .ready,
                           rationale: "Reflector output unparseable.",
                           gaps: [], unsupportedClaims: [], suggestedRefinements: [])
        }
    }

    public struct Critique: Sendable, Codable {
        public let verdict: Verdict
        public let rationale: String
        public let gaps: [Gap]
        public let unsupportedClaims: [String]
        public let suggestedRefinements: [String]

        public enum Verdict: String, Sendable, Codable {
            case ready
            case needsMoreResearch = "needs_more_research"
            case needsClarification = "needs_clarification"
        }

        public struct Gap: Sendable, Codable {
            public let question: String
            public let rationale: String
        }

        /// Convert gaps into ResearchPlan subtasks so the orchestrator can fan
        /// out a follow-up round.
        public func subtasks() -> [ResearchPlan.Subtask] {
            gaps.map { gap in
                ResearchPlan.Subtask(
                    question: gap.question,
                    rationale: gap.rationale,
                    suggestedQueries: [gap.question]
                )
            }
        }
    }

    public enum JSONSchema {
        static let schema = #"""
        {
          "type": "object",
          "required": ["verdict", "rationale", "gaps", "unsupportedClaims", "suggestedRefinements"],
          "properties": {
            "verdict": { "type": "string", "enum": ["ready", "needs_more_research", "needs_clarification"] },
            "rationale": { "type": "string" },
            "gaps": {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["question", "rationale"],
                "properties": {
                  "question": { "type": "string" },
                  "rationale": { "type": "string" }
                }
              }
            },
            "unsupportedClaims": { "type": "array", "items": { "type": "string" } },
            "suggestedRefinements": { "type": "array", "items": { "type": "string" } }
          }
        }
        """#

        struct Wire: Decodable {
            let verdict: String
            let rationale: String
            let gaps: [WireGap]
            let unsupportedClaims: [String]
            let suggestedRefinements: [String]
        }

        struct WireGap: Decodable {
            let question: String
            let rationale: String
        }

        static func extract(from text: String) -> String {
            var s = text.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
            if let first = s.firstIndex(of: "{"), let last = s.lastIndex(of: "}") {
                s = String(s[first...last])
            }
            return s
        }
    }
}
