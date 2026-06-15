# EXECPLAN3 — Improvements, Optimizations & Out-of-Box Readiness

> Generated from an 8-analyst parallel survey of the Swift Deep Research macOS app (Engine, LLM/providers, Knowledge, Forecast, UI/UX, Storage, OOBE/build/release, security/perf). EXECPLAN2.md covered a bug backlog; **EXECPLAN3 is for enhancements, optimizations, and — above all — guaranteeing the app works out of the box for a fresh user**, culminating in a shippable `.dmg`.

**Totals:** 69 items — 1×P0, 20×P1, 27×P2, 21×P3.
> **Progress (this session):** 21/21 P0+P1 implemented and shipped; 9+ P2/P3 items done. Remaining P2/P3 are tracked below (unchecked). Build green; v2.0 .dmg shipped. `E3-oobe-2` is partial — ad-hoc signed + Gatekeeper note, since no Developer ID identity is available to notarize.


## Executive summary

### Out-of-box readiness gate (must pass before shipping the .dmg)

- **E3-llm-1** (P0, out-of-box) — Make the zero-key default config actually runnable on-device
- **E3-engine-1** (P1, robustness) — Guard against empty/degenerate planner output before dispatching round 1
- **E3-engine-2** (P1, out-of-box) — Warn (and degrade visibly) when synthesis runs with zero grounded findings
- **E3-engine-3** (P1, out-of-box) — Preflight all three role providers' API keys, not just the worker
- **E3-engine-4** (P1, out-of-box) — Give fresh users a usable default search path beyond DuckDuckGo scraping
- **E3-forecast-1** (P1, out-of-box) — Run preflight before starting a forecast so config failures surface before spend
- **E3-kb-1** (P1, out-of-box) — Pin Python dependency versions to prevent fresh-install breakage
- **E3-kb-2** (P1, out-of-box) — Move embedding-model warm-up off the startup critical path so /health binds before the ~90MB download
- **E3-kb-8** (P1, out-of-box) — Guard the sidecar architecture against App Sandbox before distribution
- **E3-llm-2** (P1, robustness) — Omit temperature for OpenAI GPT-5/o-series so the default OpenAI provider works
- **E3-llm-3** (P1, robustness) — Respect supportsToolCalling when selecting orchestrator/worker providers
- **E3-oobe-1** (P1, robustness) — Derive Keychain service name from the bundle id instead of the fork's hardcoded id
- **E3-oobe-2** (P1, out-of-box) — Add a Developer ID signed + notarized DMG release path so downloads run without Gatekeeper friction
- **E3-oobe-5** (P1, out-of-box) — Fix the empty default research config when neither Foundation Models nor an Anthropic key is present
- **E3-sec-1** (P1, security) — Re-check redirect targets against URLSafety to close the SSRF bypass
- **E3-sec-2** (P1, security) — Guard the WKWebView JavaScript-render path against redirect/JS navigation to private hosts
- **E3-storage-3** (P1, robustness) — Narrow the destroy-the-whole-store launch fallback so transient errors don't wipe history
- **E3-ux-1** (P1, robustness) — Cancel the live run when starting New Research from the toolbar and command-N

### Highest-leverage items

- **E3-llm-1** [P0/M/low] — Make the zero-key default config actually runnable on-device
- **E3-engine-1** [P1/S/low] — Guard against empty/degenerate planner output before dispatching round 1
- **E3-engine-2** [P1/S/low] — Warn (and degrade visibly) when synthesis runs with zero grounded findings
- **E3-engine-3** [P1/S/low] — Preflight all three role providers' API keys, not just the worker
- **E3-engine-4** [P1/M/medium] — Give fresh users a usable default search path beyond DuckDuckGo scraping
- **E3-forecast-1** [P1/S/low] — Run preflight before starting a forecast so config failures surface before spend
- **E3-forecast-2** [P1/M/medium] — Surface the structured forecast (scenarios + probabilities) instead of only the prose report
- **E3-kb-1** [P1/S/low] — Pin Python dependency versions to prevent fresh-install breakage
- **E3-kb-2** [P1/M/medium] — Move embedding-model warm-up off the startup critical path so /health binds before the ~90MB download
- **E3-kb-8** [P1/M/medium] — Guard the sidecar architecture against App Sandbox before distribution
- **E3-llm-2** [P1/S/low] — Omit temperature for OpenAI GPT-5/o-series so the default OpenAI provider works
- **E3-llm-3** [P1/M/medium] — Respect supportsToolCalling when selecting orchestrator/worker providers
- **E3-oobe-1** [P1/S/low] — Derive Keychain service name from the bundle id instead of the fork's hardcoded id
- **E3-oobe-2** [P1/M/low] — Add a Developer ID signed + notarized DMG release path so downloads run without Gatekeeper friction
- **E3-oobe-5** [P1/M/medium] — Fix the empty default research config when neither Foundation Models nor an Anthropic key is present
- **E3-sec-1** [P1/M/low] — Re-check redirect targets against URLSafety to close the SSRF bypass
- **E3-sec-2** [P1/S/low] — Guard the WKWebView JavaScript-render path against redirect/JS navigation to private hosts
- **E3-storage-1** [P1/S/low] — Stop persisting write-only StoredSource.fullText (or move to external storage)
- **E3-storage-2** [P1/M/low] — Eliminate write-only event snapshots (double JSON write) or actually use them for replay
- **E3-storage-3** [P1/M/low] — Narrow the destroy-the-whole-store launch fallback so transient errors don't wipe history
- **E3-ux-1** [P1/S/low] — Cancel the live run when starting New Research from the toolbar and command-N

## Subsystem overviews

### Research Engine

The research engine is a mature, well-instrumented multi-agent loop (plan → parallel workers → synthesize → reflect/deepen) with a parallel DeerFlow plan-and-execute flow sharing the same event stream, tools, budget meter, and source cache. Robustness work is extensive: bounded stream buffers, charge-before-use token gating, per-call wall-clock timeouts, graceful per-worker degradation, source-cache in-flight dedup, and an anti-hallucination citation grounding gate. The biggest remaining opportunities are first-run robustness gaps that produce poor/empty/ungrounded results for a fresh user: a fresh install with no API keys falls back to DuckDuckGo-only HTML scraping (frequently blocked), and when all workers fail the synthesizer still emits a confident-but-ungrounded answer with zero warning. Two correctness traps can yield empty or hollow runs — an LLM-emitted empty subtask array is not guarded (JSON-Schema minItems is not enforced by Codable), and the missing-key preflight only checks the worker provider so orchestrator/synthesis key gaps surface as opaque mid-run 401s. Quality opportunities include unused planner signals (estimatedComplexity/estimatedTokenBudget are parsed then ignored), a citation auditor that only sees the first 4k of each source's 20k extracted text, and thorough (6-round) runs that can collapse early when the reflector is quiet because the deterministic deepening fallback window wraps and is then dedup-filtered. None of these require architectural change; they are targeted guards, prompt/window tweaks, and a slightly broader preflight.

### LLM & Providers

The LLM layer is mature and well-factored: a single `LLMClient` protocol with one canonical OpenAI-compatible implementation, dedicated Anthropic/Gemini/Ollama/FoundationModels clients, a shared `HTTPErrorMapping` for actionable error text, robust SSE/NDJSON parsing with truncation detection, and a careful transient-retry policy that only retries before any output is delivered. Tool-call buffering handles real-world gateway quirks (Qwen empty ids, object-form arguments, missing `[DONE]`). The biggest weakness is the out-of-box (OOBE) story: the suggested default configuration hard-wires the worker and synthesis roles to Anthropic, so a fresh user with only on-device Apple Intelligence — or with no key at all — cannot complete a single research run despite the app advertising local/on-device support. Secondary OOBE gaps: the OpenAI default model (`gpt-5.5`) will 400 because the client always sends a non-default `temperature` that GPT-5/o-series reject; the engine never consults `identity.supportsToolCalling`, so picking Foundation Models (or MLX) for the orchestrator/worker silently produces tool-less, degraded research; and the forecast default provider is MiniMax, which needs a key. There are also smaller correctness/robustness items (hardcoded 128k Ollama context that can OOM small Macs, model-list drift between the registry and client identities, a non-functional MLX provider still surfaced as a choice, and no auto-population of model lists). Fixing the first three findings would make the app genuinely usable on a clean machine.

### Knowledge Base

The knowledge-base subsystem is mature and visibly battle-hardened: the prior audit remediation is evident throughout (writer-preferring RW lock, journal/vector reconciliation, port-conflict recovery via setsid+killpg+lsof, parent-death kqueue watchdog, tolerant text decoding, PDF OCR fallback via Vision, bulk-ingest with graceful single-add fallback, distance-to-score normalization, body-size limits, and pinned embedding-model name). Config (seekdbHost) is correctly propagated to all clients, and the sidecar .py is bundled in app Resources, so auto-launch can find the script in a release build. The strongest remaining risks are concentrated in first-run robustness rather than core correctness. The two highest-impact gaps both involve network-dependent first-run steps: dependencies are pip-installed without any version pinning (a silent future-break for every fresh user while existing users stay fine), and the embedding-model download runs synchronously on the startup critical path before /health binds, so a slow connection can exceed the supervisor's fixed 90s health-wait and report a false failure. Offline first-run is not detected distinctly from broken-deps, so the actionable guidance shown is often wrong. Retrieval quality has no relevance floor or per-document diversity, so off-topic queries return junk passages the worker is nudged to cite. Cross-cutting concerns: the sidecar is unauthenticated on loopback (privacy/destructive-reset exposure), the HF model cache lands outside the app's data tree, and the whole Process-spawning design quietly assumes App Sandbox stays disabled — a prerequisite that should be made explicit before any sandboxed/MAS distribution. None of these block the happy path on a developer machine, but several can make the KB appear broken to a fresh user on imperfect networks.

### Forecast

The Forecast subsystem is a mature, carefully-engineered integration: MiroFishSupervisor auto-launches and reaps the heavy Python backend (with setsid process-group cleanup, .env secret hardening, config-path safety gates), MiroFishClient wraps the enveloped JSON API, ForecastRun drives a robust 2s poll loop with transient/non-transient retry budgets, resume/cancel/detach, and SwiftData persistence, and the UI renders all six pipeline stages live. The polling/cancel/resume/error machinery is genuinely solid. The biggest gaps are (1) the app never calls the backend's preflight endpoint, so a fresh user discovers a missing key or invalid config only AFTER firing a full run (potentially minutes of wasted research spend) instead of before; and (2) several powerful new backend capabilities are confirmed present but completely unsurfaced: the machine-readable structured forecast (scenarios + probabilities + resolution criteria) and its Brier scoring, what-if scenario forking (/scenario), continuing a research_only run to a full forecast (/continue), and human-in-the-loop dossier editing (/dossier PUT). Critically, the structured-forecast and v1 SDK features are gated behind REPORT_STRUCTURED_FORECAST and API_V1_ENABLED env flags that default to False and that the app's envSeed never sets, so today the app shows only a prose markdown report and throws away the calibrated scenario probabilities the engine can produce. Smaller items: the dossier model silently drops the new timeline field, batch cleanup of failed pipelines is done one-by-one, and report progress is polled rather than streamed. First-run robustness is good but would jump materially by wiring preflight into both onboarding and the composer.

### UI / UX

The UI is mature and thoughtfully built: a NavigationSplitView shell with a workspace switcher, a Liquid Glass-aware composer/card system (glassCard(), glassEffect with pre-26 fallbacks), good empty states via ContentUnavailableView in most Forecast/KB views, throttled streaming renders, and a polished System-Settings-style preferences sheet. First-run guidance is genuinely strong (missingKeyHint banner, suggestion chips that route to Settings when no key, sidecar/forecast onboarding assistants). The biggest gaps are: (1) two New Research entry points (the toolbar button and the app-level command-N CommandGroup) drop env.live without cancelling it, orphaning an in-flight run that keeps streaming and spending token budget — the careful cancel-first pattern only exists in ResearchCanvas.newSession(); (2) command-N is bound in two places and, in the Forecast workspace, silently clears the (hidden) research session instead of starting a new forecast; (3) accessibility is thin — only ~5 accessibility modifiers exist app-wide and ~35 icon-only buttons rely on .help() (tooltip, not VoiceOver-readable); (4) the research failure banner has no retry, unlike the Forecast error banner; (5) several empty-state and polish opportunities (no sidebar ContentUnavailableView in research, no provider/model summary in Forecast composer). These are mostly low-risk, high-polish wins that make the app feel finished out of the box.

### Storage & Persistence

The persistence layer is a small, well-reasoned SwiftData façade: ResearchStore coalesces high-frequency streaming writes into one debounced save (good for jank), flushes synchronously at durability boundaries, and uses an isolated deinit to flush on teardown. The schema (StoredSession/Turn/Source/Citation/Event + ForecastRecord) is clean and the loss-less ResearchEventSnapshot is carefully engineered. However, three big issues undermine storage health for a real user over time. (1) The two largest persisted columns — StoredSource.fullText (entire extracted article text per source) and StoredEvent.eventPayloadJSON+payloadJSON (a full Codable snapshot of every meaningful event, written twice) — are write-only: no read path in the app ever consumes them, so the store grows without bound while delivering zero value, eventually bloating the SQLite file into the hundreds of MB and slowing every save/fetch. (2) There is no schema migration plan (no VersionedSchema/SchemaMigrationPlan) and the only recovery is makeContainer's catch-all that destroys the entire store — which also fires on transient/recoverable errors (disk full, file locked), silently wiping all research history. (3) There is no retention/cap and no index, so an active user accumulates unbounded sessions; the sidebar search builds a lowercased blob that faults every turn's full markdown and every source for every session, and all relationship sorting happens in-memory. There is also no import path (export is one-way) so backed-up JSON can't be restored. The fixes are mostly low-risk and high-leverage: stop persisting write-only columns (or mark fullText externalStorage), narrow the destroy-on-launch fallback, and add a lightweight retention/index strategy.

### Out-of-Box / Build / Release

The app has a thoughtfully designed first-run flow for the common case: a `missingKeyHint` banner (AppEnvironment.swift:308) guides users to add an API key before firing a doomed run, suggestion chips route to Settings when no key exists, web_search degrades to keyless DuckDuckGo, the SwiftData store self-heals on schema mismatch (ResearchStore.swift:104), and the SeekDB Python sidecar auto-bootstraps a virtualenv so the knowledge base "just works." App icon is complete (all 10 mac sizes) and a deployment floor of macOS 26.0 is intentional. However several concrete issues block a clean fresh-user/distribution experience. The Keychain service name is hardcoded to the upstream fork's bundle id `com.aryamirsepasi.Swift-Deep-Research.keys` while the current bundle id is `com.linroger.Swift-Deep-Research` (KeychainStore.swift:10) — a fork leftover that should be derived from the running bundle. The app is ad-hoc signed with no notarization, Developer ID, or DMG packaging, so a downloaded build hits Gatekeeper "damaged/unidentified developer" friction with no in-repo tooling or README guidance to fix it. Version/build numbers are frozen at 1.0/1, copyright is empty, and no `LSApplicationCategoryType` is set. The sidecar (and its potential pip install) spawns at every launch from MainScene's `.task` even when the user never touches the Knowledge Base, which can surprise a fresh user with a network/install on first run. The Forecast workspace defaults to a hardcoded `~/Downloads/DeepResearchForecast` path that won't exist for fresh users (mitigated by an onboarding assistant). The biggest opportunities: fix the keychain identifier, add a signed/notarized DMG release path, make the sidecar boot lazy, and surface a clear macOS-version/Gatekeeper story.

### Security & Performance

This subsystem is unusually well-hardened for its stage: KeychainStore pins device-only, after-first-unlock-this-device-only items and never logs secrets; URLSafety is a solid literal SSRF guard (IPv4/IPv6 private/loopback/link-local/metadata, scheme allow-list) applied consistently to every LLM/web-supplied URL (WebReader, PDF, Reddit); the MiroFish .env writer does atomic write + 0600 + single-quote escaping; child processes get secrets via .env, not argv, so keys don't show in `ps`; backends bind to 127.0.0.1; logTail and the activity log are bounded; SourceCache, PDF, and HTML paths all cap buffered bytes; and the streaming markdown render is already throttled to 120ms with a per-token persistence guard that avoids thousands of MainActor SQLite saves. The biggest remaining opportunities are: (1) the SSRF guard only validates the *initial* URL — URLSession and the WKWebView JS fallback follow server redirects (and client JS navigation) to private/metadata hosts without re-checking, a real bypass beyond the documented DNS-rebinding gap; (2) no ATS exception is configured while URLSafety advertises `http://` support, so cleartext public fetches silently fail with -1022 under default ATS; (3) a few residual performance items: scroll-to-bottom animates on every synthesis token (the render is throttled but the scroll is not), and ConversationContext.accumulatedSources grows unbounded (full 40k-char source text retained) across long multi-turn sessions. None of these block first run for the common HTTPS path, but the redirect-SSRF and ATS items are the highest-value hardening/robustness wins.

## Prioritized backlog

### P0 — 1 item(s)

#### E3-llm-1 — Make the zero-key default config actually runnable on-device
- **Category:** out-of-box · **Impact:** P0 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Engine/EngineConfiguration.swift:129-143`, `Swift Deep Research/LLM/FoundationModelsClient.swift:23-30`, `Swift Deep Research/Interface/AppEnvironment.swift:66-73`
- **Problem:** `suggestedDefault()` only routes the orchestrator to Foundation Models when available; worker and synthesis are unconditionally set to Anthropic (`workerProvider:.anthropic`, `synthesisProvider:.anthropic`). A fresh user who launches the app on a Mac with Apple Intelligence but no API key gets a config that fails the moment a worker runs — the worker provider needs an Anthropic key that doesn't exist. The app markets on-device use ('switch to a local model (Ollama, LM Studio, or Apple)') but the default it ships cannot produce any answer without the user first finding Settings and adding a paid key. This is the single biggest barrier to a working first run.
- **Proposal:** When `FoundationModelsClient.isAvailable`, default ALL three roles (orchestrator, worker, synthesis) to a runnable local stack: e.g. orchestrator+synthesis on Foundation Models and worker on Foundation Models too, OR detect a running Ollama (`OllamaClient.listModels`) and prefer it for the worker/synthesis roles since FM cannot tool-call (see related finding). Only fall back to Anthropic when neither on-device path exists. At minimum, never ship a default whose worker/synthesis require a key the user has not provided.
- **Acceptance:** On a clean machine (no keychain entries) with Apple Intelligence enabled and no Ollama, launching the app and submitting a query produces a (possibly degraded) answer end-to-end with zero configuration, rather than surfacing 'Anthropic API key not set.'

### P1 — 20 item(s)

#### E3-engine-1 — Guard against empty/degenerate planner output before dispatching round 1
- **Category:** robustness · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Engine/ResearchEngine.swift:118`, `Swift Deep Research/Engine/ResearchEngine.swift:131`, `Swift Deep Research/Domain/ResearchPlan.swift:129`, `Swift Deep Research/Domain/ResearchPlan.swift:94`
- **Problem:** The plan schema advertises subtasks minItems:1, but JSONDecoder does NOT enforce JSON-Schema constraints — a planner LLM that returns "subtasks": [] decodes cleanly into an empty array. ResearchPlanJSON.decode happily returns a zero-subtask plan, and ResearchEngine then computes round1Batch = plan.subtasks.prefix(maxWorkers) = [], runs zero workers, and synthesizes from no findings — the fresh user gets an empty/ungrounded answer. Weaker default orchestrators (Apple Foundation Models, small Ollama models, which are the suggested defaults when FM is available) are the most likely to emit a malformed or empty array. Only a full decode FAILURE triggers the single-subtask fallback; a syntactically valid empty array slips through.
- **Proposal:** In ResearchPlanJSON.decode, after mapping subtasks, if the resulting subtasks array is empty (or all questions are blank), return ResearchPlanJSON.fallback(query:) instead of an empty plan. Defensively, also guard in ResearchEngine.run: if round1Batch.isEmpty after building it, seed it from ResearchPlanJSON.fallback(query:).subtasks so a round always dispatches at least one worker.
- **Acceptance:** Feed decode() a plan JSON with "subtasks": [] and confirm it returns the single-subtask fallback (covers the original query). Run the native engine with a stub orchestrator returning empty subtasks and confirm at least one worker runs and a non-empty draft is produced.

#### E3-engine-2 — Warn (and degrade visibly) when synthesis runs with zero grounded findings
- **Category:** out-of-box · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Engine/Synthesizer.swift:32`, `Swift Deep Research/Engine/Synthesizer.swift:42`, `Swift Deep Research/Engine/Synthesizer.swift:94`
- **Problem:** Synthesizer.synthesize filters workerOutputs to those with findings (line 32) and dedups sources (line 42), but never checks whether BOTH are empty. When every worker fails (e.g. a fresh user with no search keys whose only backend is DuckDuckGo and DDG returns an anti-bot page), workerSection and sourceTable are both empty, yet the synthesizer still issues the LLM call with an empty findings block. The model then answers confidently from its own parametric knowledge with no citations, and the user has no signal that zero sources were actually gathered — it looks like a real, grounded research result. This is a silent first-run failure mode.
- **Proposal:** Before the synthesis LLM call, compute whether there are any grounded findings (orderedSources.isEmpty && workerOutputs.allSatisfy { !$0.hasFindings }). If so, emit(.warning("No sources were gathered — the answer below is unverified and uncited. Add a web-search API key in Settings to enable real research.")) and either prepend that caveat into the synthesis system prompt (instructing the model to state it could not gather sources) or surface it as a distinct status. At minimum, the warning makes the empty-research case visible in the activity feed and answer.
- **Acceptance:** Run the engine with all search backends stubbed to fail so every worker returns no sources; confirm a .warning is emitted and the final draft is clearly marked as unverified rather than presented as a normal cited answer.

#### E3-engine-3 — Preflight all three role providers' API keys, not just the worker
- **Category:** out-of-box · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/AppEnvironment.swift:308`, `Swift Deep Research/Interface/AppEnvironment.swift:316`, `Swift Deep Research/Engine/EngineConfiguration.swift:129`
- **Problem:** refreshKeyStatus() only checks configuration.workerProvider.requiresAPIKey. The suggested default uses Anthropic for worker AND synthesis but Anthropic Haiku (or Foundation Models) for the orchestrator. A user who, e.g., sets the orchestrator or synthesis role to a keyed provider while leaving the worker on a local model gets missingKeyHint == nil (banner cleared), then the run fails partway through with an opaque provider 401 from the orchestrator/synthesis call instead of the friendly 'add an API key' banner. The preflight under-covers the actual roles the run will exercise.
- **Proposal:** Make refreshKeyStatus() iterate over the distinct providers across orchestrator, worker, and synthesis roles, checking requiresAPIKey for each. Report the first role missing a key (e.g. 'Synthesis model (OpenAI) needs an API key…') so the hint names which role/provider is unconfigured. Keep clearing the hint only when every keyed role has a key.
- **Acceptance:** Set worker to a local provider (no key) and synthesis to Anthropic with no Anthropic key stored; confirm the welcome banner appears and names the synthesis/Anthropic role, and that the suggestion chips route to Settings instead of firing a doomed run.

#### E3-engine-4 — Give fresh users a usable default search path beyond DuckDuckGo scraping
- **Category:** out-of-box · **Impact:** P1 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/ResearchTools/WebSearchTool.swift:39`, `Swift Deep Research/ResearchTools/WebSearchTool.swift:306`, `Swift Deep Research/ResearchTools/WebSearchTool.swift:354`
- **Problem:** WebSearchTool.makeDefault() only appends keyed backends (Tavily/Exa/Brave) when their keys exist; a fresh user with no keys gets a single backend: DuckDuckGoBackend, which scrapes html.duckduckgo.com via regex. DDG frequently serves anti-bot/captcha interstitials to datacenter/automated requests (the code itself logs 'parsed 0 results … likely a markup change or anti-bot page'). On those responses the search returns an empty .ok, every worker gathers ~0 sources, and the whole run produces an ungrounded answer — the most common fresh-install experience. There is no in-product nudge that a free search key (Tavily/Brave have free tiers) is effectively required for good results.
- **Proposal:** Two-part: (1) Surface a one-time onboarding/Settings note that web research quality depends on a search API key, linking to Tavily/Brave free tiers, shown when WebSearchTool falls back to DDG-only. (2) Harden the keyless path: when DDG parses 0 links from a 200 response, optionally try a secondary keyless source (e.g. a Wikipedia opensearch query for encyclopedic topics is already available via WikipediaTool, or the DDG Instant-Answer API) before declaring empty, and emit a worker-visible note 'web search returned no results (no search key configured)'. At minimum make the all-empty keyless case loud rather than silent.
- **Acceptance:** On a clean install with no search keys, run a query and confirm either real DDG results or a clear in-UI note that no search key is configured and results will be limited; confirm adding a Tavily key in Settings makes the backend chain pick it up on the next run.

#### E3-forecast-1 — Run preflight before starting a forecast so config failures surface before spend
- **Category:** out-of-box · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/AppEnvironment.swift:100`, `Swift Deep Research/Forecast/MiroFishClient.swift:71`, `Swift Deep Research/Interface/Forecast/ForecastComposer.swift:159`
- **Problem:** startForecast() only ensures the backend is reachable, then fires POST /api/research/run blind. The backend already does a preflight gate inside /run (research.py:84) and rejects with a multi-line bullet list (missing LLM_API_KEY, invalid GRAPH_BACKEND, placeholder credentials). But for a fresh user with a misconfigured provider, the failure is only learned AFTER the POST — and crucially the deep-research stage can begin before the model name is validated for downstream stages, burning research credits before the run fails. The dedicated GET /api/research/preflight endpoint (research.py:288) exists precisely to catch this up front but is never called by the app.
- **Proposal:** Add MiroFishClient.preflight(mode:) hitting GET /api/research/preflight?mode=<mode>, decoding {ready, errors, mode}. In AppEnvironment.startForecast, after ensureForecastBackend() returns .running, call preflight; if not ready, set run.reportBackendUnavailable with the joined errors (and a 'Fix in Settings' affordance) instead of starting the doomed run. Cheap (offline checks only) so it adds negligible latency.
- **Acceptance:** With a placeholder LLM_API_KEY in .env, clicking Run forecast immediately shows the actionable preflight errors in the error banner without any research subprocess starting (verify no DeerFlow child spawns server-side).

#### E3-forecast-2 — Surface the structured forecast (scenarios + probabilities) instead of only the prose report
- **Category:** enhancement · **Impact:** P1 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Interface/Forecast/ForecastReportView.swift:16`, `Swift Deep Research/Forecast/MiroFishClient.swift:182`, `Swift Deep Research/LLM/ModelProviderManager.swift:231`
- **Problem:** The backend can emit a machine-readable forecast.json with named scenarios, calibrated probabilities, key drivers, and resolution criteria (sdk.py:246 v1_forecast; forecast_extractor.py), but two things block it: (1) REPORT_STRUCTURED_FORECAST defaults to False (config.py:122) and the app's envSeed (ModelProviderManager.swift:231) never sets it, and (2) API_V1_ENABLED defaults to False (config.py:136). So the app only renders the markdown blob in ForecastReportView and discards the most decision-useful output — the probability distribution over outcomes.
- **Proposal:** In envSeed, add REPORT_STRUCTURED_FORECAST=true (and API_V1_ENABLED=true if using /api/v1, or read forecast.json via a /api/report artifact path). Add MiroFishClient.structuredForecast(reportID:) and wire/MFForecast decoding {scenarios:[{name,probability,drivers,resolution}], horizon}. Render a compact scenario-probability card at the top of ForecastReportView (bar per scenario, sorted by probability) above the markdown. This is the single highest-value UX upgrade for a 'forecast' app.
- **Acceptance:** After enabling the flag and running a full forecast, the report panel shows a scenario list with probabilities that sum to ~100% and matching resolution criteria, sourced from forecast.json; with the flag off the panel gracefully falls back to markdown-only.

#### E3-kb-1 — Pin Python dependency versions to prevent fresh-install breakage
- **Category:** out-of-box · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Knowledge/SidecarSupervisor.swift:532`, `sidecar/seekdb_sidecar.py:50-51`, `sidecar/README.md:8`
- **Problem:** The auto-bootstrap installs unpinned latest packages: `pip install pyseekdb fastapi uvicorn pydantic` (SidecarSupervisor.swift:532), and the README/error text repeat the unpinned command. This is the single biggest out-of-box time-bomb: the sidecar code is written against Pydantic v2 (UpsertBody at seekdb_sidecar.py:628 was deliberately moved to module level for 'Pydantic v2 / FastAPI' forward-ref resolution, per its own comment) and a specific pyseekdb API surface (AdminClient, DefaultEmbeddingFunction(model_name=...), get_or_create_collection(embedding_function=)). A future Pydantic v3, a FastAPI change, or a pyseekdb API rename will silently break EVERY new install while existing users (who already have a working venv) are unaffected — so the regression is invisible to the developer and only hits fresh users. There are defensive try/except fallbacks for some kwargs, but a major-version break (e.g. Pydantic v3 validation semantics) is not recoverable by those.
- **Proposal:** Pin a tested version range for each dependency in one shared constant and use it in installDependencies (e.g. `pyseekdb>=X,<Y`, `fastapi>=A,<B`, `uvicorn>=...`, `pydantic>=2,<3`). Add a `sidecar/requirements.txt` with the same pins, install via `pip install -r` when the bundled requirements file is locatable (falls back to inline pins), and update README + the Settings 'Manual setup' command (SettingsSheet.swift:1362) and the unreachable-banner command (DocumentUploadView.swift:73) to match. At minimum cap pydantic at `<3` since the code is v2-specific.
- **Acceptance:** On a fresh machine with no venv, trigger first-run install; confirm the venv pins resolve and the sidecar reaches /health. Simulate a major bump by installing pydantic 3.x manually and confirm the pin prevents it. Verify the printed/manual commands in Settings and the offline banner show the pinned versions.

#### E3-kb-2 — Move embedding-model warm-up off the startup critical path so /health binds before the ~90MB download
- **Category:** out-of-box · **Impact:** P1 · **Effort:** M · **Risk:** medium
- **Files:** `sidecar/seekdb_sidecar.py:272`, `sidecar/seekdb_sidecar.py:301-308`, `Swift Deep Research/Knowledge/SidecarSupervisor.swift:647-654`
- **Problem:** `_warm_up_embeddings()` is called synchronously inside `KnowledgeBase.__init__` (seekdb_sidecar.py:272), which runs in `main()` BEFORE `uvicorn.run()` binds the port. The warm-up embeds a string, which on first run downloads the all-MiniLM-L6-v2 sentence-transformers model (~80-90MB) from Hugging Face. So /health does not answer until the model finishes downloading. The Swift side `waitForHealthOrExit` polls only up to ~90s (SidecarSupervisor.swift:648, 180 x 0.5s). On a slow/throttled connection the model download alone can exceed 90s, after which the supervisor reports a false failure even though the process is healthy and still downloading — a fresh user on hotel/coffee-shop wifi sees 'failed' for a working install.
- **Proposal:** Start uvicorn first, then warm up the model in a background thread (or lazily on first add/query). Move `self._warm_up_embeddings()` out of `__init__` into a daemon thread started after the server is constructed, or trigger it from a FastAPI startup event so the port binds immediately and /health answers while the model loads. Optionally add a `model_ready: bool` field to /health and a `warming` state so the UI can say 'Downloading embedding model…' distinctly from 'Starting…'.
- **Acceptance:** On a fresh machine with the HF cache cleared and bandwidth throttled, launch the app; confirm /health returns 200 within a few seconds (before the model finishes) and the KB UI shows online rather than failing after 90s. First query still works once the model is ready.

#### E3-kb-8 — Guard the sidecar architecture against App Sandbox before distribution
- **Category:** out-of-box · **Impact:** P1 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Swift_Deep_Research.entitlements:1-6`, `Swift Deep Research/Knowledge/SidecarSupervisor.swift:390-459`
- **Problem:** The app's entitlements file is an empty `<dict/>` (Swift_Deep_Research.entitlements), so App Sandbox is OFF. The KB design depends on this: it spawns arbitrary Python interpreters via Process (SidecarSupervisor.swift:390+), runs perl/lsof/pip, writes a venv to Application Support, and opens an outbound localhost socket. The moment the app is sandboxed (required for Mac App Store, and a strong recommendation for notarized distribution), Process spawning of system python/perl/lsof and the pip-driven venv bootstrap will all fail, silently breaking the entire knowledge base for every distributed user. There is no detection or fallback for the sandboxed case.
- **Proposal:** Decide and document the distribution posture explicitly. If staying unsandboxed (direct-download + notarized), add a code comment and a README note that App Sandbox is intentionally disabled because the sidecar requires Process/exec; and add a runtime guard that, if a spawn fails with EPERM-like errors, reports a clear 'this build cannot launch the embedding sidecar in a sandbox' message instead of a generic failure. If MAS is a goal, the sidecar must be redesigned (XPC helper / bundled interpreter / pure-Swift embedding) — flag this as a prerequisite. At minimum, detect the sandbox at runtime (presence of APP_SANDBOX_CONTAINER_ID env) and surface an actionable message.
- **Acceptance:** Build a sandboxed variant (add com.apple.security.app-sandbox); confirm the KB shows a clear, specific 'sidecar can't run sandboxed' message rather than a generic spawn failure. In the current unsandboxed build, confirm behavior is unchanged.

#### E3-llm-2 — Omit temperature for OpenAI GPT-5/o-series so the default OpenAI provider works
- **Category:** robustness · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/LLM/OpenAICompatibleClient.swift:330-339`, `Swift Deep Research/LLM/OpenAIClient.swift:12-20`, `Swift Deep Research/Engine/WorkerAgent.swift:138`, `Swift Deep Research/Engine/Planner.swift:65`
- **Problem:** `OpenAICompatibleClient.encodeBody` always serializes `temperature` (it's a non-optional `Double` in `Body`), and every engine call site passes a non-default value (0.2–0.5). OpenAI's GPT-5 and o-series reasoning models reject any temperature other than the default 1 with HTTP 400 ('Unsupported value: temperature'). The OpenAI provider's default model is `gpt-5.5` and `OpenAIClient.models` is entirely GPT-5/4.1, so a user who selects OpenAI and adds a valid key still gets an immediate 400 on the orchestrator/worker call — the provider is broken out of the box.
- **Proposal:** Make `temperature` optional in the wire `Body` and omit it when `tokenParameter == .completion` (the OpenAI/reasoning path) or when the model id matches GPT-5/o-series (`gpt-5`, `o1`, `o3`, `o4`). Simplest: when `tokenParameter == .completion`, drop `temperature` entirely (these models ignore/forbid it). Keep sending it for legacy/third-party endpoints that expect it.
- **Acceptance:** With a valid OpenAI key and default `gpt-5.5`, a research run completes without an HTTP 400 'temperature' error; the request body for OpenAI contains no `temperature` field while DeepSeek/Kimi/etc. still include it.

#### E3-llm-3 — Respect supportsToolCalling when selecting orchestrator/worker providers
- **Category:** robustness · **Impact:** P1 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/LLM/LLMClient.swift:20`, `Swift Deep Research/LLM/FoundationModelsClient.swift:18`, `Swift Deep Research/LLM/MLXClient.swift:27`, `Swift Deep Research/Engine/WorkerAgent.swift:138`
- **Problem:** `LLMClientIdentity.supportsToolCalling` exists (false for Foundation Models and MLX) but no engine code consults it (grep finds it only in client identities and never in Engine/ or DeerFlow/). The worker loop unconditionally passes `tools: toolSpecs`. Foundation Models ignores tools entirely and just emits free text, so a worker on Foundation Models silently never calls `web_search` or `knowledge_base` — exactly the degraded mode the Ollama client's header comment warns about ('silently degrades to free-text answers'). Because `suggestedDefault` can place Foundation Models on the orchestrator (and an over-eager fix could place it on workers), this produces research with no actual tool use and no warning to the user.
- **Proposal:** Before building a run, check the resolved worker client's `identity.supportsToolCalling`; if false, either (a) surface a clear warning/hint that the chosen model can't use tools and research will be web-less, or (b) auto-route the tool-using roles (worker, DeerFlow steps) to a tool-capable provider while keeping FM for pure-text synthesis/orchestration. Pair with the `suggestedDefault` fix so FM is only used where tool-calling isn't required.
- **Acceptance:** Selecting Foundation Models as the worker provider either shows an explicit 'this model cannot call tools' warning or transparently keeps tool execution working; a run with a tool-capable worker still invokes web_search/knowledge_base as before.

#### E3-oobe-1 — Derive Keychain service name from the bundle id instead of the fork's hardcoded id
- **Category:** robustness · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Shared/KeychainStore.swift:10`
- **Problem:** The Keychain service is hardcoded to `com.aryamirsepasi.Swift-Deep-Research.keys` — the UPSTREAM FORK's bundle id. The current app's bundle id is `com.linroger.Swift-Deep-Research` (project.pbxproj:431). Confirmed: the only previously-built .app in the repo is signed `Identifier=com.aryamirsepasi.Swift-Deep-Research` with an app-sandbox entitlement, i.e. a stale fork artifact. As a constant string the keychain still functions, but (a) it's a confusing fork leftover, (b) two differently-branded builds on one Mac would collide on the same keychain item, and (c) under the App Sandbox (which the old build used and a future App Store build would need) keychain items are scoped to the app-identifier/keychain-access-group, so this mismatched service name plus an absent keychain-access-group entitlement would break key persistence entirely.
- **Proposal:** Compute the service name from the running bundle, e.g. `private let service = (Bundle.main.bundleIdentifier ?? "com.linroger.Swift-Deep-Research") + ".keys"`. Provide a one-time migration that reads any item under the old `com.aryamirsepasi...keys` service and re-writes it under the new service so existing users don't lose saved keys. Keep the fallback literal aligned with the real bundle id.
- **Acceptance:** Build under the current bundle id, save an Anthropic key in Settings, quit and relaunch: the key persists and `refreshKeyStatus()` clears the missing-key banner. `security find-generic-password -s com.linroger.Swift-Deep-Research.keys` shows the item under the correct service.

#### E3-oobe-2 — Add a Developer ID signed + notarized DMG release path so downloads run without Gatekeeper friction
- **Category:** out-of-box · **Impact:** P1 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research.xcodeproj/project.pbxproj:406`, `Swift Deep Research.xcodeproj/project.pbxproj:444`, `README.md:239`
- **Problem:** The release config uses `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` (ad-hoc) and the only built .app in the repo is `Signature=adhoc, TeamIdentifier=not set`. An ad-hoc-signed, un-notarized app downloaded as a .dmg/.zip carries the quarantine bit and Gatekeeper blocks it as "damaged" or "from an unidentified developer" — a hard stop for a fresh user. README §239 'Getting started' only documents building from Xcode; there is no signed-DMG distribution path, no `create-dmg`/`xcrun notarytool` script, and no guidance on right-click-Open or `xattr -dr com.apple.quarantine`.
- **Proposal:** A DEVELOPMENT_TEAM (X8AD8YC886) is already set, so flip the Release config to a Developer ID Application identity, add a `scripts/release.sh` that archives, exports with `-exportOptionsPlist`, staples with `xcrun notarytool submit ... --wait` + `xcrun stapler staple`, and packages a DMG (e.g. via `create-dmg`). Document the resulting flow in README. If signing isn't yet available, at minimum add a README 'Open a downloaded build' section with the right-click-Open / quarantine-removal steps.
- **Acceptance:** Run `scripts/release.sh`, copy the produced DMG to a second Mac (or remove and re-add the quarantine attr), double-click the app: it launches with no Gatekeeper warning. `spctl -a -vvv "Swift Deep Research.app"` reports `accepted, source=Notarized Developer ID`.

#### E3-oobe-5 — Fix the empty default research config when neither Foundation Models nor an Anthropic key is present
- **Category:** out-of-box · **Impact:** P1 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Engine/EngineConfiguration.swift:129`, `Swift Deep Research/Interface/AppEnvironment.swift:308`
- **Problem:** `suggestedDefault()` sets orchestrator to Foundation Models when available, but ALWAYS sets worker and synthesis to `.anthropic` (claude-sonnet-4). For a fresh user on a Mac without Apple Intelligence and without an Anthropic key, the very first run is doomed. The `missingKeyHint` banner (AppEnvironment.swift:316) correctly catches the worker case and tells them to add a key OR switch to a local model — good — but it does NOT detect the synthesis provider's missing key, and it offers no zero-config path: a fresh user with Ollama/LM Studio installed still has to manually re-point all three roles. There's no auto-detection of a locally reachable Ollama/LM Studio to make the default config runnable with zero keys.
- **Proposal:** Two improvements: (1) Extend `refreshKeyStatus()` to also check the synthesis/orchestrator providers' keys so the banner reflects the true first-failing role. (2) In `suggestedDefault()` (or a one-time first-run probe), if Foundation Models is unavailable, probe the default Ollama (localhost:11434) / LM Studio (localhost:1234) hosts and, if reachable, default all three roles to that local provider so the app is usable with zero keys and zero configuration.
- **Acceptance:** On a Mac with no Apple Intelligence, no API keys, and Ollama running locally, a fresh first launch can submit a suggestion-chip query and get a result without opening Settings. On a Mac with nothing local, the banner names the actual missing key and the suggestion chips route to Settings.

#### E3-sec-1 — Re-check redirect targets against URLSafety to close the SSRF bypass
- **Category:** security · **Impact:** P1 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Shared/Logging.swift:49`, `Swift Deep Research/Shared/URLSafety.swift:14`, `Swift Deep Research/ResearchTools/WebReaderTool.swift:54`, `Swift Deep Research/ResearchTools/PDFReaderTool.swift:47`
- **Problem:** URLSafety.blockReason is only run on the URL the LLM supplies. The URLSession built by HTTPClientCommon.defaultSession (Logging.swift:49) uses default redirect handling, so a public page that 302-redirects to http://169.254.169.254/ (cloud metadata), http://127.0.0.1:5001/ (the app's own MiroFish backend), or http://localhost:9100/ (SeekDB) is followed without re-validation. There is no URLSessionTaskDelegate.willPerformHTTPRedirection anywhere in the codebase (grep returned nothing). Because a deep-research agent fetches whatever URL web content steers it toward, indirect prompt injection can place a redirect on a public host and reach internal services. This is a distinct vector from the DNS-rebinding gap already documented in URLSafety.swift:11-16.
- **Proposal:** Add a small URLSessionTaskDelegate that implements urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) and returns nil (cancel) when URLSafety.blockReason(for: newRequest.url) is non-nil; otherwise pass newRequest through. Wire this delegate into HTTPClientCommon.defaultSession so every research-tool fetch (WebReader static path, PDF, Reddit) inherits it. Keep redirects enabled for safe public hops. The delegate is Sendable-friendly since URLSafety is a pure static enum.
- **Acceptance:** Stand up a local server that returns 302 Location: http://169.254.169.254/ and another returning 302 to http://127.0.0.1:5001/, call fetch_url/read_pdf on the public redirector, and confirm the fetch fails with an SSRF-block message instead of returning internal content. Confirm a normal http(s)→http(s) public redirect (e.g. a shortener) still resolves.

#### E3-sec-2 — Guard the WKWebView JavaScript-render path against redirect/JS navigation to private hosts
- **Category:** security · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/ResearchTools/WebReaderTool.swift:247`, `Swift Deep Research/ResearchTools/WebReaderTool.swift:304`
- **Problem:** The JS fallback (HiddenWebView.load at WebReaderTool.swift:247, extractJavaScript at :304) loads the URL into a WKWebView that runs arbitrary remote JavaScript. The class implements only WKNavigationDelegate completion callbacks; it does NOT implement webView(_:decidePolicyFor navigationAction:decisionHandler:). So a page that server-redirects or client-side window.location-navigates to http://localhost:5001/ or http://169.254.169.254/ is rendered and its innerText returned — bypassing the up-front URLSafety check entirely on the most powerful (script-executing) fetch path.
- **Proposal:** Add decidePolicyFor navigationAction to HiddenWebView: call decisionHandler(URLSafety.isFetchable(action.request.url) ? .allow : .cancel) so every navigation (initial, redirect, and JS-initiated) is re-validated. Already-good ceilings (nonPersistent store, 20s watchdog, 200k innerText cap) stay. This complements the URLSession redirect delegate above so both fetch paths enforce the same policy.
- **Acceptance:** Serve a public HTML page whose inline script sets window.location='http://127.0.0.1:5001/'; force javascript=true on fetch_url; confirm the navigation is cancelled and no internal content is returned. Verify a legitimate SPA that loads only public assets still renders to text.

#### E3-storage-1 — Stop persisting write-only StoredSource.fullText (or move to external storage)
- **Category:** performance · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchSchema.swift:92`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:209`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:220`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Interface/SourcePanel.swift:354`
- **Problem:** StoredSource.fullText stores the COMPLETE extracted article text for every fetched source of every session (upsertSource writes fetched.extractedText at ResearchStore.swift:209/220). A grep of the whole codebase shows fullText is never read anywhere — the restored-session inspector (StoredSourceRow, SourcePanel.swift:354) only shows title/url/snippet; only the in-memory live FetchedSource shows extractedText. So fullText is pure write amplification: a 'thorough' run can fetch 6 workers × 12 sources × tens-of-KB of article text, all written into the main SQLite store (inline, since there is no .externalStorage attribute) and never used. Over many runs the store grows into hundreds of MB, slowing every coalesced save (the whole row is rewritten on upsert) and every fetch.
- **Proposal:** Either (a) drop fullText from StoredSource entirely (the live engine already has the text via FetchedSource and the cache layer; nothing reads it back), or (b) if a future 'reopen full source text' feature is intended, annotate it `@Attribute(.externalStorage) public var fullText: String` so SwiftData keeps the large blob out of the SQLite row and out of every fault. Option (a) is cleanest. Pair with a SchemaMigrationPlan or accept the existing destroy-and-rebuild fallback for the schema change.
- **Acceptance:** After several research runs, inspect the .store file size under ~/Library/.../DeepResearch.v2 before/after the change for the same workload; size growth per source drops to title+snippet only. Reopen a stored session and confirm the inspector still renders identically (it never used fullText).

#### E3-storage-2 — Eliminate write-only event snapshots (double JSON write) or actually use them for replay
- **Category:** performance · **Impact:** P1 · **Effort:** M · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:347`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchSchema.swift:159`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchSchema.swift:186`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchEventSnapshot.swift:172`
- **Problem:** appendEvent(event:...) encodes a full ResearchEventSnapshot to JSON and stores it into BOTH payloadJSON and eventPayloadJSON (ResearchStore.swift:358-360) — the same large blob written twice per event. StoredEvent.decodedSnapshot and ResearchEventSnapshot.event (the entire reconstruction path) are never called outside Storage: grep shows zero consumers of decodedSnapshot, StoredEvent, or session.events in Interface/. So every meaningful event during a run triggers a JSONEncoder pass plus two copies of the payload persisted, all of which is dead — the UI reconstructs sessions only from turns/sources/citations. This is the dominant per-save cost on long runs and unbounded storage growth, for a replay feature that doesn't exist.
- **Proposal:** Pick one: (a) If event replay is not on the roadmap, store only kind+summary+sequence (drop both JSON payloads) — or remove StoredEvent persistence entirely from the hot path. (b) If replay IS planned, stop double-writing: store the snapshot once in eventPayloadJSON, leave payloadJSON empty for new rows (decodedSnapshot already handles nil-payload legacy rows), and add the read path (e.g., a timeline tab that calls decodedSnapshot). Today's behavior is the worst of both: full cost, no benefit.
- **Acceptance:** Run a 'thorough' session; confirm no decodedSnapshot/payloadJSON regression in any visible feature (there are no consumers). Measure save latency / store growth per event before vs after; both drop substantially.

#### E3-storage-3 — Narrow the destroy-the-whole-store launch fallback so transient errors don't wipe history
- **Category:** robustness · **Impact:** P1 · **Effort:** M · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:99`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:122`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Bootstrap/SwiftDeepResearchApp.swift:11`
- **Problem:** makeContainer() catches ANY error from ModelContainer init and unconditionally calls destroyStore() (deletes the .store, -wal, -shm), then recreates empty. The comment assumes the only cause is a schema mismatch, but the catch also fires on recoverable conditions: disk full, the file briefly locked by a previous instance / Spotlight / Time Machine, a permissions hiccup, or a corrupt-but-recoverable WAL. In all those cases the user's entire research history is irreversibly deleted on the next launch with no prompt and no backup. There is also no VersionedSchema/SchemaMigrationPlan, so every future @Model change deliberately relies on this nuke path even for data that could migrate losslessly.
- **Proposal:** Before destroying, copy the store files to a sibling backup (e.g. DeepResearch.v2.corrupt-<timestamp>) so a wipe is recoverable, and log the path. Optionally retry init once after a short delay to ride out transient file locks before deciding the store is truly incompatible. Longer term, introduce a VersionedSchema + lightweight SchemaMigrationPlan so additive changes migrate instead of wiping. SwiftDeepResearchApp.swift:11 should surface the rebuild to the user rather than silently swallow it.
- **Acceptance:** Simulate a locked store (open the file exclusively, or set the store dir read-only) and launch: history is preserved (no silent wipe) or a recoverable backup exists. After an intentional incompatible schema change, a .corrupt backup file appears alongside the rebuilt empty store.

#### E3-ux-1 — Cancel the live run when starting New Research from the toolbar and command-N
- **Category:** robustness · **Impact:** P1 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/MainScene.swift:72-85`, `Swift Deep Research/Bootstrap/SwiftDeepResearchApp.swift:30-37`, `Swift Deep Research/Interface/ResearchCanvas.swift:87-95`, `Swift Deep Research/Interface/AppEnvironment.swift:301-303`
- **Problem:** Two of the three New Research entry points drop env.live without cancelling the in-flight engine. The toolbar button (MainScene.swift:72-85) sets env.live = nil directly, and the app-level CommandGroup (SwiftDeepResearchApp.swift:31-36) does env.live = nil; env.selectedSessionID = nil. Neither calls env.cancelLive(). ResearchCanvas.newSession() (line 88-95) documents exactly this hazard and calls env.cancelLive() first 'otherwise an in-progress run's streamTask keeps streaming, persisting, and spending budget detached (orphaned) with no way for the user to stop it.' So mid-run, pressing command-N (which the OS routes to the CommandGroup, not the toolbar) or clicking the toolbar New Research leaks a run that keeps consuming the user's paid API budget invisibly. LiveSession.deinit cancels, but the orphaned Task captures self via the streaming loop, so it is not deallocated while streaming.
- **Proposal:** Route all three entry points through a single AppEnvironment.newResearchSession() that calls cancelLive() before clearing live/selectedSessionID/inspector state. Replace the toolbar closure and the CommandGroup body with a call to that method; have ResearchCanvas.newSession() call it too. This makes the cancel-first invariant live in one place.
- **Acceptance:** Start a thorough run; while workers are active press command-N. Verify (via Activity/logs and the network) that the previous run's streaming stops immediately and no further tokens are billed; the new welcome/composer appears with no background activity.

### P2 — 27 item(s)

#### E3-engine-5 — Feed the citation auditor the same source window it grounds against (not the first 4k)
- **Category:** improvement · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/ResearchTools/CitationExtractor.swift:20`, `Swift Deep Research/ResearchTools/CitationExtractor.swift:74`, `Swift Deep Research/ResearchTools/WebReaderTool.swift:110`
- **Problem:** WebReaderTool stores up to 20,000 chars of extractedText per source, but CitationExtractor builds its prompt corpus by clipping each source to only the first 4,000 chars (line 23). The verbatim-grounding gate (line 74) compares quotes against the FULL extractedText, so the asymmetry means the auditor LLM can only PROPOSE quotes from the first 4k of each page; any load-bearing claim supported by text in chars 4,001–20,000 simply never gets cited (the auditor can't see it). On long articles/PDFs this drops a large fraction of legitimate citations, weakening the headline 'cited answer' value prop.
- **Proposal:** Raise the per-source corpus clip (e.g. to ~8–12k) and/or budget the total corpus across sources (clip = maxCorpus / sources.count, floored) so the auditor sees a representative span of each source rather than only its lede. Keep the grounding check on full text. If token cost is a concern, scale the clip with the number of sources so the total prompt stays bounded.
- **Acceptance:** Construct a source whose only supporting sentence for a draft claim sits past char 4,000; confirm the extractor now produces a grounded citation for it, and that total corpus size stays within a sane token bound for a 6-source run.

#### E3-engine-6 — Use the planner's complexity/token estimate to scale the run instead of discarding it
- **Category:** optimization · **Impact:** P2 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Domain/ResearchPlan.swift:108`, `Swift Deep Research/Engine/ResearchEngine.swift:131`, `Swift Deep Research/Domain/AgentBudget.swift:11`
- **Problem:** ResearchPlan carries estimatedComplexity (trivial/moderate/complex/expansive) and estimatedTokenBudget, both required by the planner schema and decoded, but they are never read to influence the run — they are only copied through when rebuilding the plan (ResearchEngine.swift:269-270). The engine fans out a fixed maxWorkers regardless, so a 'trivial' lookup spins up the same worker count and source target as an 'expansive' query, wasting tokens/latency on simple questions and under-investing capacity that the planner itself flagged as needed on hard ones.
- **Proposal:** Map estimatedComplexity to a per-round worker/source scaling factor within the configured budget caps: e.g. trivial → 1 worker + lower sourceTarget; expansive → use the full maxWorkers and maxSourcesPerWorker. Keep budget caps as hard ceilings (never exceed config.budget). This makes 'fast/standard/thorough' adapt to question difficulty rather than treating every query identically.
- **Acceptance:** Run a trivial lookup ('what is the capital of France') and confirm fewer workers/sources are dispatched than for an expansive comparative query, with both still bounded by the active budget; verify total tokens drop measurably on the trivial case.

#### E3-engine-7 — Keep thorough (6-round) runs from collapsing early when the reflector is quiet
- **Category:** improvement · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Engine/ResearchEngine.swift:218`, `Swift Deep Research/Engine/ResearchEngine.swift:422`, `Swift Deep Research/Engine/ResearchEngine.swift:460`
- **Problem:** synthesizeDeepeningSubtasks rotates a 3-wide window over a 9-angle pool keyed on round (base = (round-2)*3). For a thorough run the fallback is invoked with round 2,3,4,5,6 → bases 0,3,6,9,12. base 9 and 12 wrap to indices that repeat angles already dispatched (e.g. base 12 → angles 3,4,5 reused), which the dispatched-question dedup then filters to empty, ending the loop via the 'candidates.isEmpty' break. So a thorough run with a consistently low-yield reflector can terminate around round 4–5 instead of 6, quietly collapsing the depth difference the mode promises. The pool (9 angles) is too small to supply 5 disjoint windows of 3.
- **Proposal:** Either (a) expand the angle pool to ≥ 3 * (maxThoroughReflectionPasses) distinct angles so every fallback round draws fresh directions, or (b) when a wrapped window would fully duplicate dispatched questions, mutate the angles (append a round-specific qualifier such as the round number or a rotating sub-facet) so they survive dedup and still contribute a distinct round. Keep the existing disjoint behavior for rounds 2–4.
- **Acceptance:** Run the native engine in thorough mode with a stub reflector that always returns empty gaps; confirm 6 distinct iterationStarted rounds fire (currently it terminates early) and that each fallback round dispatches non-duplicate subtasks.

#### E3-forecast-10 — Pre-warn first-run users about the one-time ~470MB embedding model download
- **Category:** out-of-box · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/Forecast/ForecastComposer.swift:159`, `Swift Deep Research/Forecast/ForecastRun.swift:367`, `Swift Deep Research/Interface/Forecast/KnowledgeGraphView.swift:1`
- **Problem:** The graph stage triggers a one-time ~470MB multilingual embedding model download (documented in ForecastOnboarding.swift:128 and SettingsSheet.swift:1627). On the very first forecast, the graph stage can appear stalled for a long time with no explanation while the model downloads; the pipeline view shows a generic running spinner. A fresh user may think the app hung and cancel. The deep preflight probe (preflight.py deep_probes, embed-model cache) can detect whether the model is already cached.
- **Proposal:** When the graph stage is running on a machine where preflight (deep) reports the embed model is not yet cached, show an explicit 'First run: downloading the ~470MB embedding model once — this can take several minutes' note in the graph stage / pipeline header. Optionally offer to pre-download via preflight?deep=true&pull=true during onboarding's launch step so the first real forecast isn't blocked on it.
- **Acceptance:** On a clean machine, the first forecast's graph stage shows the embedding-model download notice; on a second run (model cached) the notice does not appear.

#### E3-forecast-3 — Add 'Continue to full forecast' for completed research_only runs
- **Category:** enhancement · **Impact:** P2 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Forecast/ForecastRun.swift:20`, `Swift Deep Research/Interface/Forecast/ForecastReportView.swift:32`, `Swift Deep Research/Forecast/MiroFishClient.swift:125`
- **Problem:** The composer offers a 'Research only' mode (ForecastComposer.swift:99) that produces just the cited dossier, and the backend has POST /api/research/<id>/continue (research.py:164) to promote a completed research_only pipeline into a full forecast while reusing the research artifacts. But the app provides no way to invoke it — a user who runs research-only and likes the dossier must start a whole new full run from scratch, re-paying for the research stage.
- **Proposal:** Add MiroFishClient.continuePipeline(_:) → POST /<id>/continue (mirrors resumePipeline). In ForecastRun add continueToFull() guarded by mode == .research_only && phase == .completed, which flips the local stage list to full and starts a poll loop. Surface a 'Continue to full forecast' button in the research_only completed state (ForecastReportView/ResearchConsoleView). Run preflight(mode: .full) first since continue runs graph/sim/report.
- **Acceptance:** Run a research_only forecast to completion, click 'Continue to full forecast', and confirm the graph/simulation/report stages run without re-executing deep research (research stage stays completed, no new DeerFlow subprocess).

#### E3-forecast-4 — Add what-if scenario forking from a completed forecast
- **Category:** enhancement · **Impact:** P2 · **Effort:** L · **Risk:** medium
- **Files:** `Swift Deep Research/Forecast/MiroFishClient.swift:125`, `Swift Deep Research/Interface/Forecast/ForecastPipelineView.swift:134`
- **Problem:** The backend supports POST /api/research/<id>/scenario (research.py:199) to fork a what-if pipeline at the PREPARE stage — reusing the base research/ontology/graph and only re-running prepare/run/report with influence_overrides, stance_overrides, injected_events, and as_of_shift. This is the marquee capability of a society-simulation forecaster (cheap counterfactual exploration without rebuilding the graph) and is entirely absent from the app.
- **Proposal:** Add MiroFishClient.forkScenario(_:overlay:) posting {label, max_rounds?, influence_overrides, stance_overrides, injected_events, as_of_shift}. Add a 'Fork scenario…' control in ForecastPipelineView controls (enabled when phase == .completed && mode == .full) opening a sheet to set a label and per-actor influence/stance overrides (the dossier already exposes actorList for the picker). On fork, import the returned pipeline_id as a new ForecastRecord and open it. Start with label + influence/stance overrides; injected_events can be a follow-up.
- **Acceptance:** From a completed forecast, fork a scenario with one actor's influence raised; confirm a new pipeline appears that skips research/graph (reused) and only re-runs prepare/run/report, producing a different report.

#### E3-forecast-7 — Show a live readiness panel in Settings using preflight format=full
- **Category:** ux · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/SettingsSheet.swift:1626`, `Swift Deep Research/Forecast/MiroFishClient.swift:47`
- **Problem:** Settings → Forecast shows only backend up/down status and a static 'knowledge graph runs locally' note. The backend offers GET /api/research/preflight?format=full[&deep=true] returning structured checks [{id, severity, ok, message, fix}] plus provider/deerflow_model/graph_backend/embed_model (preflight.py:73, research.py:301), which is exactly a renderable readiness dashboard. The app's onboarding ForecastOnboarding.refreshChecks() re-derives much of this client-side from .env parsing (ForecastOnboarding.swift:68) — duplicating logic the backend already authoritatively computes and risking drift.
- **Proposal:** Add MiroFishClient.preflightReport() → /preflight?format=full and an MFPreflightReport model. When the backend is running, render a checklist in Settings → Forecast (and reuse it in onboarding step 1 once the backend is up) showing each check's ok/severity/message with the embedded fix. This makes the readiness panel authoritative and surfaces the deep probes (embed-model cache, disk) the client-side checks can't see.
- **Acceptance:** With the backend running and a placeholder key, Settings → Forecast shows a red check with the backend's exact remediation text; fixing the key and re-checking turns it green — matching what POST /run would gate on.

#### E3-kb-3 — Detect and message the offline/no-network first-run case distinctly from 'deps broken'
- **Category:** out-of-box · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Knowledge/SidecarSupervisor.swift:530-539`, `Swift Deep Research/Knowledge/SidecarSupervisor.swift:148`, `Swift Deep Research/Interface/DocumentUploadView.swift:65-91`
- **Problem:** Both first-run paths require the network: the pip install (SidecarSupervisor.swift:532) and the embedding-model download. If a fresh user is offline, pip fails and `installDependencies` returns false, surfacing as `.notInstalled` with a raw pip tail. The UI then shows the generic 'Couldn't start the embedding sidecar' card (DocumentUploadView.swift:67) telling the user to run a pip command — which will also fail offline. There is no detection of 'you have no internet' versus 'your Python is broken', so the actionable guidance is wrong for the most common fresh-install failure.
- **Proposal:** In installDependencies, scan the pip output tail for offline signatures ('Could not find a version', 'Temporary failure in name resolution', 'Failed to establish a new connection', 'Network is unreachable', 'Connection timed out', 'getaddrinfo failed') and return a distinct status/message like 'No internet connection — the knowledge base needs to download Python packages and an embedding model once. Connect to the internet and click Reinstall.' Surface that as a dedicated case in the DocumentUploadView banner so the user gets the correct fix instead of a pip command that can't succeed offline.
- **Acceptance:** Disable networking on a machine without the venv, open the KB; confirm the banner says it needs internet (not a pip command). Re-enable networking and Reinstall; confirm it completes.

#### E3-kb-4 — Apply a relevance-score floor (and per-document diversity) to KB retrieval
- **Category:** enhancement · **Impact:** P2 · **Effort:** M · **Risk:** medium
- **Files:** `sidecar/seekdb_sidecar.py:529-556`, `Swift Deep Research/ResearchTools/KnowledgeBaseTool.swift:40-66`
- **Problem:** `/query` returns the top-k chunks unconditionally (seekdb_sidecar.py:536-556) with no relevance threshold; the KnowledgeBaseTool passes them all to the worker LLM verbatim (KnowledgeBaseTool.swift:58-64). For an off-topic question against a small KB, the vector store still returns its k 'least-bad' chunks with low scores, and the tool reports them as real hits and emits them as discovered/fetched sources (KnowledgeBaseTool.swift:45-55). The worker is then nudged to cite irrelevant private passages instead of falling through to web_search — degrading answer quality and citation trust. There is also no diversity guard, so all k results can come from one large document, crowding out other relevant docs.
- **Proposal:** Add an optional `min_score` to the /query body (default e.g. 0.30 on the 1/(1+d) scale) and drop hits below it server-side, OR filter in KnowledgeBaseTool after the call. When the filtered set is empty but raw hits existed, set the existing `note` to 'matches were below the relevance threshold — rely on web_search' so the worker behaves like the empty-KB case. Additionally cap chunks-per-document (e.g. 2) before returning, to diversify across documents. Keep the threshold conservative and configurable so it never suppresses genuinely relevant small-KB hits.
- **Acceptance:** Query an off-topic question against a KB of 1-2 docs; confirm low-score chunks are dropped and the tool tells the worker to use web_search instead of returning junk. Query an on-topic question; confirm relevant hits still return and no single doc monopolizes all k slots.

#### E3-kb-6 — Set HF_HOME/TRANSFORMERS cache to Application Support so the embedding model persists with app data
- **Category:** robustness · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `sidecar/seekdb_sidecar.py:301-308`, `Swift Deep Research/Knowledge/SidecarSupervisor.swift:466-476`
- **Problem:** The embedding model is downloaded by sentence-transformers/huggingface into the default `~/.cache/huggingface` (the child env in childEnvironment() at SidecarSupervisor.swift:466 sets only PATH and PYTHONUNBUFFERED). This means: (a) the model lives outside the app's own ~/Library/Application Support/SwiftDeepResearch tree, so a user who 'cleans' ~/.cache forces a silent re-download on next launch (looks like a hang); (b) the model location isn't co-located with the seekdb data it must stay compatible with; and (c) there's no way for the app to ship a pre-warmed cache or to clear/repair just the model.
- **Proposal:** In childEnvironment(), set `HF_HOME` (and/or `TRANSFORMERS_CACHE` / `SENTENCE_TRANSFORMERS_HOME`) to a stable subdir under appSupportDir (e.g. .../SwiftDeepResearch/hf-cache). This keeps the model alongside the venv and seekdb data, makes 'reinstall/repair' able to manage it, and makes the download location predictable for support. Also enables an optional future 'ship a pre-downloaded model' optimization.
- **Acceptance:** Launch on a fresh machine; confirm the model downloads under ~/Library/Application Support/SwiftDeepResearch/hf-cache (not ~/.cache/huggingface), and that deleting ~/.cache does not trigger a re-download on next launch.

#### E3-kb-7 — Add a localhost-only shared-secret token between app and sidecar
- **Category:** security · **Impact:** P2 · **Effort:** M · **Risk:** medium
- **Files:** `sidecar/seekdb_sidecar.py:644-747`, `sidecar/seekdb_sidecar.py:88-92`, `Swift Deep Research/Knowledge/SeekDBClient.swift:185-191`
- **Problem:** The sidecar is unauthenticated (seekdb_sidecar.py header: 'no auth — bound to localhost only'). Any local process or any web page that can reach 127.0.0.1:9100 can read every ingested document via /query and /documents, or wipe the KB via /reset and DELETE. The code's own comment at seekdb_sidecar.py:89-91 flags this as a recommended follow-up. For a research tool whose entire value is the user's PRIVATE documents (papers, notes), a same-machine DNS-rebinding or a malicious local helper exfiltrating the KB is a realistic privacy risk, and /reset is destructive with no auth.
- **Proposal:** Generate a random per-launch token in SidecarSupervisor, pass it to the child via env (e.g. SEEKDB_TOKEN) and to SeekDBClient, require it as a header (e.g. Authorization: Bearer / X-Sidecar-Token) in the sidecar middleware (alongside the existing body-size middleware at seekdb_sidecar.py:647), and reject mismatches with 401. Also add a Host-header / Origin check to block DNS-rebinding from browsers. This is the cross-process change the existing TODO anticipated; keep it backward compatible by skipping the check when no token env is set (manual runs).
- **Acceptance:** With the token wired, confirm the app's requests succeed and a raw `curl 127.0.0.1:9100/documents` (no token) returns 401. Confirm /reset and DELETE also require the token. Manual `python3 seekdb_sidecar.py` (no token env) still serves for dev.

#### E3-kb-9 — Bound model-warm-up wait independently so first-run health timeout reflects download, not just bind
- **Category:** robustness · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Knowledge/SidecarSupervisor.swift:639-654`, `sidecar/seekdb_sidecar.py:269-272`
- **Problem:** `waitForHealthOrExit` uses one fixed ~90s ceiling for everything (SidecarSupervisor.swift:648). On first run that single budget must cover: process spawn, OceanBase engine init + create_database + get_or_create_collection (the comment at 642-646 already notes this is slow), AND (because warm-up is on the critical path, see related finding) the embedding-model download. If any combination overruns 90s, the supervisor declares failure while the process is still legitimately working, and there is no 'still making progress' signal to extend the wait. The wait is also blind to whether the slowness is the model download vs a real wedge.
- **Proposal:** Once the warm-up is moved off the bind path (companion finding), /health can answer quickly and this ceiling becomes safe. If warm-up stays inline as an interim, extend the first-run ceiling (e.g. detect 'no venv existed before this launch' / first boot and allow ~5 min) and/or poll a `model_ready`/progress signal from a richer /health so the wait only fails when the process actually exits or stops making progress, not on a fixed clock.
- **Acceptance:** On a fresh, bandwidth-throttled machine, first launch reaches a healthy KB without a spurious timeout failure; a genuinely wedged process (kill -STOP) is still reported as failed within a bounded time.

#### E3-llm-4 — Default the Forecast provider to something keyless or guide before it's needed
- **Category:** out-of-box · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/LLM/ModelProviderManager.swift:109-117`, `Swift Deep Research/LLM/ModelProviderManager.swift:206-227`
- **Problem:** `ModelProviderManager.init` defaults `forecastAssignment` to `.minimax`, which has `requiresAPIKey == .minimax`. A fresh user opening the Forecast workspace and pushing the provider gets `failed('MiniMax … needs an API key')`. MiniMax is an unusual default (region-locked domestic host per the registry comments) and not a sensible first choice for a US/EU user with no key.
- **Proposal:** Default `forecastAssignment` to the same provider the main engine resolves to (read from the persisted `EngineConfiguration` if available), or to a keyless local option (Ollama/LM Studio) when one is detected, falling back to Anthropic/OpenAI only if a key for them already exists. Avoid defaulting to a region-locked, key-required provider the user never chose.
- **Acceptance:** On a clean install, opening Forecast and pushing the provider does not immediately fail with a MiniMax-key error; the default forecast provider matches a provider the user can actually use without extra setup.

#### E3-llm-5 — Stop hardcoding Ollama num_ctx at 128k to avoid OOM on small Macs
- **Category:** robustness · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/LLM/OllamaClient.swift:241-251`, `Swift Deep Research/LLM/OllamaClient.swift:297-305`
- **Problem:** `encodeBody` always sends `options.num_ctx = 131_072`. Ollama allocates a KV cache sized to num_ctx regardless of prompt length, so forcing 128k on an 8B model can demand many extra GB of RAM/VRAM and OOM or thrash on the very 8–16GB Macs that are the target audience for local inference. The comment claims Ollama 'will clamp to the model's actual capacity if smaller', but it does not clamp downward to fit available memory — it tries to allocate the requested window. This makes the local-first path the least robust on low-RAM machines.
- **Proposal:** Lower the default to a safer value (e.g. 16k–32k) and/or make it configurable per model, or derive it from `request` size with a sane ceiling. Optionally probe `/api/show` for the model's `context_length` and request the min(modelMax, configuredCeiling). At minimum, expose it in EngineConfiguration so users on small Macs can reduce it.
- **Acceptance:** Running a query against a small Ollama model on a 16GB Mac does not spike to multi-GB extra memory from KV-cache over-allocation; the context window used is reasonable for the prompt and configurable.

#### E3-llm-8 — Auto-test/populate model lists for configured providers on first open of Settings
- **Category:** enhancement · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/LLM/ModelDiscovery.swift:59-91`, `Swift Deep Research/Interface/AppEnvironment.swift:305-320`
- **Problem:** `ModelDiscovery.fetchModels` cleanly doubles as a key test, but it's only invoked behind the manual 'Test & fetch models' button. Hardcoded `availableModels` lists go stale (e.g. registry names like `gpt-5.5`, `claude-sonnet-4-20250514`, `MiniMax-M3` are fixed strings that won't track new releases) and a fresh user must know to click the button to see what's actually available with their key. The only first-run signal is `missingKeyHint`, which checks presence but not validity.
- **Proposal:** When a key is present for the active provider and Settings opens (or after a key is saved), kick off a background `fetchModels` to (a) validate the key and (b) refresh the model picker from the live catalogue, caching the result. Show a subtle 'verified / N models' or precise error inline. This both validates keys proactively and keeps model lists current without manual action.
- **Acceptance:** After saving a valid key, the provider's model list populates automatically from the live API and an invalid key shows a precise error, without the user clicking 'Test & fetch models'.

#### E3-oobe-3 — Boot the SeekDB Python sidecar lazily instead of at every app launch
- **Category:** ux · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/MainScene.swift:129`, `Swift Deep Research/Knowledge/SidecarSupervisor.swift:86`
- **Problem:** MainScene's `.task` calls `SidecarSupervisor.shared.ensureRunning(...)` on every launch (MainScene.swift:136). For a fresh user with no Python deps this can trigger a `python3 -m venv` + `pip install pyseekdb fastapi uvicorn pydantic` (SidecarSupervisor.swift:530) — a multi-second, network-dependent install — on first launch even though they may only want to run a web research query and never open the Knowledge Base (which defaults off: `useKnowledgeBase=false`, EngineConfiguration.swift:80). It spawns `/usr/bin/perl`, `/usr/bin/env`, and a Python interpreter as child processes immediately, which is surprising background activity for a fresh install and wasted work for the majority path.
- **Proposal:** Make sidecar boot lazy: trigger `ensureRunning` the first time the user opens the Knowledge Base sheet (showDocuments) OR enables `useKnowledgeBase` in Settings, rather than unconditionally in MainScene's launch `.task`. Keep `refreshKeyStatus()` in the launch task. Optionally add a Settings toggle 'Start knowledge base at launch' (default off) so power users keep the warm-start behavior.
- **Acceptance:** Fresh launch with no Python deps installed: no python/perl child processes appear (verify with Activity Monitor / `pgrep -f seekdb_sidecar`) and no pip install runs. Opening the Knowledge Base sheet for the first time starts the sidecar and shows its status.

#### E3-oobe-4 — Wire MARKETING_VERSION / CURRENT_PROJECT_VERSION to real version numbers
- **Category:** code-health · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research.xcodeproj/project.pbxproj:430`, `Swift Deep Research.xcodeproj/project.pbxproj:447`, `Swift Deep Research.xcodeproj/project.pbxproj:468`
- **Problem:** Both Debug and Release are pinned to `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` (confirmed in the built Info.plist: CFBundleShortVersionString=1.0, CFBundleVersion=1). The README describes 'v2.0' features (MLXClient.swift:5 'v2.0 ships with...') so the visible version is already wrong, and a constant build number means every distributed build looks identical to Gatekeeper/notarization and to crash-report grouping — and `notarytool` rejects re-uploads with a duplicate build number.
- **Proposal:** Bump MARKETING_VERSION to the real release (e.g. 2.0) and either auto-increment CURRENT_PROJECT_VERSION (an `agvtool`/build-script bump, or `$(date +%Y%m%d%H%M)`) in the release script so each notarized build is unique. Surface the version in the Settings → About section for user-visible confirmation.
- **Acceptance:** Two consecutive release builds produce distinct CFBundleVersion values; Settings → About shows the current MARKETING_VERSION; a second notarytool submission of an incremented build is accepted.

#### E3-oobe-7 — Make the Forecast default backend path discoverable instead of a hardcoded ~/Downloads path
- **Category:** out-of-box · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Forecast/ForecastModels.swift:182`, `Swift Deep Research/Interface/AppEnvironment.swift:41`
- **Problem:** `ForecastConfiguration.suggestedDefault()` hardcodes `repoRootPath = home + "/Downloads/DeepResearchForecast"` (ForecastModels.swift:184). For essentially every fresh user this path does not exist, so the Forecast workspace's auto-launch (`autoLaunchBackend=true`) will report `backendMissing`. The auto-presenting onboarding assistant (AppEnvironment.swift:51) mitigates this, but the default still assumes a very specific manual checkout location and won't find a repo placed elsewhere (e.g. a common `~/Developer` or alongside this repo).
- **Proposal:** Probe a small set of likely locations at first Forecast open (e.g. `~/Downloads/DeepResearchForecast`, `~/Developer/DeepResearchForecast`, sibling of this repo, `~/DeepResearchForecast`) and pick the first that exists; fall back to the onboarding assistant which already offers a folder picker + `setup.sh` runner. Persist the chosen path. Optionally let the onboarding assistant clone the repo when none is found.
- **Acceptance:** With a DeepResearchForecast checkout placed in any of the probed locations, opening the Forecast workspace finds it without manual path entry; with none present, the onboarding assistant appears and a picked folder is persisted across relaunch.

#### E3-sec-3 — Add an ATS configuration so cleartext http:// sources don't silently fail
- **Category:** robustness · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research.xcodeproj/project.pbxproj:423`, `Swift Deep Research/Shared/URLSafety.swift:22`
- **Problem:** The project uses GENERATE_INFOPLIST_FILE=YES with no NSAppTransportSecurity key (grep for NSAppTransportSecurity/NSAllowsArbitraryLoads/NSExceptionDomains in project.pbxproj returns nothing). Default ATS blocks cleartext http:// to public hosts (URLError -1022). Yet URLSafety.blockReason explicitly ALLOWS scheme http (URLSafety.swift:22), so the app advertises support it cannot deliver: any http:// source returned by web_search/DDG (older gov/edu pages, some arXiv mirrors, plain-http PDFs) fails with an opaque -1022 that surfaces as a generic tool failure. Local http://localhost/127.0.0.1 backends are exempt from default ATS, so those still work — only public cleartext is affected.
- **Proposal:** Pick one explicit policy and make it consistent. Lowest-risk: add INFOPLIST_KEY_NSAppTransportSecurity with NSAllowsArbitraryLoadsInWebContent=true (for the WKWebView render path) and a documented decision on plain http. Given the app is unsandboxed and already fetches arbitrary user/LLM-chosen URLs, an NSAllowsArbitraryLoads=true exception (or per-need) is defensible and documented in the Info.plist; alternatively, if http should be refused, change URLSafety to reject scheme http so the failure is explained as a policy block rather than a cryptic -1022. Either way the advertised capability and the runtime must agree.
- **Acceptance:** From a fresh build, call fetch_url on a known plain-http public page (e.g. an http-only .edu page). Before: -1022 / generic failure. After (allow path): page text returns; or (reject path): a clear 'cleartext http is not allowed' message. Confirm https fetches and local-backend connections are unaffected.

#### E3-sec-4 — Throttle/coalesce scroll-to-bottom during token streaming
- **Category:** performance · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/ConversationView.swift:32`, `Swift Deep Research/Interface/AppEnvironment.swift:620`
- **Problem:** LiveSession.ingest appends one token per .tokenDelta to draftMarkdown (AppEnvironment.swift:620-623). ConversationView's .onChange(of: live?.draftMarkdown ?? "") (ConversationView.swift:32-36) fires on every token and each time starts withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("draft", .bottom) }. During fast synthesis this spins up hundreds of overlapping 0.2s scroll animations per second on the MainActor — wasteful and a source of scroll jank — even though DraftCard already throttles the markdown re-parse to 120ms.
- **Proposal:** Coalesce the scroll the same way DraftCard coalesces rendering: gate scrollTo behind a ~120-150ms trailing-edge timer (a small @State throttle flag), or drive it off DraftCard's already-throttled renderedMarkdown rather than the raw per-token draftMarkdown. Keep a final unconditional scroll on status transition to .complete so the finished answer always lands at bottom.
- **Acceptance:** Run a long 'thorough' synthesis and observe with the SwiftUI animation/CPU profiler: scroll animation starts drop from per-token to at most ~8/sec, MainActor CPU during synthesis falls, and the view still auto-scrolls to the newest content and ends pinned to the bottom.

#### E3-storage-4 — Add a session retention cap / cleanup so storage doesn't grow unbounded
- **Category:** robustness · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:132`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Interface/MainScene.swift:12`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Interface/SessionSidebar.swift:18`
- **Problem:** There is no retention, archival, or cap on sessions/forecasts/events/sources — the only deletion is manual per-session (SessionSidebar.swift:96). A user who runs daily research accumulates StoredSessions forever; combined with the write-only fullText and event snapshots, the store grows without limit, the sidebar @Query (MainScene.swift:12, unbounded, no fetchLimit) returns every session, and the search index faults the full corpus. Nothing ever trims old runs.
- **Proposal:** Add an optional retention policy (e.g. a Settings toggle: 'Keep last N sessions' or 'Auto-delete completed runs older than X days') enforced by a small ResearchStore.pruneSessions(keepingMostRecent:) / pruneOlderThan(:) that runs at launch or after markSession. Even a conservative default cap (e.g. keep 200) prevents pathological growth while leaving manual delete intact.
- **Acceptance:** With retention set to keep N, create N+5 sessions and relaunch; allSessions/@Query returns exactly N (oldest pruned), and the corresponding cascade-deleted turns/sources/events are gone (verify counts).

#### E3-storage-5 — Make sidebar search faulting cheap: index searchable fields instead of faulting full markdown
- **Category:** performance · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Interface/SessionSidebar.swift:202`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchSchema.swift:21`
- **Problem:** SessionSearchIndex.blob (SessionSidebar.swift:202-211) walks session.turns -> turn.markdown (full synthesis text) and session.sources -> snippet for EVERY session on the first search keystroke. Even with the per-session memoization, the initial build faults in the full markdown of every turn of every session from SQLite — a large, blocking read on the MainActor proportional to total history. There is no #Index on any model, so even targeted predicate fetches (e.g. fetchSession by id at MainScene.swift:217) are table scans.
- **Proposal:** Maintain a denormalized lowercased searchText String on StoredSession (updated in updateTurnMarkdown/markSession) so the sidebar filters one already-faulted column instead of walking relationships; or restrict the blob to query+titleSummary (cheap, already faulted) by default and only deep-search markdown when the user opts in. Additionally add `#Index<StoredSession>([\.updatedAt])` and `#Index<StoredSource>([\.id])` / `#Index<ForecastRecord>([\.pipelineID])` so sort and lookup predicates use B-tree indexes rather than scans.
- **Acceptance:** With ~200 sessions of full-length drafts, type in the sidebar search: first-keystroke latency drops markedly (no full-markdown fault), measured via signpost or simple Date diff around `filtered`. findForecast/fetchSession use the index (verify via SwiftData logging showing index use).

#### E3-storage-6 — Provide a JSON import path so exported sessions are actually restorable
- **Category:** out-of-box · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Interface/SessionExporter.swift:135`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:132`
- **Problem:** SessionExporter produces a full structured JSON dump (SessionExporter.json, including turns and citations) but there is NO import counterpart anywhere — the only ingress is a live research run. A user who exports JSON for backup, or who hits the destroy-the-store fallback (finding above), cannot restore it. The export is effectively a dead-end for round-tripping, and the JSON also omits the persisted sources' fullText and the event timeline, so it isn't even a complete backup.
- **Proposal:** Add SessionExporter.importJSON(Data) -> decoded model + a ResearchStore.importSession(...) that recreates a StoredSession with its turns/sources/citations (reusing the existing JSON shape, decoding dates as iso8601). Wire a 'Import Session…' menu item next to Export. This makes JSON a real backup/restore format and gives users a recovery path after a store rebuild.
- **Acceptance:** Export a session to JSON, delete it (or wipe the store), then Import the file: the session reappears in the sidebar with identical query, turns, citations, and sources.

#### E3-ux-2 — Make command-N workspace-aware (new forecast in Forecast mode) and remove the duplicate binding
- **Category:** ux · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Bootstrap/SwiftDeepResearchApp.swift:30-37`, `Swift Deep Research/Interface/MainScene.swift:70-86`, `Swift Deep Research/Interface/AppEnvironment.swift:138-141`
- **Problem:** command-N is bound twice: in the App CommandGroup (always active, clears research state) and in the research-only toolbar button (MainScene.swift:83, gated behind workspace == .research). In the Forecast workspace there is no toolbar New button, so pressing command-N silently clears the hidden research session and does nothing visible — there is no way to start a new forecast via the standard New shortcut. AppEnvironment.newForecast() already exists (line 138) but isn't wired to command-N.
- **Proposal:** Keep a single command-N in the App CommandGroup and branch on env.workspace: research -> newResearchSession(); forecast -> env.newForecast(). Remove the .keyboardShortcut("n") from the toolbar button (keep the button itself, no shortcut) so there's exactly one binding and it always matches the visible workspace.
- **Acceptance:** Switch to Forecast workspace with a forecast open; press command-N and confirm the forecast composer (new forecast) appears. Switch to Research and press command-N; confirm a new research session starts. Confirm no double-fire.

#### E3-ux-3 — Add VoiceOver labels to icon-only buttons that currently only have .help()
- **Category:** ux · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/Composer.swift:48-86`, `Swift Deep Research/Interface/Forecast/KnowledgeGraphView.swift:150-177`, `Swift Deep Research/Interface/DraftCard.swift:154-209`, `Swift Deep Research/Interface/Forecast/ForecastReportView.swift:76-81`, `Swift Deep Research/Interface/KBChunkDetail.swift:70-76`
- **Problem:** .help() renders a tooltip but is NOT exposed to VoiceOver. A grep shows ~35 .help() calls but only ~5 accessibilityLabel/Hint/Element modifiers in the whole Interface tree (the latter only in SourcePanel tabs, DocumentUploadView, SettingsSheet, WelcomeView). Composer's stop/follow-up/new-session/research buttons (Image-only labels), the entire KnowledgeGraphView control bar (pause/zoom/reset/labels), DraftCard citation chips and NumberedSourceRow links, the report Copy button, and KBChunkDetail Copy button are all icon-only with no accessibilityLabel — VoiceOver announces them as bare 'button'. This blocks non-sighted users from operating the core research controls.
- **Proposal:** Add .accessibilityLabel(...) to every icon-only Button/Toggle (e.g. 'Stop research', 'Follow up', 'New session', 'Pause layout', 'Zoom in', 'Reset view', 'Copy report'). Where a .help() string already conveys it, mirror it into accessibilityLabel. For status-bearing controls (layout pause), add .accessibilityValue.
- **Acceptance:** Turn on VoiceOver and tab through the active research view and the knowledge graph; confirm every control announces a meaningful name and action rather than 'button'.

#### E3-ux-4 — Add a one-click Retry to the research failure banner
- **Category:** robustness · **Impact:** P2 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/ConversationView.swift:238-264`, `Swift Deep Research/Interface/Forecast/ForecastPipelineView.swift:47-74`, `Swift Deep Research/Interface/AppEnvironment.swift:283-289`
- **Problem:** When a research run fails (transient network error, rate limit, provider hiccup), failureBanner (ConversationView.swift:238-264) shows the message but offers no action. The user must manually retype/re-run. The Forecast errorBanner (ForecastPipelineView.swift:62-68) already provides a Resume button, so the two flows are inconsistent. For a fresh user whose first run fails on a flaky network, the dead-end banner reads as 'the app is broken'.
- **Proposal:** Add a 'Retry' button to failureBanner that re-runs the failed query. Pass an onRetry closure from ResearchCanvas that calls env.startResearch(query: live.query) (the original query is on LiveSession.query). Optionally also surface 'Open Settings' when failure.kind indicates an auth/key problem so the user can fix the key inline.
- **Acceptance:** Force a run to fail (e.g. invalid key or airplane mode), confirm the banner shows Retry; fix the condition and click Retry; confirm the same query re-runs without retyping.

#### E3-ux-6 — Show provider/model + key status in the Forecast composer like the research Composer does
- **Category:** out-of-box · **Impact:** P2 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/Forecast/ForecastComposer.swift:66-126`, `Swift Deep Research/Interface/Composer.swift:141-169`
- **Problem:** The research Composer surfaces a providerSummary chip (icon + provider + model + 'key needed' warning, Composer.swift:141-169) so a user knows what will run and whether a key is missing before submitting. The Forecast composer card (ForecastComposer.swift:66-126) has depth/mode/rounds and a Run button but no indication of which LLM provider the forecast will use or whether its key is configured. A fresh user can fire a forecast that fails opaquely on the backend for a missing provider key — the only signal is the separate ForecastBackendBanner about backend reachability, not provider/key readiness.
- **Proposal:** Add a compact provider summary row to the Forecast composer card using env.modelProviders.forecastAssignment (provider icon + name + model), with an inline 'needs key' affordance routing to Settings when the forecast provider requires a key the backend lacks. Reuse ProviderIcon for consistency.
- **Acceptance:** Open Forecast with a key-requiring provider and no key; confirm the composer shows the provider/model and a visible 'needs key' hint before Run, and that tapping it opens Settings.

### P3 — 21 item(s)

#### E3-engine-8 — Prevent budget/iteration mismatch from silently killing later rounds
- **Category:** ux · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/SettingsSheet.swift:1102`, `Swift Deep Research/Interface/SettingsSheet.swift:1214`, `Swift Deep Research/Engine/EngineConfiguration.swift:73`
- **Problem:** The Composer depth picker pairs budget and iteration in lockstep (fast→.fast/.fast, etc.), but SettingsSheet exposes budget presets (lines 1102-1109) and iteration presets (lines 1214-1221) as fully independent rows. A user can therefore select 'Thorough' iteration (6 rounds) with a 'Fast' budget (60k tokens / 180s), so the engine busts its token/wall-clock cap after ~1-2 rounds and ends with a 'budget exhausted' warning — the configured 6 rounds never materialize, with no explanation that the budget, not the round count, was the binding constraint.
- **Proposal:** Either link the two presets in Settings the way the Composer does (selecting a tier sets both), or add an inline warning when iteration.maxRounds implies more work than budget can fund (e.g. thorough iteration + fast budget) advising the user to raise the budget. A lightweight heuristic: warn when maxRounds * minPerRoundTokenEstimate > budget.maxTokens.
- **Acceptance:** In Settings, pick Thorough iteration with Fast budget and confirm an inline caution appears; verify the Composer depth picker still sets both budget and iteration together so the common path can't mismatch.

#### E3-engine-9 — Cap concurrency of the cross-turn cache pre-warm loop
- **Category:** performance · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Engine/ResearchEngine.swift:68`, `Swift Deep Research/Shared/SourceCache.swift:47`
- **Problem:** On a follow-up turn the engine pre-warms the SourceCache by iterating conversation.accumulatedSources and calling cache.fetch(url) { known } for each (ResearchEngine.swift:68-71). The closure just returns the already-known source (no network), so this is cheap, but it is done serially and unconditionally for every accumulated source across all prior turns. A long multi-turn session can accumulate hundreds of sources (the cache itself caps at 300 and FIFO-evicts), so a long follow-up turn does up to ~300 actor round-trips before any planning begins — minor latency, and the eviction cap means the oldest pre-warmed entries are immediately discarded if accumulatedSources exceeds maxEntries, making part of the loop pure waste.
- **Proposal:** Pre-warm directly via an internal SourceCache seeding method that inserts known sources in one actor hop (or in a bounded batch), and cap the number seeded to the cache's maxEntries (seed the most recent N). This removes the per-source await overhead and avoids seeding entries that will be evicted before use.
- **Acceptance:** On a follow-up turn with 400 accumulated sources, confirm pre-warm completes in roughly constant actor hops (not 400) and that only the most-recent maxEntries are retained; verify a follow-up worker still gets a cache hit on a previously-fetched URL.

#### E3-forecast-5 — Allow editing the research dossier before building the graph (human-in-the-loop)
- **Category:** enhancement · **Impact:** P3 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Forecast/MiroFishClient.swift:96`, `Swift Deep Research/Forecast/MiroFishModels (MFDossier):MiroFishClient.swift:425`, `Swift Deep Research/Interface/Forecast/ResearchConsoleView.swift:1`
- **Problem:** The backend exposes PUT /api/research/<id>/dossier (research.py:356) to edit research_report.md and actors.json after a completed research_only run (or a failed run before graph-building), enabling a human to correct actors/stances before the expensive simulation consumes them. The app's MFDossier is read-only and offers no edit path, so a user who spots a wrong actor stance can only restart.
- **Proposal:** Add MiroFishClient.editDossier(_:report:actors:) → PUT /<id>/dossier. In the research stage detail (ResearchConsoleView), when mode == .research_only && phase == .completed, add an 'Edit actors' affordance that lets the user adjust actor stance/influence (and optionally the report text), then save via the PUT. Pair naturally with the Continue-to-full button so edits flow into the simulation.
- **Acceptance:** Edit an actor's stance on a completed research_only dossier, save, re-fetch dossier and confirm actors.json reflects the change; then Continue and confirm the simulation uses the edited actors.

#### E3-forecast-6 — Decode the dossier timeline field the backend already returns
- **Category:** enhancement · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Forecast/MiroFishClient.swift:425`, `Swift Deep Research/Forecast/ForecastRun.swift:43`
- **Problem:** GET /api/research/<id>/dossier now returns a first-class timeline field (research.py:343-350, 'T5.2 一等公民时间线') containing the chronological event timeline DeerFlow extracted. The Swift MFDossier struct (MiroFishClient.swift:425) only decodes report/has_report/actors/sources and silently drops timeline, so the app never shows the research-stage event timeline even though it's free in the response already being fetched.
- **Proposal:** Add `timeline: AnyJSON?` to MFDossier plus a best-effort accessor (e.g. timelineEvents -> [{date, event}]) mirroring actorList/sourceList. Render it in the research stage detail as a vertical event timeline alongside actors and sources. Zero extra network cost — the data is in a response already retrieved by sideFetches.
- **Acceptance:** After a research stage completes, the research detail shows a chronological event timeline populated from dossier.timeline; absent timeline data degrades to hiding the section.

#### E3-forecast-8 — Batch-clean failed/cancelled pipelines via /clean instead of per-item deletes
- **Category:** optimization · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/AppEnvironment.swift:219`, `Swift Deep Research/Forecast/MiroFishClient.swift:133`
- **Problem:** deleteBackendPipeline deletes one pipeline at a time (AppEnvironment.swift:219). The backend provides POST /api/research/clean (research.py:255) to bulk-remove all failed/cancelled pipeline records in one call. After a few failed first-run attempts (common while setting up), the 'On backend' sidebar section accumulates failed pipelines the user must delete individually.
- **Proposal:** Add MiroFishClient.cleanPipelines(statuses:) → POST /clean. Add a 'Clear failed/cancelled' button to the ForecastSidebar 'On backend' section header (ForecastSidebar.swift:78) that calls clean(['failed','cancelled']) and refreshes the list. Low-risk: backend only allows terminal statuses.
- **Acceptance:** With several failed backend pipelines listed, one click clears them all and the sidebar 'On backend' section refreshes to drop them.

#### E3-forecast-9 — Stream report agent log / progress via SSE instead of 2s polling
- **Category:** performance · **Impact:** P3 · **Effort:** M · **Risk:** medium
- **Files:** `Swift Deep Research/Forecast/ForecastRun.swift:234`, `Swift Deep Research/Forecast/ForecastRun.swift:436`, `Swift Deep Research/Forecast/MiroFishClient.swift:191`
- **Problem:** fetchReport polls report, reportProgress, and reportAgentLog every 2s (ForecastRun.swift:300). The report stage's ReAct agent log can be lengthy and is the most-watched live console, yet the backend offers SSE endpoints GET /api/report/<id>/agent-log/stream and /console-log/stream (report.py:832, 915) for push delivery. Polling every 2s adds latency to the live console and re-fetches overlapping ranges (mitigated by from_line, but still chatty).
- **Proposal:** Optionally consume /agent-log/stream via URLSession bytes/SSE while the report stage is running, appending to agentLog with the existing dedupe logic, and fall back to the current polling on stream error. Keeps the robust poll loop as the source of truth for stage transitions; only the high-frequency agent log moves to push. Lower-priority than the capability gaps above.
- **Acceptance:** During report generation, new agent-log lines appear with sub-second latency via the stream; killing the stream connection mid-run falls back to polling without losing or duplicating lines.

#### E3-kb-10 — Remove the now-stale 'Start it with python3 ...' guidance from the unreachable error
- **Category:** code-health · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Knowledge/SeekDBClient.swift:166-168`
- **Problem:** `SeekDBError.unreachable.errorDescription` returns 'Sidecar at <url> is unreachable. Start it with `python3 sidecar/seekdb_sidecar.py`.' (SeekDBClient.swift:167-168). The whole point of SidecarSupervisor is that users never run Python manually (its own header comment), and the KnowledgeBaseTool/DocumentUploadView already provide correct auto-launch guidance. This stale message can leak into surfaces that show the raw error (e.g. KnowledgeBase.lastError -> banner detail, KnowledgeBaseTool generic catch at KnowledgeBaseTool.swift:110), telling a fresh GUI user to cd into a project tree that doesn't exist in a distributed app — actively misleading for OOBE.
- **Proposal:** Change the message to reflect auto-launch, e.g. 'The knowledge-base sidecar at <url> isn\'t responding. It starts automatically; open Settings → Knowledge → Reinstall/Start, or disable the knowledge-base toggle.' Keep the manual command only in the explicit 'Manual setup (optional)' disclosure that already exists in Settings.
- **Acceptance:** Force the sidecar offline and trigger a generic error path; confirm no user-facing surface instructs running `python3 sidecar/seekdb_sidecar.py` outside the explicit Manual-setup disclosure.

#### E3-kb-5 — Surface ingest/query progress for large documents instead of a single isBusy spinner
- **Category:** ux · **Impact:** P3 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Knowledge/KnowledgeBase.swift:86-100`, `Swift Deep Research/Knowledge/KnowledgeBase.swift:121-171`, `Swift Deep Research/Interface/DocumentUploadView.swift:163-172`
- **Problem:** Ingestion of a large PDF embeds chunks server-side in batches of 96 (seekdb_sidecar.py:440-446) while holding the writer lock, and on the client side a multi-MB document's upsert is a single awaited HTTP call with only a boolean `isBusy` flag (KnowledgeBase.swift:87-88) driving a disabled button. The user gets no progress, no chunk count, and no indication the app is alive during what can be a tens-of-seconds embed (especially right after the model warm-up). For batch imports (ingestFiles), there is likewise no per-file progress — the whole set is one opaque busy state. This reads as a hang on first real use.
- **Proposal:** Add lightweight progress to KnowledgeBase: for ingestFiles, track files completed/total and expose a `progress: (done: Int, total: Int)?` the view can render ('Embedding 3 of 12…'). For a single large file, optionally show the extracted character count / estimated chunk count before upload. The sidecar already batches; consider a tiny `/documents/{id}/status` or simply show an indeterminate-with-label state. Even just 'Embedding <title>…' with the file count materially improves the first-run perception.
- **Acceptance:** Drop 10 mixed files; confirm the UI shows incremental progress ('n of 10') rather than one static spinner, and the final document list reflects all successes plus any skipped-file note.

#### E3-llm-6 — Reconcile available-model lists between ProviderRegistry and client identities
- **Category:** code-health · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/LLM/ProviderRegistry.swift:87`, `Swift Deep Research/LLM/OllamaClient.swift:24-31`, `Swift Deep Research/LLM/ProviderRegistry.swift:46-93`
- **Problem:** There are two independent hardcoded model catalogues that have already drifted. `ProviderRegistry.availableModels` for `.ollama` is `[qwen3:8b, qwen2.5:7b, deepseek-r1:14b, mistral-small:24b]` while `OllamaClient.identity.availableModels` is `[qwen3:8b, qwen2.5:7b, llama3.3:70b, deepseek-r1:14b, mistral-small:24b]` — different sets. Whichever the UI reads determines what the user sees, and the two will keep diverging on every edit. Same risk exists across other providers since each client re-declares its own list.
- **Proposal:** Have client `identity.availableModels` reference `ProviderRegistry.ProviderID(rawValue:)?.availableModels` (single source of truth), or vice-versa, so the catalogue is defined once per provider. Add a tiny test asserting the registry list and the constructed client identity list match for each provider.
- **Acceptance:** For every provider, `ProviderRegistry.ProviderID.availableModels` equals the `availableModels` on the client returned by `makeClient`, verified by a unit test; editing the catalogue in one place is reflected everywhere.

#### E3-llm-7 — Surface MLX as 'coming soon' instead of a selectable broken provider
- **Category:** ux · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/LLM/MLXClient.swift:11-44`, `Swift Deep Research/LLM/ProviderRegistry.swift:8-10`, `Swift Deep Research/LLM/ProviderRegistry.swift:40-42`
- **Problem:** MLX is a full first-class provider in the picker (`ProviderID.mlx`, default model, available models) but its `stream` immediately throws 'MLX provider is not yet wired in v2.0.' A user who selects MLX (a prominent, attractive on-device option on Apple Silicon) gets a hard failure on their first run with no upfront signal that it's a stub — its display name only says '(on-device)', not '(stub)'. This is a discoverable dead-end during first-run exploration.
- **Proposal:** Either disable/hide MLX in the provider picker until wired, or clearly label it 'MLX (coming soon)' and grey it out so it can't be selected as an active role; keep the explanatory error only as a fallback. The `MLXClient.identity` already says '(stub)' — propagate that intent to the picker rather than only to the runtime error.
- **Acceptance:** MLX cannot be chosen as an active orchestrator/worker/synthesis provider (or is clearly marked unavailable) so a new user never hits the 'not yet wired' runtime error by simply trying the option.

#### E3-oobe-6 — Set NSHumanReadableCopyright and LSApplicationCategoryType for a polished bundle
- **Category:** enhancement · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research.xcodeproj/project.pbxproj:425`, `Swift Deep Research.xcodeproj/project.pbxproj:463`
- **Problem:** `INFOPLIST_KEY_NSHumanReadableCopyright = ""` (empty in both configs) so the About panel / Get Info shows no copyright, and no `INFOPLIST_KEY_LSApplicationCategoryType` is set, so Finder/Launchpad/App Store categorize the app as generic. These are small but visible polish gaps for a fresh user inspecting the app and are required metadata for App Store submission.
- **Proposal:** Set `INFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © 2026 Roger Lin. All rights reserved."` and add `INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"` (or developer-tools) in both Debug and Release.
- **Acceptance:** Get Info / About panel on the built app shows a copyright line; `mdls -name kMDItemAppStoreCategory` (or the Info.plist LSApplicationCategoryType key) reports the chosen category.

#### E3-oobe-8 — Align SWIFT_VERSION with the Swift 6.2 toolchain the project targets
- **Category:** code-health · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research.xcodeproj/project.pbxproj:434`, `Swift Deep Research.xcodeproj/project.pbxproj:472`
- **Problem:** `SWIFT_VERSION = 6.0` in both build configs, while the project is described as Swift 6.2 and uses `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_STRICT_CONCURRENCY = complete`. SWIFT_VERSION selects the language mode; pinning 6.0 forgoes any 6.1/6.2 language-mode behaviors the codebase may assume and is inconsistent with the stated toolchain.
- **Proposal:** Set `SWIFT_VERSION = 6.2` (or the toolchain's current major) in both configs and rebuild; resolve any language-mode diagnostics that surface. This is low-risk since strict concurrency is already complete.
- **Acceptance:** A clean Debug+Release build succeeds with SWIFT_VERSION=6.2 and no new warnings/errors.

#### E3-oobe-9 — Surface a clear macOS 26.0 requirement so older-OS users get a graceful message, not a silent no-launch
- **Category:** ux · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research.xcodeproj/project.pbxproj:327`, `Swift Deep Research.xcodeproj/project.pbxproj:389`, `README.md:239`
- **Problem:** `MACOSX_DEPLOYMENT_TARGET = 26.0` (LSMinimumSystemVersion=26.0 in the built Info.plist). This is an intentional, defensible floor (Liquid Glass, Foundation Models, Swift Charts 26), but on macOS < 26 the OS refuses to launch the app with a generic 'requires a newer version of macOS' dialog and the README 'Getting started' (§239) does not state the macOS 26 requirement up front. A fresh user on macOS 15 downloads, double-clicks, and gets a confusing system error with no project-side explanation.
- **Proposal:** Add a prominent 'Requirements: macOS 26.0 (Tahoe) or later, Apple Silicon' line at the top of README Getting started and on any download/release page. (The deployment target itself is correct and should stay.)
- **Acceptance:** README clearly states the macOS 26 / Apple Silicon requirement before the build/run steps; the requirement matches LSMinimumSystemVersion in the built Info.plist.

#### E3-sec-5 — Cap ConversationContext.accumulatedSources to bound multi-turn memory growth
- **Category:** performance · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Engine/ConversationContext.swift:11`, `Swift Deep Research/Interface/AppEnvironment.swift:516`
- **Problem:** After every completed turn, LiveSession appends all fetchedSources.values into conversation.accumulatedSources (AppEnvironment.swift:516) and accumulatedCitations (:517). Each FetchedSource holds up to 40k chars of extracted text (PDF) / 20k (HTML). The array is never trimmed, so a long session with many follow-ups retains every source's full text in memory (and re-encodes it when the context is Codable-persisted). The prompt-facing accessors are bounded (plannerPreamble suffix(6)/prefix(8), seenSourcesNote limit 30), but the backing store and its payloads are not — slow, unbounded memory growth proportional to total sources across the session.
- **Proposal:** Bound accumulatedSources to a recent/most-relevant window (e.g. keep the last N=~80 by recency, or de-dup by URL and drop the extractedText for entries beyond what seenSourcesNote needs — titles+URLs are enough for the 'already-seen' hint while the SourceCache still serves full text on demand). Apply the same cap to accumulatedCitations. Do the trim at the append site in LiveSession after each turn.
- **Acceptance:** Run a synthetic 15-turn session that fetches ~20 sources/turn; sample process memory (and the persisted context size). Before: monotonic growth tracking total sources. After: memory/context plateaus near the cap, while follow-ups still see the 'already-seen sources' note and cached re-reads remain free.

#### E3-sec-6 — Reduce FlowLayout sizeThatFits recomputation for citation chip rows
- **Category:** performance · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/DraftCard.swift:253`, `Swift Deep Research/Interface/DraftCard.swift:257`
- **Problem:** FlowLayout (DraftCard.swift:253) calls view.sizeThatFits(.unspecified) for every subview in both sizeThatFits (:257) and placeSubviews (:274) on each layout pass, with no caching, and the Layout's Cache type is Void. For the quoted-evidence chip flow this re-measures every CitationChip twice per pass; on a citation-heavy answer that re-measures dozens of chips repeatedly during the streaming relayouts. It's a minor but avoidable per-pass cost in the hot synthesis view.
- **Proposal:** Use the Layout cache: define a Cache struct holding the measured subview sizes (and total) keyed off the subviews' count/hash, populate it in makeCache/updateCache, and read from it in both sizeThatFits and placeSubviews so each chip is measured once per invalidation rather than twice per pass. Sizes for fixed chips don't change between the two phases.
- **Acceptance:** With a draft containing 30+ citations, profile layout time of the quoted-evidence section during streaming: sizeThatFits call count per relayout drops roughly by half and chips render identically. Verify wrapping behavior is unchanged at multiple window widths.

#### E3-storage-7 — Remove dead allSessions()/allForecasts() API to keep the persistence surface honest
- **Category:** code-health · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:163`, `/Users/rogerlin/XCode-Projects/Swift-Deep-Research/Swift Deep Research/Storage/ResearchStore.swift:299`
- **Problem:** allSessions() (ResearchStore.swift:163) and allForecasts() (ResearchStore.swift:299) have zero callers — the UI reads sessions/forecasts exclusively through @Query (MainScene.swift:12-13). They are unused public API on the persistence façade. Leaving them invites a future caller to do an unbounded, un-paged fetch on the MainActor (no fetchLimit), exactly the pathology the @Query path avoids.
- **Proposal:** Delete both methods (or, if kept for a retention/export feature, give them an explicit fetchLimit/paging parameter and a doc note that they bypass @Query reactivity). Confirm no compile breakage; grep already shows none.
- **Acceptance:** Methods removed; project builds; grep for allSessions/allForecasts returns only the (now absent) definitions. No behavioral change in the running app.

#### E3-ux-10 — Make the multi-line composer submit behavior consistent and discoverable
- **Category:** ux · **Impact:** P3 · **Effort:** S · **Risk:** medium
- **Files:** `Swift Deep Research/Interface/Composer.swift:28-33`, `Swift Deep Research/Interface/Composer.swift:73-86`, `Swift Deep Research/Interface/Forecast/ForecastComposer.swift:75-80`
- **Problem:** The research composer TextField uses axis: .vertical with .onSubmit(handlePrimary) (Composer.swift:28-33), so plain Return submits even though the field is multi-line and the send button advertises command-Return (line 85). The Forecast composer uses a TextEditor where Return inserts a newline and only command-Return submits, so the two composers behave inconsistently with no on-screen hint about either.
- **Proposal:** Standardize the two composers (let Return insert a newline and command-Return submit in both, or clearly document the difference) and add a subtle inline 'command-Return to run' caption near the send button shown when the field is focused/non-empty, so the shortcut is discoverable and the behavior unsurprising.
- **Acceptance:** Focus the research composer and type a multi-line query; confirm predictable Return behavior and a visible command-Return hint; confirm command-Return submits in both research and forecast composers.

#### E3-ux-5 — Give the SessionSidebar a real empty state and use ContentUnavailableView
- **Category:** out-of-box · **Impact:** P3 · **Effort:** S · **Risk:** low
- **Files:** `Swift Deep Research/Interface/SessionSidebar.swift:33-37`, `Swift Deep Research/Interface/Forecast/ForecastSidebar.swift:35-42`
- **Problem:** On first launch the research sidebar shows a tiny tertiary two-line Text ('No sessions yet.\nAsk a question to begin.') buried inside a List Section (SessionSidebar.swift:33-37), which reads as an afterthought next to the polished Forecast sidebar that uses a proper ContentUnavailableView (ForecastSidebar.swift:36-42). The first thing a new user sees in the research workspace sidebar is underwhelming and inconsistent with the rest of the app.
- **Proposal:** Replace the bare Text with a ContentUnavailableView (icon 'magnifyingglass' or 'sparkles', title 'No research yet', description 'Ask a question to start your first deep-research session.') for the empty case, matching ForecastSidebar. Keep the lightweight 'No matches' Text for the search-with-no-results case.
- **Acceptance:** Launch with no stored sessions; confirm the research sidebar shows a centered, styled empty state consistent with the Forecast sidebar.

#### E3-ux-7 — Unify hardcoded reading-column widths into one constant and verify Dynamic Type reflow
- **Category:** ux · **Impact:** P3 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/ConversationView.swift:29-30`, `Swift Deep Research/Interface/ConversationView.swift:135-136`, `Swift Deep Research/Interface/WelcomeView.swift:31-32`, `Swift Deep Research/Interface/Forecast/ForecastComposer.swift:27`
- **Problem:** Reading-column widths are hardcoded in several places (ConversationView 880, WelcomeView 720, ForecastComposer 760) with no relation to the user's text size, and the duplication can drift. At the largest Accessibility Dynamic Type sizes a fixed 880pt column plus 28pt horizontal padding can cramp long titles (sessionHeader Text(live.query) is lineLimit(3) at .title weight).
- **Proposal:** Extract a single Layout.readingWidth constant (or a ViewModifier) and apply it in all three places. While there, audit the few fixed .frame(width:) pickers in SettingsSheet for clipping at AX sizes, and confirm the composer/cards reflow rather than truncate at the largest Dynamic Type setting.
- **Acceptance:** Set Accessibility text size to the maximum; confirm conversation, welcome, and forecast composer text wraps without horizontal clipping and the columns stay centered and readable.

#### E3-ux-8 — Add Forecast report export/copy parity with the research Export menu
- **Category:** enhancement · **Impact:** P3 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/MainScene.swift:87-103`, `Swift Deep Research/Interface/Forecast/ForecastReportView.swift:71-91`
- **Problem:** In the research workspace the toolbar offers a rich Export menu and 'Copy synthesis as Markdown' (MainScene.swift:171-190). In the Forecast workspace the toolbar shows only Settings (the export/inspector/KB group is gated behind workspace == .research, line 88), so a completed forecast report can only be copied via the small borderless Copy button inside ForecastReportView (line 76-81) — no Save-to-file/export. This makes finished forecasts feel less first-class than research sessions.
- **Proposal:** Add a workspace == .forecast branch to the toolbar primaryAction group exposing Export/Copy for the current ForecastRun report markdown (reuse the NSSavePanel flow, or at minimum 'Save report as Markdown…' and 'Copy report'). Disable when no report is available.
- **Acceptance:** Complete a forecast; confirm the toolbar offers Save/Copy for the report and that exporting writes a valid .md file matching the on-screen report.

#### E3-ux-9 — Announce research status transitions to VoiceOver during long runs
- **Category:** ux · **Impact:** P3 · **Effort:** M · **Risk:** low
- **Files:** `Swift Deep Research/Interface/ConversationView.swift:62-89`, `Swift Deep Research/Interface/ConversationView.swift:222-236`, `Swift Deep Research/Interface/ConversationView.swift:301-341`
- **Problem:** Long runs rely on visual cues (pulsing symbols, ProgressView, StatusPill) to signal liveness (inflightCard line 222-236, StatusPill line 301-341). None emit accessibility announcements, so a VoiceOver user cannot tell 'working' from 'hung' during a multi-minute run, and status transitions (planning -> working -> synthesizing -> complete) are silent.
- **Proposal:** Add .accessibilityElement(children: .combine) + .accessibilityLabel to the StatusPill (e.g. 'Status: synthesizing') and post an AccessibilityNotification.Announcement (or bind .accessibilityValue to status) on status changes in ConversationView so VoiceOver speaks 'Planning', 'Synthesizing', 'Complete'.
- **Acceptance:** With VoiceOver on, start a run; confirm status transitions are announced and the status pill reads its current state on focus.

## Implementation waves

Ordered smallest-safe-first, P0/out-of-box first. Build + smoke after each wave.

### Wave 1 — Out-of-box gate (P0 + OOBE/robustness/security P1)

- [x] E3-llm-1
- [x] E3-engine-1
- [x] E3-engine-2
- [x] E3-engine-3
- [x] E3-engine-4
- [x] E3-forecast-1
- [x] E3-kb-1
- [x] E3-kb-2
- [x] E3-kb-8
- [x] E3-llm-2
- [x] E3-llm-3
- [x] E3-oobe-1
- [~] E3-oobe-2  (README + ad-hoc DMG only; notarization needs a Developer ID)
- [x] E3-oobe-5
- [x] E3-sec-1
- [x] E3-sec-2
- [x] E3-storage-3
- [x] E3-ux-1

_Build: `xcodebuild -scheme "Swift Deep Research" -configuration Debug build` → fix → smoke._

### Wave 2 — Remaining P1 (quality/correctness)

- [x] E3-forecast-2
- [x] E3-storage-1
- [x] E3-storage-2

_Build: `xcodebuild -scheme "Swift Deep Research" -configuration Debug build` → fix → smoke._

### Wave 3 — P2 enhancements & optimizations

- [ ] E3-engine-5
- [ ] E3-engine-6
- [ ] E3-engine-7
- [ ] E3-forecast-10
- [ ] E3-forecast-3
- [ ] E3-forecast-4
- [ ] E3-forecast-7
- [x] E3-kb-3
- [x] E3-kb-4
- [x] E3-kb-6
- [ ] E3-kb-7
- [ ] E3-kb-9
- [ ] E3-llm-4
- [x] E3-llm-5
- [ ] E3-llm-8
- [ ] E3-oobe-3
- [x] E3-oobe-4
- [ ] E3-oobe-7
- [ ] E3-sec-3
- [ ] E3-sec-4
- [x] E3-storage-4
- [x] E3-storage-5
- [ ] E3-storage-6
- [ ] E3-ux-2
- [ ] E3-ux-3
- [x] E3-ux-4
- [ ] E3-ux-6

_Build: `xcodebuild -scheme "Swift Deep Research" -configuration Debug build` → fix → smoke._

### Wave 4 — P3 polish & code-health

- [ ] E3-engine-8
- [ ] E3-engine-9
- [ ] E3-forecast-5
- [ ] E3-forecast-6
- [ ] E3-forecast-8
- [ ] E3-forecast-9
- [ ] E3-kb-10
- [ ] E3-kb-5
- [ ] E3-llm-6
- [ ] E3-llm-7
- [x] E3-oobe-6
- [ ] E3-oobe-8
- [ ] E3-oobe-9
- [ ] E3-sec-5
- [ ] E3-sec-6
- [ ] E3-storage-7
- [ ] E3-ux-10
- [x] E3-ux-5
- [ ] E3-ux-7
- [ ] E3-ux-8
- [ ] E3-ux-9

_Build: `xcodebuild -scheme "Swift Deep Research" -configuration Debug build` → fix → smoke._

## Out-of-box verification checklist (fresh user on a clean Mac)

- [ ] 1. Install from the .dmg (drag to /Applications); first launch succeeds past Gatekeeper (right-click→Open).
- [ ] 2. App launches to the main window with a clear welcome/empty state — no crash on empty SwiftData store.
- [ ] 3. With ZERO API keys configured, the app does something useful: on-device/Ollama path works OR a clear banner guides the user to add a key (no silent ungrounded answers).
- [ ] 4. A research run with no search key surfaces a visible 'no sources / unverified' warning rather than a confident uncited answer (E3-engine-2).
- [ ] 5. Provider/key preflight names the exact missing role before a doomed run (E3-engine-3).
- [ ] 6. Knowledge base: sidecar boots (or degrades cleanly); first-run embedding model download is messaged, not a silent hang (E3-kb-2, E3-forecast-10).
- [ ] 7. Forecast: onboarding finds the backend at the default path, runs setup.sh, launches, reaches /health; preflight surfaces config errors before a long run (E3-forecast-1).
- [ ] 8. Settings shows accurate provider/model/key status; no references to removed Zep flow.
- [ ] 9. No App Sandbox blocking subprocess launch (sidecar + backend) (E3-kb-8).
- [ ] 10. Version/build numbers are real; app icon present; copyright/category set (E3-oobe-4/6).
- [ ] 11. Quit and relaunch: sessions/forecasts persist; no store wipe on transient error (E3-storage-3).
- [ ] 12. DMG runs on a second Mac (or fresh user account) without developer tooling installed.