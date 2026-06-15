# Handoff.md — Swift Deep Research v2 Rebuild

**Last Updated (UTC):** 2026-06-04
**Status:** In Progress
**Current Focus:** Multi-provider expansion (DeepSeek/MiniMax/Kimi/LM Studio/custom), config persistence, and SeekDB auto-bootstrap — landed; build green.

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

## Update — 2026-06-04: Provider expansion, config persistence, sidecar bootstrap, clean build
**Status:** In Progress → provider/UX overhaul landed; **build green, 0 warnings.**

User request (this session): "Overhaul to be more robust/performant/feature-rich.
Enable additional providers (DeepSeek, MiniMax, Kimi) and custom endpoints; make
LM Studio work; make SeekDB start automatically; ready to ship."

Delivered (all verified by `xcodebuild ... clean build` → **BUILD SUCCEEDED**, 0
errors, 0 duplicate-build-file warnings):
1. **Five new providers** — DeepSeek, MiniMax, Kimi (Moonshot), LM Studio, and a
   user-defined Custom endpoint. All speak the OpenAI Chat Completions wire format.
   - New `LLM/OpenAICompatibleClient.swift` is the single implementation of that
     wire format (SSE + tool-call buffering + endpoint normalization + `/v1/models`
     discovery). `OpenAIClient` is now a thin wrapper over it (selects
     `max_completion_tokens`; third-parties use legacy `max_tokens`).
   - `reasoning_content` (R1/Kimi thinking) is intentionally not surfaced as answer
     text. HTTP and mid-stream errors become actionable `EngineFailure`s.
   - Endpoints verified: DeepSeek `api.deepseek.com`, MiniMax `api.minimax.io`,
     Moonshot `api.moonshot.ai` — each resolves to `/v1/chat/completions`.
   - `ProviderRegistry` gained the cases + `usesFreeformModel`/`supportsModelDiscovery`;
     `makeClient` gained `lmStudioHost`/`customBaseURL`. `KeychainStore` gained
     `.deepseek/.minimax/.moonshot/.custom`.
2. **Config persistence** — `EngineConfiguration` is now `Codable`/`Equatable`
   (tolerant decoder); `AppEnvironment` loads/saves it via UserDefaults
   (`engineConfiguration.v2`). Custom endpoint base URL + LM Studio host persist.
3. **SeekDB robustness** — `SidecarSupervisor` still auto-starts at launch but now
   self-bootstraps a private venv (`~/Library/Application Support/SwiftDeepResearch/
   sidecar-venv`) and pip-installs deps on a ModuleNotFoundError, then relaunches
   from it. Added `.installingDependencies` status, early-exit health polling, and a
   `reinstallAndStart()` repair path. Settings → Knowledge gained Start/repair +
   Reinstall dependencies + a live status line.
4. **Settings UI** — editable model field with suggestion/discovery menu for the new
   providers; LM Studio + Custom endpoint cards (host/base URL, Apply, Test & list).
5. **project.pbxproj cleanup** — removed 72 stale explicit Swift refs that duplicated
   the `fileSystemSynchronizedGroups`; the synchronized group still compiles
   everything. Eliminates all "Skipping duplicate build file" warnings.

Acceptance evidence: build logs under `logs/build-final-*.log` and
`logs/build-clean-*.log` (clean build, 0 dup warnings). feature_list.json gained 9
`passes:true` entries; agent-progress.txt has the full session log.

Remaining (needs user-supplied secrets / live services, not code):
- Per-provider live API smoke test (DeepSeek/MiniMax/Kimi keys; running LM Studio).
- Live venv-bootstrap test on a machine lacking pyseekdb.

## Update — 2026-06-04 (cont.): SeekDB verified + knowledge-base chunk visibility
**Status:** build green, 0 warnings.

- **SeekDB verified end-to-end** (live): `sidecar/seekdb_sidecar.py` in embedded
  mode — `/health` ok, `/documents` chunked a doc, `/query` returned the chunk
  with score 0.58 + metadata (title/doc_id/chunk_index). The system Python
  (pyenv 3.12.6) already has the deps; the venv bootstrap path triggers only when
  they're missing.
- **Chunk visibility (user request):** users can now see and read the KB chunks
  the agent used as sources.
  - `FetchedSource` gained `relevanceScore: Double?` + `isKnowledgeBase`; the KB
    tool threads `hit.score` through.
  - Inspector (`SourcePanel`) has a dedicated **Knowledge base (N)** section
    ranked by score; tapping a chunk opens a full-text reader sheet (kb:// URLs
    have no browser handler). Web discoveries are filtered out of the generic
    Discovered section.
  - New `Interface/KBChunkDetail.swift` (shared `KBChunkDetail` reader +
    colour-coded `KBScoreBadge`) is reused by the inspector and the final answer.
  - `DraftCard` renders KB sources as "Knowledge base" + score and opens the
    reader instead of a dead `kb://` link.
- **Mid-run KB resilience:** `KnowledgeBaseTool.queryWithRecovery` asks
  `SidecarSupervisor.ensureRunning` and retries once if the sidecar is offline.
- Refreshed stale SeekDBClient / KnowledgeBaseTool comments (auto-start, not
  manual terminal launch).

Evidence: build logs `logs/build-kbshared-*.log`, `logs/build-kbrecover-*.log`
(SUCCEEDED, 0 dup warnings); live sidecar transcript captured in session.

---

## 2026-06-10 — Forecast workspace robustness + deeper MiroFish integration

**Request:** "Make the app more robust, integrating more closely the deep research
forecast workflow from `~/Downloads/mirofish`."

**Backend ground truth verified first.** The Swift Forecast layer was written
against an older partial copy of MiroFish; every route the client uses (and every
route added this session) was re-verified against the live code in
`~/Downloads/mirofish/MiroFish-0.1.2/backend/app/api/*.py`. That backend's venv is
healthy (Python 3.12.6, camel imports cleanly) — the screenshot's "venv needs
re-provisioning" banner was a supervisor misclassification path, now improved.
The backend gained (upstream) preflight checks on `POST /run` & `/resume` that
return 400 + bullet list — the app now surfaces those verbatim.

**Changes (all in `Swift Deep Research/`):**
- `Forecast/MiroFishClient.swift`: added `cancelPipeline` (404/409 tolerated),
  `resumePipeline`, `deletePipeline`, `reportChat` (300 s per-request timeout —
  ReAct loop is slow), `setProvider` (`POST /api/settings/llm`); new wire types
  `MFChatTurn`/`MFChatReply` (+`toolNames` extraction), `MFRunResponse.resumed`;
  `rawData`/`request` accept a per-call timeout.
- `Forecast/ForecastRun.swift`:
  - `cancel()` now also fires backend `POST /cancel` (was poll-stop only → the
    pipeline kept burning tokens server-side).
  - New `resume()` → backend `POST /resume`, reuses completed stage artifacts.
  - New `detach()` — stop following without cancelling (used when the UI switches
    runs; record stays "running" for later reattach).
  - `restored(from:)` keeps the SwiftData record attached (was nil → restored runs
    never persisted updates) and restores `errorText`.
  - New `hydrateFromBackend()` — restored runs re-fetch dossier/ontology/graph/
    report live, adopt backend status drift, and reattach if still running.
  - Poll loop handles backend `cancelled` status; failures persist `errorText`.
  - Report-agent chat: `chatMessages`/`chatBusy`/`chatError`, `canChat`,
    `sendChat(_:)` with prior-turn history.
- `Forecast/ForecastModels.swift`: `ForecastRecord.errorText: String?` (additive,
  lightweight SwiftData migration).
- `Forecast/MiroFishSupervisor.swift`: exit-classification now distinguishes
  import errors / port-in-use (Errno 48) / `.env` validation failures (run.py
  prints `配置错误:` bullets — Zep key and LLM key get targeted English guidance);
  new `repairEnvironment(repoRoot:)` (stops supervised child, `uv venv --python
  3.12` when venv missing/wrong, `uv sync`, 15-min cap per step, off-actor pipe
  drain) + `RepairError`.
- `Interface/AppEnvironment.swift`: `openForecast` auto-reattaches records stored
  as "running" (ensures backend, `resumePolling`) and hydrates finished ones;
  new `deleteForecast` (SwiftData + best-effort backend `DELETE`); private
  `detachForecast()` so switching/new runs never kill a live pipeline;
  `startForecast` uses it.
- `Interface/Forecast/ForecastPipelineView.swift`: failure/cancel banner showing
  `errorMessage` (incl. multi-line preflight bullets, text-selectable) with a
  **Resume** button wired to `run.resume()`.
- `Interface/Forecast/ForecastReportView.swift`: new `ForecastChatView` — Q&A
  thread with the report agent (markdown replies, tool-name chips, busy/error
  states), shown once `run.canChat`.
- `Interface/Forecast/ForecastSidebar.swift`: delete routes through
  `env.deleteForecast`.
- `Interface/Forecast/ForecastComposer.swift`: depth picker seeds from
  `forecastConfig.defaultDepth`.
- `Interface/SettingsSheet.swift` (Forecast tab): **Repair environment** button
  (drives `repairEnvironment`, then relaunches + reports), and an **LLM provider**
  group (GET/POST `/api/settings/llm`: picker from backend metadata, conditional
  API-key field, applies to new forecasts).

**Verification:** full `xcodebuild` Debug build (log `logs/forecast-robust-build-*.log`).
Backend routes/shapes verified by reading `research.py`, `report.py`, `settings.py`,
`simulation.py`, `config.py`, `pipeline_orchestrator.py` in the Downloads copy.
Live end-to-end run not executed this session (forecast pipelines take 30+ min and
spend LLM tokens); scenario checks to run next: cancel-mid-research (verify child
process dies server-side), resume-after-preflight-failure, relaunch-during-run
(auto-reattach), report chat round-trip.

**Note:** repo-root `MiroFish-0.1.2/` and `deer-flow/` (untracked) are stale,
incomplete copies of the Downloads originals (missing `backend/app/api`,
`config.py`, bridge). The app defaults to `~/Downloads/mirofish/MiroFish-0.1.2`,
so they're unused — candidates for deletion, left in place pending user say-so.

**2026-06-10 verification evidence (appended post-build):**
- `xcodebuild` Debug build SUCCEEDED, 0 errors / 0 project warnings
  (`logs/forecast-robust-build-20260610-170321.log`).
- All edited Swift files pass `swiftc -parse`.
- Live endpoint smoke test against the user's running backend at :5001:
  `/health` ✓, `GET /api/settings/llm` ✓ (envelope + provider metadata decode
  into `MFProviderInfo` shape), `GET /api/research/list` ✓, cancel/resume/delete
  on unknown id → 404 as the client expects, `POST /api/report/chat` with bad
  simulation id → `{"success": false, "error": …}` ✓.
- Caution learned: launching a second backend instance while one is live runs
  MiroFish's orphan-pipeline reclaim *before* the port-bind failure — it can kill
  stale child pids. `MiroFishSupervisor` already probes `/health` first and
  attaches instead of double-launching, which avoids this; keep it that way.

### 2026-06-10 (later) — Forecast onboarding assistant

**Request:** "create an onboarding phase that runs the startup script and gets
everything started up."

- `Forecast/ForecastOnboarding.swift` (new): @Observable model for the setup
  flow — environment checks (MiroFish folder, uv, git, claude/codex CLI or API
  provider in .env, Zep key in Keychain/.env, backend venv `python3.12` shim,
  DeerFlow checkout incl. `DEERFLOW_DIR` override), Zep key capture (Keychain +
  `syncEnv` into .env), `setup.sh` execution with live console (600-line cap,
  \r-progress collapsed), backend launch + health wait. Persists completion in
  UserDefaults (`forecastOnboardingCompleted.v1`).
- `MiroFishSupervisor.setupScriptStream(repoRoot:)` (new): nonisolated
  AsyncThrowingStream running `bash setup.sh` with stdin=/dev/null (the script's
  interactive Zep prompt self-skips — verified by reading setup.sh:229-247),
  augmented PATH, line-buffered output, cancellation → SIGTERM, non-zero exit →
  typed error.
- `Interface/Forecast/ForecastOnboardingView.swift` (new): 4-step sheet
  (checks → Zep key → setup console → start backend) with auto-scrolling
  console and skip hint when everything is already provisioned.
- Wiring: auto-presents once per session on first visit to the Forecast
  workspace when the backend isn't running and onboarding never completed;
  "Set up…" button on the backend-needs-setup banner; "Setup assistant…" in
  Settings → Forecast (switches to the Forecast workspace first since the sheet
  hangs off it).
- Known upstream behavior (accepted): re-running setup.sh on a configured
  machine re-detects the CLI provider and may flip LLM_PROVIDER in .env (e.g.
  minimax → claude-cli); the onboarding marks the step skippable when
  provisioned, and the provider can be switched back in Settings → Forecast.

**Evidence:** two `xcodebuild` Debug builds SUCCEEDED, 0 warnings
(`logs/forecast-onboarding-build*.log`); all check predicates validated against
the real machine (venv shim, deerflow_research.py, tool discovery incl. claude
at `~/.local/bin`); setup.sh non-interactive path verified by source read. Live
setup.sh run intentionally NOT performed — the user's backend is mid-pipeline
and the script would mutate `.env`'s LLM_PROVIDER.

### 2026-06-10 (later) — Backend forecast browser + knowledge-graph fixes

**Request:** "read from the completed forecast reports and display them on the
app's interface, including all the research, reports, and knowledge graph, and
everything else."

**Backend pipeline browser.** The sidebar now lists every pipeline MiroFish
knows about — started from this app, the web UI, run_simulation.py, or another
machine — under an "On backend" section (deduped against locally-imported runs,
manual refresh button). Tapping a remote pipeline imports it as a `ForecastRecord`
and opens it through the normal restore→hydrate path.
- `AppEnvironment`: `backendPipelines` state, `refreshBackendPipelines()`,
  `openBackendPipeline()` (creates record from `/status`, treats `pending`→running),
  `deleteBackendPipeline()`.
- `ResearchStore.findForecast(pipelineID:)` for dedupe.
- `ForecastSidebar`: "On backend" section + `BackendPipelineRow`; refresh `.task`.
- `ForecastWorkspaceView`: refreshes the list once the backend is confirmed up.

**Full hydration of completed/imported runs.** `ForecastRun.finalFetches` now
pulls *every* stage artifact (research console tail, dossier, project ontology,
knowledge graph, simulation run-status + timeline, report + agent log), not just
the ones that streamed in live — so an imported finished forecast renders all six
stages. `hydrateFromBackend()` (added earlier) drives this on open.

**Knowledge-graph view fixes (user-reported bugs).**
- *"No way to back out."* Grape's `ForceDirectedGraph` is a bare greedy `Canvas`
  that drew **unclipped over the pipeline header/stepper**, hiding the New/back
  controls. Fixed by `.clipShape(RoundedRectangle)` on both the graph canvas and
  the outer container, plus a finite `maxWidth/maxHeight:.infinity` frame.
- *"Tapping nodes shows no labels/details."* The plain `.onTapGesture` was being
  swallowed by Grape's `withGraphDragGesture`. Replaced with a
  `.simultaneousGesture(SpatialTapGesture)` that survives the drag and carries the
  hit location; empty-space taps now dismiss the inspector. Grape's hit-test area
  equals a node's drawn radius (confirmed by reading
  `ForceDirectedGraphModel.findNode`), so the node radius floor was raised
  (5→8 + degree) to make small nodes tappable.

**Live verification (against the user's running backend, 7 pipelines).**
- `/api/research/list` decodes cleanly into `MFPipelineSummary` (isolated Swift
  harness): 7 pipelines, 5 completed.
- Endpoint shapes for a completed pipeline confirmed: dossier (5.4 KB report),
  ontology (10 entity / 8 edge types), graph (90 nodes / 140 edges), simulation
  (542 actions, 24 timeline rounds), report (16.7 KB markdown, 3 sections),
  agent-log (70 lines).
- Built app launched: the Forecast sidebar populated with the backend pipelines;
  opening one rendered the full view — header, 6-stage stepper (Deep Research /
  Ontology / Knowledge Graph / Agent Setup all green, Simulation telemetry with
  the actions-per-round chart + agent feed, Report state). A live pipeline
  auto-advanced through its stages in real time in the imported view.
- Four clean `xcodebuild` Debug builds (`logs/backend-browser-build-*.log`,
  `logs/graph-fix-build-*.log`).
- Not visually re-confirmed via automation: the graph chip's rendered output
  after the clip fix — scripted clicking kept being confounded by live-pipeline
  auto-follow and then an OS automation-permission dialog. The fix is grounded in
  reading Grape's source (overdraw + gesture swallowing) and is low-risk.

## 2026-06-12 — DeerFlow flow in Deep Research + unified model provider manager

**Request.** Implement the DeerFlow deep-research flow inside the app's deep research function, augmented with the SeekDB knowledge base, and create a unified model provider manager covering both Deep Research and Forecast.

**What was built (all compiles clean — `logs/build-deerflow-unified-full.log`, 0 errors / 0 warnings in changed files):**

1. **`Engine/DeerFlowEngine.swift` (new).** Native Swift adaptation of DeerFlow's plan-and-execute LangGraph: background investigation (one `web_search` + one `knowledge_base` query run as a visible pseudo-worker whose findings and `kb://` sources feed the planner and the final report) → structured planner JSON (`title/thought/hasEnoughContext/steps[{title,description,stepType,suggestedQueries}]`, strict-context rule, max steps = min(4, budget.maxWorkers)) → sequential step execution via `WorkerAgent` with observation threading (`extraContext`) → re-plan loop (plan iterations = min(iteration.maxRounds, 3); planner sees step findings and either plans only the missing steps or declares context sufficient) → existing `Synthesizer` writes the cited report. Emits the same `ResearchEvent` stream, so LiveSession/UI/persistence are untouched. Processing-type steps get only calculator/datetime/knowledge_base tools.
2. **Flow selection.** `ResearchFlow` enum (`native`/`deerflow`) added to `EngineConfiguration` (tolerant decoding, default native). `ResearchEngine.run` delegates to `DeerFlowEngine` when selected. Picker in Settings → Providers → "Deep research flow".
3. **SeekDB augmentation.** KB queried during background investigation; planner prompt lists the KB document titles as DeerFlow-style "resources" and instructs steps to search the KB first; research steps keep the `knowledge_base` tool (existing `makeTools`, now shared between flows).
4. **`LLM/ModelProviderManager.swift` (new).** `ModelRole` enum (orchestrator/worker/synthesis/forecast) + `ProviderRegistry.makeClient(role:config:)` as the single in-process factory (both engines use it). `@Observable ModelProviderManager` owns the forecast assignment (UserDefaults `modelProviders.forecast.v1`), maps app providers onto MiroFish's vocabulary (deepseek/minimax/kimi/qwen native; openai/anthropic/gemini/ollama/lmstudio/custom bridged through MiroFish's generic OpenAI-compatible provider with the right base URL; MLX/FM excluded), pushes via `POST /api/settings/llm`, and seeds `.env` (`LLM_PROVIDER`, `DEERFLOW_MODEL`, `LLM_BASE_URL`, `LLM_MODEL_NAME`, `LLM_API_KEY` + per-provider key mirrors like `DEEPSEEK_API_KEY`).
5. **AppEnvironment.** Owns `modelProviders`; `ensureForecastBackend()` auto-pushes the forecast provider whenever the backend is confirmed running; `syncMiroFishEnv()` now seeds the LLM_* vars alongside the Zep key.
6. **Settings UI.** Providers tab: research-flow picker, fourth role group "Forecast (MiroFish)" (eligible providers only, model field, "Apply to backend now" + push-state label). Forecast tab's provider panel reframed as "backend live state" override.

**Assumptions / risks (to verify at runtime, see feature_list entries `feat_deerflow_research_flow` and `feat_unified_provider_manager`, both `passes:false`):**
- Anthropic/Gemini OpenAI-compat bridging assumes their `/v1`-style OpenAI-compatible endpoints accept MiroFish's chat-completions calls.
- Local providers (Ollama `/v1`, LM Studio `/v1`) pass dummy keys ("ollama"/"lm-studio") because MiroFish's generic provider requires a key string.
- DeerFlow planner JSON parsing falls back to a single direct research step (first iteration) / plan termination (re-plan) when the model emits malformed JSON.

**Next steps.** Runtime validation of both features end-to-end (needs API keys + running backend), then flip the feature_list flags with evidence.

## 2026-06-15 — Multi-agent codebase audit + systematic remediation (EXECPLAN2.md)

**Request.** Run a team of subagents to find blocks/bottlenecks/bugs and note them in `EXECPLAN2.md`; study the codebase and propose improvements; then work through EXECPLAN2.md and implement each item.

**Audit method (evidence under `logs/` + workflow transcripts).** Two background multi-agent workflows: (1) 12 parallel auditors, one per subsystem (core-engine, deerflow-engine, llm-providers, research-tools, forecast-mirofish, knowledge-seekdb, storage/domain/shared, ui-core, ui-settings + 3 cross-cutting: concurrency, security, architecture) → 155 findings; (2) adversarial verification (12 verifiers re-read the cited code, throttled into 3 waves to dodge rate limits) + an architect synthesis. Result: **150 verified findings kept (1 P0, 21 P1, 59 P2, 69 P3), 5 refuted** (e.g. `mirofish-supervisor-3` actor-reentrancy — coalescing is sound). `EXECPLAN2.md` is the full catalog (checkbox per finding) + executive summary, top risks, themes, quick wins, a 5-phase roadmap, and 8 capability ideas.

**Implemented this session — 23 findings (2 P0, 17 P1, 4 P2), each validated by a clean `xcodebuild` (Debug/macOS, 0 errors). The first 17 are below; a second batch followed (see "Batch 2").**
- **`build-health-1` (P1):** removed the stale 1.1 MB hook-log tree (incl. `aaa/bbb-collisiontest`) from under the synchronized source root — the build-collision source; moved to a `/tmp` backup. Green baseline captured (`logs/baseline-*.log`).
- **P0 `iface-pertoken-save-1`:** `AppEnvironment.ingest` no longer does a synchronous SwiftData `save()` (+ double JSON-encode) per `.tokenDelta`/`.reasoningDelta` — new `shouldPersist(_:)` persists only meaningful events. Removed the dead write-only `tokenStream` (`iface-tokenstream-dead-2`, P1).
- **P0 `mirofish-supervisor-1` + `-2` (P1):** backend launches as a new session/process-group leader via a `/usr/bin/perl … setsid` shim (falls back to direct launch), so `killpg` reaps the whole DeerFlow/OASIS tree instead of orphaning grandchildren. `terminate()` signals the group; a new nonisolated `ProcessGroupBox` lets `applicationWillTerminate` reap **synchronously** (the old `Task { await terminate() }` never finished before exit). Same hardening applied to `SidecarSupervisor` (SeekDB). `-4` (P2): `probeHealth` requires the MiroFish `service` signature, not any 200.
- **Budget cluster:** `Planner`/`Reflector`/`CitationExtractor` now charge tokens (`engine-token-budget-undercount`, P1); `AnthropicClient` captures `message_start` `input_tokens`(+cache) → single combined usage so prompt tokens count (`anthropic-prompt-tokens-zero`, P1); `Synthesizer` charges last-seen usage **once** instead of summing per-chunk, fixing Gemini's cumulative double-charge (`gemini-cumulative-usage-double-charge`, P2).
- **Security:** new `Shared/URLSafety.swift` SSRF guard (blocks non-http(s), loopback/private/link-local/metadata IPs + localhost-style hosts) wired into `WebReaderTool`/`PDFReaderTool`/`RedditTool` (`research-tools-ssrf`, `sec-ssrf-fetch-tools-1`, P1). MiroFish `.env` `chmod 0600` after write (`sec-env-cleartext-perms-3`, P1). Gemini key moved from `?key=` to the `x-goog-api-key` header + percent-encoded model path, in `GeminiClient` and `ModelDiscovery` (`gemini-apikey-unescaped-url`, P1).
- **Robustness:** `AnthropicClient.checkOK` drains+parses the error body (`anthropic-error-body-discarded`, P1). `WebReaderTool.HiddenWebView` got a load watchdog timeout (20s) + resume-exactly-once `finish()` (`research-tools-js-timeout` + `concurrency-webreader-continuation-leak`, P1). `ResearchStore.makeContainer` got a destroy-and-recreate fallback so a schema change can't brick launch (`store-no-migration-plan-5`, P1; data-preserving VersionedSchema is the follow-up).

**Batch 2 (6 more findings, all building green):**
- `store-source-id-cross-session-1` (P1): `StoredSource.id` is now a `sessionID|url` composite (was url-only + `.unique`), so re-researching an overlapping URL no longer overwrites another session's source nor cascade-deletes it. No schema change (value-only), so the destroy-and-recreate fallback isn't triggered.
- `engine-wallclock-not-interruptible` (P1): new `Shared/TaskTimeout.swift` `withTimeout(_:operation:)`; `WorkerAgent` bounds each `llm.complete` by `BudgetMeter.remainingWallClock` (new property); `Synthesizer` polls `checkWallClock()` every 48 chunks mid-stream and stops (keeping the partial draft, skipping the citation pass) when the budget is spent.
- `concurrency-budgetmeter-charge-discard` (P2): `WorkerAgent` re-asserts the token cap via `chargeTokens(0)` after each tool-charged hop, so tool token spend (charged through the non-throwing `ToolContext.charge`) actually stops the worker.
- `deerflow-1` (P1): `DeerFlowEngine.backgroundInvestigation` now decodes `web_search` hits into lightweight `FetchedSource`s (`decodeSearchAsSources`, snippet as text, URL-string id) so the background sweep's web findings are citable in the final report (were previously markdown-only and lost).
- `iface-orphaned-live-run-4` (P1, the clear orphan part): `ResearchCanvas.newSession()` calls `env.cancelLive()` before dropping `env.live` — the "New Chat" button no longer leaves a detached, budget-spending `streamTask` running. (The softer "navigate to another session while live is active" case was left as-is deliberately — cancelling on mere navigation is harsh UX, and the live run persists to its own session so it doesn't corrupt the viewed one; the proper fix is a persistent "Running" sidebar row, a larger UI change.)
- `iface-canvas-fetch-in-body-3` (P2): `ResearchCanvas` caches the resolved `StoredSession` in `@State` and refreshes it via `.onChange(of: selectedSessionID, initial: true)` instead of running a `FetchDescriptor` fetch inside `body` on every live-timer re-render.

**Batch 3 — Phase-4 consolidations + 1 P1 (3 more, all green; session total 26: 2 P0, 18 P1, 6 P2):**
- `json-extract-dup-1` (P2): new `Shared/LLMJSON.swift` with `extractObject(_:)` (strip ```json fences → first `{`…last `}`) and `quoted(_:)` (JSON string literal). Replaced the 4 copy-pasted extractors (Planner/Reflector/DeerFlowEngine/CitationExtractor) and DeerFlow's `jsonString` with calls to it — one source of truth for LLM-JSON salvage.
- `provider-factory-1` (P2): `ResearchEngine` now resolves all three roles via `registry.makeClient(role:config:)` (the same factory DeerFlowEngine uses) instead of repeating six config args per role — single provider/model/endpoint resolution path. (Left the legacy positional `makeClient(provider:…)` non-private since the role factory + ModelDiscovery call it.)
- `kb-host-contract-mismatch` (P1): `SidecarSupervisor` now launches the sidecar with an explicit `--host` (from the probe URL) in addition to `--port`, so the bind address matches what the client probes instead of relying on the sidecar's 127.0.0.1 default. (`--data-dir`/`--collection`/`--database` have no app-side config to diverge from — both sides use the same hardcoded defaults — so they're left as sidecar defaults.)

**Verification.** Each cluster built clean (`logs/p1-*`, `logs/p2-*`, `logs/p3-*`, `logs/p4-*`, `logs/final3-*` — final full build: 0 errors / 0 warnings in app sources, all 26 changes together). These are code-review-grounded; runtime E2E (process-tree reaping, SSRF rejection, budget accuracy, wall-clock interruption) needs a live run with keys + backend — the next validation step. No git commit made (left for review; pre-existing DeerFlow/provider work is also uncommitted in the tree).

**Next session — highest-value remaining (EXECPLAN2.md):** `engine-wallclock-not-interruptible` (P1, wrap llm/tool calls in a ContinuousClock/Task-race timeout), `deerflow-1` (P1, background web-sweep sources never become citable FetchedSources), `store-source-id-cross-session-1` (P1, `StoredSource.id` unique-on-url corrupts across sessions), `iface-canvas-fetch-in-body-3` / `iface-orphaned-live-run-4` (P1 UI). Phase 4 structural: `engine-dup-1` (unify the two engines' scaffold), `json-extract-dup-1`, `provider-factory-1`, AppEnvironment decomposition, and `no-tests-1` (Swift Testing target — deferred because adding a target to the synchronized-group pbxproj is risky; do carefully first). Work top-down; build after each cluster.
