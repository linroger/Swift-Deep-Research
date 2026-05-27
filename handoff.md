# Handoff.md — Swift Deep Research v2 Rebuild

**Last Updated (UTC):** 2026-05-25T09:58Z
**Status:** In Progress
**Current Focus:** Robustness pass for provider tool-calling, knowledge-base evidence flow, and document ingestion.

## 1) Request & Context
- **User's request:** "Read through this project recursively. Research deep research agents and their architectures. The purpose of this app is to build a deep research agent using the most up-to-date frameworks and in Swift. This app in its current state needs a complete overhaul, and to be rebuilt from the ground up to be more powerful and advanced. Make a plan and execute on it."
- **Operational constraints / environment:**
  - macOS development on Apple Silicon (`darwin 25.5.0`)
  - Xcode 26.x available (user is on macOS Tahoe development track)
  - In-place rebuild of existing `Swift Deep Research.xcodeproj` (keep identity, history, screenshots)
- **Guidelines / preferences to honor (from AskUserQuestion):**
  - **Deployment target:** macOS 26 (Tahoe) — unlock Foundation Models, Liquid Glass, Swift 6.2 default actor isolation
  - **LLM providers:** Anthropic (Claude Sonnet 4, Opus 4.1), OpenAI (gpt-5.5 family), Gemini (3 Pro Preview, 3 Flash Preview, 2.5 Pro), Ollama, MLX, Foundation Models
  - **Rebuild strategy:** in-place — replace internals, keep `.xcodeproj`
  - **Architecture (from prior research, decision #5349):** orchestrator-worker mirroring Anthropic's pattern; Foundation Models as on-device orchestrator brain; cloud LLMs for long-context synthesis; MCP-Swift for dynamic tool extension; actor-per-session + TaskGroup fan-out; SwiftData persistence; AsyncThrowingStream event bus; Liquid Glass UI
- **Scope boundaries (non-goals for v2.0):**
  - Not building a backend service — pure on-device app
  - Not shipping MCP server discovery UI in v2.0 (client-side only)
  - Not handling video/image research sources in v2.0 (text only)
  - Not building offline-only mode in v2.0 (cloud providers assumed available when picked)
- **Changes since start (dated deltas):**
- 2026-05-24: Initial handoff created; tasks #1–#10 enqueued.
- 2026-05-25: Current session explicitly avoids building because package dependencies have not been fetched. Verification is limited to recursive code/document reading, current architecture research, static plist/JSON/Python checks, and focused source review.

## 2) Requirements → Acceptance Checks (traceable)

| ID | Requirement | Acceptance Check | Expected Outcome | Evidence |
|---|---|---|---|---|
| R1 | macOS 26 / Swift 6.2 strict concurrency build clean | `xcodebuild build` from CLI with `SWIFT_STRICT_CONCURRENCY=complete` | Zero errors, zero data-race warnings | Build log saved to `logs/build-<ts>.log` |
| R2 | Multi-provider LLM abstraction | Settings → switch provider → run query | All 6 providers selectable; each routes correctly | Screenshot of settings + successful query per provider |
| R3 | Orchestrator-worker decomposition | Submit complex query | App emits Plan event with ≥2 sub-tasks, then fans them out in parallel | Console log shows `TaskGroup.addTask` per worker |
| R4 | Real-time streaming UX | Submit query | Tokens stream into UI with `withAnimation`; reasoning groups collapsible | Screen recording of streaming behavior |
| R5 | Source citations with snippets | Complete a research run | Final draft has ≥3 citation chips; clicking opens source URL | Screenshot of cited draft |
| R6 | SwiftData persistence survives relaunch | Run query → quit → relaunch | Session reappears in sidebar with full transcript and sources | Screenshot before/after |
| R7 | Keychain-backed API key storage | Enter API key → quit → relaunch | Key persists; `defaults read` shows no plaintext | `security find-generic-password` output |
| R8 | Web reader handles JS-rendered SPAs | Research a Next.js / React site | `WKWebView` fallback extracts content static parser missed | Diff log of two extractor outputs |
| R9 | Foundation Models orchestrator path works | Submit query while on macOS 26 | FM emits structured `ResearchPlan` via `@Generable` | Console log of decoded plan |
| R10 | Liquid Glass adoption on key surfaces | Visual inspection | Toolbar, source cards, settings sheet use `.glassEffect()` / `Glass*` views | Screenshot pre/post |

## 3) Plan & Decomposition (with rationale)

**Critical-path narrative.** The rewrite is gated by (a) project config bump (everything fails to compile until macOS 26 / Swift 6.2 is set) and (b) the unified provider protocol (orchestrator can't be tested without ≥1 working provider). Build outward from those two foundations.

- **Step 1 — Planning artifacts (Task #1).** Create handoff.md, feature_list.json, agent-progress.txt so future sessions can resume cold.
- **Step 2 — Project config bump (Task #2).** Edit `project.pbxproj`. Add SwiftPM deps. Without this, nothing else compiles.
- **Step 3 — Core domain types (Task #3).** Sendable event types, errors, plan structures. All other modules depend on these.
- **Step 4 — SwiftData layer (Task #4).** `@Model` for ResearchSession/Source/Citation. Replaces UserDefaults-based managers.
- **Step 5 — Providers (Task #5).** Unified protocol + 6 implementations. Anthropic first (most mature SDK), Foundation Models second (free on-device baseline), then OpenAI/Gemini/Ollama/MLX.
- **Step 6 — Tools (Task #6).** Search (Tavily/Exa/Brave/DDG fallback chain), web reader (SwiftSoup + WKWebView), citation extractor. Tools are tested via direct invocation before orchestrator wiring.
- **Step 7 — Orchestrator (Task #7).** Actor coordinating plan → workers → synthesis. Emits `AsyncThrowingStream<ResearchEvent>`.
- **Step 8 — SwiftUI views (Task #8).** Three-pane Liquid Glass layout consuming the event stream.
- **Step 9 — Wire entry + delete legacy (Task #9).** New `Swift_Deep_ResearchApp.swift`. Remove old Agent/ChatViewModel/etc.
- **Step 10 — Build & validate (Task #10).** `xcodebuild`, fix errors, smoke test.

## 4) To-Do & Progress Ledger
- [x] T1 — Planning artifacts (handoff.md, feature_list.json, agent-progress.txt) — **done**
- [x] T2 — Bump project to macOS 26 + Swift 6.2 + strict concurrency — **done** (Xcode 26.3 + macOS 26.2 SDK verified)
- [x] T3 — Core/ Sendable domain types — **done** (`Domain/ResearchEvent.swift`, `ResearchPlan.swift`, `Message.swift`, `AgentBudget.swift`)
- [x] T4 — Persistence/ SwiftData @Model layer — **done** (`Storage/ResearchSchema.swift`, `ResearchStore.swift`)
- [x] T5 — Providers/ unified LLM module — **done** (`LLM/` — protocol + 6 clients + registry + SSE parser)
- [x] T6 — Tools/ search + reader + citation — **done** (`ResearchTools/` — Tavily/Exa/Brave/DDG search, SwiftSoup+WKWebView reader, citation extractor)
- [x] T7 — Orchestrator/ actor-based engine — **done** (`Engine/` — Planner → WorkerAgent fan-out → Synthesizer, all via `AsyncThrowingStream<ResearchEvent>`)
- [x] T8 — Views/ Liquid Glass SwiftUI rebuild — **done** (`Interface/` — three-pane layout, plan/worker/draft/source cards, citation chips, settings sheet)
- [x] T9 — Wire entry point, delete legacy — **done** (`Bootstrap/SwiftDeepResearchApp.swift` is new @main; old Core/Models/Services/Views/LLMLibrary/Appstate/ContentView/Swift_Deep_ResearchApp deleted)
- [ ] T10 — Build, validate, smoke test — *deferred this session* because the user explicitly requested no app build until package dependencies are fetched.

## 5) Findings, Decisions, Assumptions
- **Decision (D1):** Adopt Anthropic orchestrator-worker pattern verbatim (90% perf vs single-agent, 15× tokens). *Rationale:* matches user's "more powerful and advanced" mandate; token cost acceptable on-device with FM as orchestrator. *Consequence:* must implement actor-per-session and TaskGroup fan-out from day 1.
- **Decision (D2):** Foundation Models is the orchestrator brain, not the synthesizer. 4096-token context (memory #5336) is too small for synthesis but perfect for structured plan emission via `@Generable`. *Rationale:* keeps the privacy-first / free-tier story while routing heavy lifting to long-context cloud models.
- **Decision (D3):** Use direct REST clients for Anthropic Messages, OpenAI Chat/Responses-compatible chat, and Gemini `streamGenerateContent` so the app can accept documented model IDs immediately without waiting for third-party Swift SDK updates.
- **Decision (D4):** Tavily primary search ($0.008/credit, agent-ready snippets, memory #5329), Exa secondary for semantic discovery, Brave/DDG as free fallback.
- **Decision (D5):** Direct REST for search APIs — no SDK overhead. Each search provider is ~80 LOC.
- **Assumption (A1):** User has Xcode 26 installed (macOS 26 SDK present). *Falsify:* `xcodebuild -showsdks | grep macosx26`. *If false:* downgrade to macOS 15 + skip Foundation Models / Liquid Glass.
- **Assumption (A2):** User will enter API keys post-build via Settings sheet. *Falsify:* attempt query without keys → see helpful error.
- **Assumption (A3):** The duplicate file references in `project.pbxproj` (many `Agent.swift in Sources`) are stale and ignorable — Xcode builds each file once via the SOURCE_ROOT path. *Falsify:* `xcodebuild` with `-verbose` and count compile invocations.

## 6) Issues, Mistakes, Recoveries
- **Symptom → root cause → fix → guardrail added:** Initial `wc` inventory failed because file paths contain spaces (`Swift Deep Research/...`). Re-ran inventory with NUL-delimited paths. Guardrail: use `rg --files -0 | xargs -0 ...` for path-sensitive commands in this repo.
- **Issue:** Anthropic tool-use streaming currently emits tool argument deltas under synthetic `block-N` IDs, while tool-call starts use Anthropic's real tool-use ID. `LLMClient.complete` therefore cannot attach streamed JSON arguments to the right call. Planned fix: preserve an index-to-tool-id map while parsing Anthropic SSE events.
- **Issue:** Worker evidence collection only promotes `fetch_url` payloads into `FetchedSource`. PDF, Reddit thread, Wikipedia summary, and knowledge-base results can inform the worker summary but are invisible to the synthesizer's citation extractor. Planned fix: make worker source extraction generic and have `knowledge_base` return/emit synthetic fetched sources for uploaded document passages.
- **Issue:** The pyseekdb sidecar accepts empty documents and chunks by fixed character windows only. Planned fix: reject empty uploads clearly and use paragraph-aware chunking with overlap so embeddings carry better semantic boundaries.

## 7) Scenario-Focused Resolution Tests
- **Anthropic tool-call routing:** Source scenario is a streamed Anthropic tool call whose `content_block_delta` events identify the content block by index. The fix records the real `tool_use.id` from `content_block_start` and uses it for subsequent argument deltas and tool-call end events. Verdict: resolved by source review plus syntax parse; live API validation remains pending.
- **Knowledge-base passages as citation evidence:** Source scenario is a worker calling `knowledge_base`, receiving relevant uploaded-document passages, and then synthesis needing those passages as sources. The fix has `KnowledgeBaseTool` emit `sourceFetched` events and return `FetchedSource` records under `fetchedSources`; `WorkerAgent` now normalizes any tool payload that contains `FetchedSource` or `[FetchedSource]`. Verdict: resolved by source review plus syntax parse; live sidecar validation remains pending.
- **Document ingestion robustness:** Source scenario is a dropped or chosen document with no readable text, or a long document whose chunks cut through semantic boundaries. The fix rejects empty text before upsert and changes sidecar chunking to paragraph/sentence-aware windows with overlap. Verdict: resolved by Python compile and source review; embedding quality must be validated with pyseekdb installed.

## 8) Verification Summary
- **2026-05-25 static checks before edits:** `plutil -lint "Swift Deep Research.xcodeproj/project.pbxproj"` passed; `python3 -m py_compile sidecar/seekdb_sidecar.py` passed; `python3 -m json.tool feature_list.json` passed. No app build was run per user instruction.
- **2026-05-25 research evidence:** Anthropic's public engineering write-up supports orchestrator-worker research with parallel subagents, iterative synthesis/refinement, citation auditing, and explicit token trade-offs. Apple Foundation Models docs support on-device `LanguageModelSession`, guided generation, tool calling, context limits, prewarming, and token-count profiling. seekdb/pyseekdb docs support embedded local operation, built-in embedding, vector/full-text/hybrid search, and document-in/query-out workflows.
- **2026-05-25 post-edit checks:** `python3 -m py_compile sidecar/seekdb_sidecar.py` passed; `python3 -m json.tool feature_list.json` passed; `plutil -lint "Swift Deep Research.xcodeproj/project.pbxproj"` passed; syntax-only `xcrun swiftc -parse` passed for touched Swift files; `swift -e 'import UniformTypeIdentifiers; _ = UTType.commaSeparatedText; print("ok")'` passed; `git diff --check` passed. No app build was run.

## 9) Remaining Work & Next Steps
- **Open items:** T10 remains deferred until package dependencies can be fetched and the user allows a real Xcode build; live pyseekdb/seekdb sidecar smoke testing also remains pending until dependencies are installed.
- **Current session completed:** Anthropic tool streaming fix, current model ID normalization, knowledge-base evidence promotion, sidecar chunking/server-mode hardening, `PLANS.md`, feature-list update, and progress-log update.
- **Risks:**
  - Foundation Models API may differ from what memory #5345 captured → fall back to cloud orchestrator
  - Anthropic/Gemini model aliases may change → prefer documented snapshot or preview IDs over speculative names
  - Liquid Glass APIs may not be GA in user's installed Xcode → guard with `if #available(macOS 26, *)`
- **Next working interval:** Fetch packages when allowed, run real Xcode build/type-check, then live-test `sidecar/seekdb_sidecar.py` with `pyseekdb fastapi uvicorn pydantic` installed and run one knowledge-base retrieval flow.

## 10) Updates to This File (append-only)
- 2026-05-24T08:30Z: Created. Sections 1–10 populated from prior research memory + user clarifications.
- 2026-05-25T09:48Z: Added current-session scope, no-build constraint, static pre-check evidence, and the robustness implementation slice chosen after recursive Swift review and current architecture research.
- 2026-05-25T09:56Z: Recorded completed robustness changes, scenario-focused resolution notes, and post-edit verification evidence.
- 2026-05-25T09:58Z: Corrected the build-validation ledger to mark app build as deferred for this session and recorded the `UTType.commaSeparatedText` availability probe.

## Update — 2026-05-25T15:15Z: SeekDB knowledge-base feature
Added end-to-end document ingestion + semantic-search-as-tool integration:
- `sidecar/seekdb_sidecar.py` — FastAPI wrapper around pyseekdb (embedded mode), exposes /ingest, /documents, /query, /reset.
- `Swift Deep Research/Knowledge/SeekDBClient.swift` — actor-based HTTP client.
- `Swift Deep Research/Knowledge/KnowledgeBase.swift` — @Observable VM with file ingestion (PDFKit for PDFs, plain-text decoder for the rest).
- `Swift Deep Research/ResearchTools/KnowledgeBaseTool.swift` — ResearchTool that workers call when the toggle is on.
- `Swift Deep Research/Interface/DocumentUploadView.swift` — drag-drop + paste + test-query UI.
- ResearchCanvas: 'Use knowledge base' toggle in the new researchOptionsBar; depth menu (Fast/Standard/Thorough).
- SettingsSheet: new Knowledge tab for sidecar host + default-on toggle.
- MainScene: 'Knowledge base' toolbar button (⌘⇧K) opens DocumentUploadView sheet.
- Planner: when KB available, system prompt now instructs workers to try `knowledge_base` first.
- EngineConfiguration: new `seekdbHost` and `useKnowledgeBase` fields, threaded through ResearchEngine.makeTools().

Setup for users: `python3 -m pip install pyseekdb fastapi uvicorn pydantic` then `python3 sidecar/seekdb_sidecar.py --port 9100`.

## Update — 2026-05-25T15:15Z: Engine + UI polish completed
- Iterative loop with reflection (Reflector + IterationController) — Fast/Standard/Thorough presets surfaced.
- New tools: WikipediaTool, ArXivTool, PDFReaderTool, RedditTool, DateTimeTool, CalculatorTool.
- Shared SourceCache (cross-worker dedup) + RetryPolicy (exponential backoff).
- ConversationContext for multi-turn follow-ups; LiveSession.continueResearch + Follow-up button.
- InlineCitationsView renders [N] markers as tappable chips.
- DraftCard restructured with numbered source list + quoted-evidence section.
- ReflectionCard surfaces critic verdict/gaps mid-run.
- ActivityLog + Inspector tabs (Sources / Activity / Plan).
- SessionExporter (Markdown / HTML / JSON) + sidebar context menu + MainScene toolbar.
- Searchable session sidebar with highlighted matches.
- StatusBar footer with budget/round/source counts.
- SettingsSheet: added Iteration, Knowledge, Instructions tabs; system-prompt addendum threaded into planner/worker/synthesizer.
