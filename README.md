# Swift Deep Research

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%20Tahoe-red" />
  <img src="https://img.shields.io/badge/Swift-6.2-orange" />
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-purple" />
  <img src="https://img.shields.io/badge/License-MIT-green" />
  <img src="https://img.shields.io/badge/Platform-Apple%20Silicon-blue" />
</p>

<p align="center">
  <a href="./README.md">English</a> · <a href="./README_zh.md">简体中文</a>
</p>

**Swift Deep Research** is an open-source macOS research agent that runs a multi-round **ReAct loop** — reason, act, observe, reflect — against the open web *and* your own private documents. A planner decomposes the question, parallel workers issue tool calls (search, fetch, knowledge base, arXiv, Wikipedia, Reddit, calculator), a reflector identifies gaps, and a synthesizer produces a cited markdown report. Up to six rounds of refinement; gap-finding for the first half, deepening + cross-verification for the second.

Private documents live in **SeekDB**, an embedded vector knowledge base wired through a Python FastAPI sidecar that the app launches on first run. PDFs are chunked, embedded, and queried semantically — the worker calls `knowledge_base` *before* the web so your own notes get priority.

Alongside research, a **Forecast** workspace answers questions about the *future*: it drives a local **DeepResearchForecast** prediction backend (formerly MiroFish) through a six-stage pipeline — deep research (DeerFlow) → actor ontology → local Graphiti temporal knowledge graph (embedded FalkorDB, no API key) → agent personas → a multi-agent social simulation (OASIS) with hundreds of LLM agents posting on simulated Twitter/Reddit → a final prediction report you can chat with. Every stage renders natively in SwiftUI, including an interactive force-directed knowledge graph.

Built top-to-bottom in Swift 6.2 / SwiftUI for macOS 26 Tahoe with strict concurrency, structured tool calling across every provider, and a Liquid Glass UI.

---

## Demo

### Forecast: simulate a society, read out the prediction

A complete forecast of the 2030 semiconductor industry — the DeerFlow research console and actor dossier, the six-stage pipeline stepper, the OASIS social simulation (40 rounds, 1,600+ agent actions across simulated Twitter and Reddit with live per-round telemetry), and the final prediction report.

<video src="https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.11.33.mp4" controls muted width="100%"></video>

> ▶ Direct link: [Forecast pipeline walkthrough](https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.11.33.mp4)

### Deep research

A full multi-round research run — planner decomposition, parallel workers issuing tool calls, the activity inspector, and the final cited synthesis.

<video src="https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-08%20at%2002.05.10%201.mp4" controls muted width="100%"></video>

> ▶ If the player doesn't load inline, watch it here: [End-to-end research run](https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-08%20at%2002.05.10%201.mp4)

A condensed walkthrough of the same flow at **5× speed**:

<video src="https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/SwiftDeepResearch%202026-06-08at01.42.541_5x.mp4" controls muted width="100%"></video>

> ▶ Direct link: [Full walkthrough (5× speed)](https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/SwiftDeepResearch%202026-06-08at01.42.541_5x.mp4)

---

## Screenshots

| | |
|:--|:--:|
| **Hero composer** — Spotlight-style entry with depth presets, knowledge-base toggle, and live provider/model status | ![Composer](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.21%402x.png) |
| **Iterative research canvas** — Round-by-round plan, parallel workers, tool-call drill-down, live activity inspector | ![Canvas](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.39%402x.png) |
| **Sources inspector** — Discovered, fetched, and cited sources beside the draft, plus a Knowledge base section listing retrieved chunks by relevance score (click to read the full chunk) | ![Sources](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.19.44%402x.png) |
| **Knowledge base** — Drop PDFs to chunk + embed via the auto-launched SeekDB sidecar; queried automatically during research | ![Knowledge Base](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.53.03%402x.png) |
| **Settings** — Provider routing for orchestrator / worker / synthesizer across 12 providers (brand-iconed), one-click API-key testing + live model discovery, API keys, LM Studio / custom / Qwen endpoints, sidecar controls, budget tuning | ![Settings](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2011.17.46%402x.png) |
| **Forecast workspace** — Ask how a society reacts to an event; depth presets (Quick / Standard / Deep), full-forecast vs research-only mode, a live backend-ready banner, and past + on-backend forecasts in the sidebar | ![Forecast composer](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.15.22%402x.png) |
| **Forecast settings** — DeepResearchForecast backend status with one-click start, the guided setup assistant, environment repair, simulation/report LLM provider switching (incl. MiniMax 国内), backend folder + host URL, auto-launch, default research depth | ![Forecast settings](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.15.06%402x.png) |
| **Provider routing** — Orchestrator, workers, and synthesizer each get their own provider + model; one-click *Test key & fetch* validates the key against the live API and pulls the latest model ids | ![Providers](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.13.45%402x.png) |
| **Budget presets** — Fast / Standard / Thorough scale max tokens, workers, sources per worker, and tool calls per worker together — or tune each cap individually | ![Budget](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.14.57%402x.png) |
| **About** — The architecture at a glance: orchestrator–worker pattern, the full LLM provider roster, search fallback chain, SeekDB knowledge base, Keychain-backed keys | ![About](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.14.35%402x.png) |

---

## The Deep Research Agent — a ReAct loop, end to end

The engine is an **orchestrator–worker–synthesizer** architecture implementing the classic **ReAct** (Reason + Act) pattern, extended with multi-round reflection in the spirit of Anthropic's research-agent design notes:

```
                ┌───────────────────────────────────────────┐
   user query ──▶│ Planner (orchestrator LLM)               │── ResearchPlan ──┐
                └───────────────────────────────────────────┘                  │
                                                                               ▼
                                  ┌────────────────────────────────────────────────────┐
                                  │ Worker pool (TaskGroup, N parallel ReAct agents)   │
                                  │  for each subtask:                                 │
                                  │   Thought ─▶ Act (tool) ─▶ Observation ─▶ Thought… │
                                  │   tools: knowledge_base · web_search · fetch_url   │
                                  │          read_pdf · wikipedia · arxiv · reddit     │
                                  │          calculator · current_datetime             │
                                  └────────────────────────────────────────────────────┘
                                                       │  WorkerOutput[]
                                                       ▼
                                  ┌────────────────────────────────────────────────────┐
                                  │ Synthesizer (cloud or local LLM)                   │
                                  │  cites every load-bearing claim, [1][2] markers    │
                                  └────────────────────────────────────────────────────┘
                                                       │  draft markdown
                                                       ▼
                                  ┌────────────────────────────────────────────────────┐
                                  │ Reflector  ── rounds 2–3: gap-finding              │
                                  │            ── rounds 4–6: deepening + cross-verify │
                                  └────────────────────────────────────────────────────┘
                                                       │  new subtasks
                                                       └─────▶ loop until maxRounds
```

What this buys you over a one-shot RAG pipeline:

- **No early termination.** Earlier "ready" verdicts used to collapse the difference between Fast and Thorough modes. The engine now commits to running every configured round; when the reflector finds no gaps, it switches to **deepening mode** — cross-verifying load-bearing claims, hunting for counter-evidence, surfacing 30–90-day updates, replacing generic prose with hard numbers. If the LLM still produces nothing, the engine synthesizes deepening subtasks itself so no round is a no-op.
- **Real source diversity.** Each worker is told to issue 2+ search queries with different phrasings, then fetch *at least* `sourceTarget − 2` and *up to* `sourceTarget` distinct URLs (4 fast / 6 standard / 12 thorough). Paywalled or off-topic pages trigger a fallback fetch rather than a quiet skip.
- **Provider-agnostic tool calling.** A unified `LLMRequest(messages:, tools:, …)` envelope is translated into Anthropic's `tool_use`, OpenAI's `tools[].function`, Gemini's `function_declarations`, *and* Ollama's `/api/chat tools` field — including streaming `tool_call` parsing for each. DeepSeek, MiniMax, Kimi, Qwen, LM Studio, and custom endpoints reuse the OpenAI path through one shared `OpenAICompatibleClient` (reasoning-model `reasoning_content` is parsed but never leaks into answers). Tool-call argument parsing accepts both wire formats: the OpenAI-spec incremental string fragments *and* the complete `arguments` JSON object that some gateways (Alibaba DashScope / Qwen compatible-mode) emit in a single chunk — the latter was previously dropped, which made every tool call on those providers fail with "invalid arguments".
- **Hard budget envelope.** A shared `BudgetMeter` actor enforces wall-clock, token, per-worker tool-call, and per-worker source caps. Fast / Standard / Thorough presets scale every dimension together.

---

## Forecast — predict how a society reacts

The **Forecast** workspace (toolbar toggle: Research ⇄ Forecast) answers a different kind of question: not *"what is true?"* but *"what will happen?"*. Type an event — *"How will US chip-export policy reshape the semiconductor industry by 2030?"* — and the app drives the local DeepResearchForecast prediction backend through a six-stage pipeline, rendering every stage natively:

```
 prompt ─▶ ① Deep Research (DeerFlow) ─▶ ② Ontology ─▶ ③ Knowledge Graph (Graphiti)
                                                              │
 ⑥ Prediction Report ◀─ ⑤ Simulation (OASIS) ◀─ ④ Agent Setup ◀┘
```

The composer offers three research depths (**Quick / Standard / Deep** — deeper means more DeerFlow research passes and a richer actor dossier) and two modes: **Full forecast**, or **Research only**, which stops after stage ① when all you want is the dossier. The workspace renders the run as a six-chip **stage stepper** — each chip shows live status, progress, and the stage's last message; click any chip to inspect that stage while later ones are still running, and the view auto-follows the pipeline unless you pin a stage.

### The pipeline, stage by stage

**① Deep Research.** DeerFlow runs a multi-pass background investigation (the number of passes scales with the chosen depth) and produces two artifacts: a research dossier and a cast of **real-world actors** — people, companies, institutions — each with a role, stance, influence weight, and memory seed. A live console streams every research line as it happens, and the actor dossier renders below it as cards.

**② Ontology.** Before extracting anything, the pipeline decides *what kinds of things matter for this question* — a bespoke schema of entity types and relationship types, each with a natural-language description that guides extraction. For a semiconductor forecast that means types like `ChipCompany`, `AILab`, `CEO`, `MediaOutlet` and relations like `LEADS`, `WORKS_FOR`, `SUPPLIES`, `COMPETES_WITH`:

![Ontology stage — inferred entity and relationship types](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.47.32%402x.png)

**③ Knowledge Graph.** Entities and relations are extracted from the research into a **local Graphiti temporal knowledge graph** (embedded FalkorDB, no API key), which the app renders as a *native* interactive force-directed graph (the [Grape](https://github.com/li3zhen1/Grape) package — no web view). Nodes are coloured by entity type and sized by connection count; the control bar pauses/resumes the physics layout, zooms, and toggles labels; the legend keys the type palette. Tap any node and an inspector slides in with its type, summary, and relationship list — tap empty space to dismiss. Large graphs are capped at the top ~140 nodes by degree so the layout stays fluid:

![Knowledge graph — force-directed Graphiti graph with node inspector](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.47.59%402x.png)

**④ Agent Setup.** Each graph actor becomes an autonomous LLM agent with a persona distilled from its dossier entry, a memory, and platform-specific posting behaviour. The stage reports the simulation scale (agents × rounds) once configured.

**⑤ Simulation.** OASIS runs the agent society on simulated **Twitter and Reddit** in parallel for dozens of rounds (the screenshot below: round 40 of 40, 1,668 actions — 613 tweets, 1,055 Reddit posts/comments). The stage view shows per-platform cards, an actions-per-round chart, and a live feed of every post, comment, and like as agents react to the event — and to each other:

![Simulation stage — per-platform telemetry, actions-per-round chart, live agent feed](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.48.06%402x.png)

**⑥ Prediction Report.** A ReAct report agent reads the simulation back out — it can *interview individual simulated agents* as a tool call — and writes a structured forecast: key judgments up front, scenario analysis, and the evidence trail from the simulation. The report renders as native markdown with a table of contents, and you can **chat with it**: follow-up questions run against the full simulation context, and the answer cites which agents were interviewed:

![Prediction report — structured forecast](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.48.10%402x.png)

![Prediction report — AI-rivalry forecast example](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.47.29%402x.png)

### How the app drives the backend

The whole pipeline runs in the local **DeepResearchForecast** Flask backend on `127.0.0.1:5001`; the Swift side is a thin, typed REST layer plus an observable state machine:

- **`MiroFishClient`** wraps every endpoint (`/api/research/*`, `/api/graph/*`, `/api/simulation/*`, `/api/report/*`, `/api/settings/*`) behind `Codable` types and the backend's uniform `{success, data, error}` envelope. Long-running calls (report chat) get their own timeouts; cancel/delete tolerate races where the pipeline already finished.
- **`ForecastRun`** is the `@Observable` heart of the workspace: it starts the pipeline, then polls status — updating each stage's progress, streaming new research-console lines, and following the backend's current stage. When the run completes (or an existing pipeline is imported) it hydrates *everything* in one sweep: research lines, actor dossier, ontology, graph JSON, simulation timeline + telemetry, and the report markdown.
- **SwiftData persistence.** Every forecast is a `ForecastRecord` — prompt, pipeline id, status, progress, error text — so the sidebar survives relaunches. Opening a record whose pipeline is still running **reattaches** the poll loop; opening a finished one re-hydrates all stages from the backend on demand.
- **`MiroFishSupervisor`** owns the backend process: it launches it, watches `/health`, and when the process dies it classifies the exit (port already taken, broken virtualenv, missing `.env` keys) into a message with a fix attached — including a one-click **Repair environment** that rebuilds the Python side.

### Built to survive real pipelines

Forecasts run for tens of minutes against a local Python backend, so the lifecycle is hardened end-to-end:

- **Onboarding assistant.** A guided first-run flow checks the environment, streams the backend's `setup.sh` into a live console, and launches the backend — no terminal needed (the knowledge graph runs locally, so there's no API key to enter). The first forecast downloads a ~470 MB local embedding model once.
- **Cancel / resume / reattach.** Stop a run mid-flight; resume restarts from the first incomplete stage, reusing finished research, graph, and simulation artifacts. Quit the app mid-run and reopening the forecast reattaches to the still-running pipeline.
- **Backend browser.** The sidebar's *On backend* section lists pipelines that exist on the backend but weren't started from this app (web UI, CLI, another machine). One click imports them with full hydration — research lines, dossier, ontology, graph, simulation telemetry, and report.
- **Provider switching.** The simulation/report LLM is switchable from Settings → Forecast — including the **MiniMax domestic (国内) platform** (`api.minimaxi.com`, MiniMax-M3), DeepSeek, Qwen, and more — with keys pulled from the same Keychain the research side uses.

The DeepResearchForecast backend (with a vendored DeerFlow) lives outside the app; point Settings → Forecast at its folder and the app handles launch, health, and shutdown.

---

## SeekDB — your private knowledge base, embedded

Most research questions have *some* answer in documents you already own. Swift Deep Research integrates **SeekDB** (via `pyseekdb`) as a first-class tool the agent reaches for *before* the web:

- **Embedded vector store.** No external server. A small FastAPI **sidecar** ships with the app and auto-launches at startup (`SidecarSupervisor` watches `/health` and PATH-augments for pyenv/Homebrew Python). Concurrent startup calls coalesce onto a single launch, and a **parent-death watchdog** makes the sidecar self-terminate if the app quits, force-quits, *or* crashes — so a stale process never holds port 9100 and blocks the next launch.
- **Zero-setup dependencies.** If the Python packages aren't installed, the supervisor builds a private virtualenv under `~/Library/Application Support/SwiftDeepResearch/sidecar-venv` and `pip install`s `pyseekdb fastapi uvicorn pydantic` automatically, then relaunches from it — the knowledge base just works on first run, no terminal required. Settings → Knowledge has Start/repair and Reinstall buttons for recovery.
- **Drop-in ingestion.** Drag a PDF onto the Knowledge tab; the sidecar chunks it (paragraph/sentence-aware), embeds each chunk, and persists locally.
- **Semantic retrieval as a tool.** Workers see a `knowledge_base(query, k)` tool in their tool catalogue. The system prompt instructs them to call it *first* whenever private documents could be relevant, then corroborate with the web. Results stream into the same `sourceDiscovered` / `sourceFetched` event channel as web hits, so the citation extractor and inspector treat them uniformly. If the sidecar is offline mid-run, the tool asks the supervisor to recover it and retries once.
- **See the chunks you retrieved.** The inspector has a dedicated **Knowledge base** section listing every chunk the agent pulled, ranked by semantic relevance score (colour-coded). Click any chunk to read its full text in a reader sheet — knowledge-base sources in the final report open the same reader, since `kb://` URLs have no browser handler.
- **`kb://` citation scheme.** Knowledge-base passages get synthetic URLs of the form `kb://<doc-id>/<chunk-id>` so the source panel can distinguish them from web hits and link back to the document.

End-to-end this means: ingest the DeepSeek-v4 paper into the KB, ask *"research the architectural innovations of DeepSeek-v4"*, and the worker fires `knowledge_base` first, gets five high-relevance passages, then runs `web_search` to find external benchmarks — producing a synthesis that cites both your private PDF *and* recent blog posts in the same report.

---

## Reliability & resilience

Built to survive flaky networks, slow reasoning models, and cold first-run setup without dropping the run:

- **One worker can't sink the run.** A worker failure — hitting its tool-call cap, an exhausted-retry connection drop, a budget bust — is isolated: that worker ends with whatever it gathered, emits a warning, and the surviving workers still reach synthesis. Only an explicit cancel tears everything down.
- **Transient-network retry on every provider.** Reasoning models (deepseek-reasoner, Kimi thinking) idle before the first token, and intermediaries drop the idle connection ("the network connection was lost"). Every streaming client retries transient drops — but only *before* the server starts responding, so streamed output is never duplicated. Streaming is bounded by an inactivity window rather than a hard whole-request ceiling, so a long synthesis is never cut off mid-answer.
- **Self-healing sidecar.** Beyond launch coalescing and the crash watchdog above: cold pyseekdb initialization gets a generous health window, a partially-built virtualenv is torn down and rebuilt (with `ensurepip` repair and post-install verification), and interpreter probing is time-bounded so a wedged Python can't hang startup. The knowledge-base tool also retries cold-start `5xx` responses and treats a still-launching sidecar as "warming up," not "offline."
- **Robust web fetching.** Page / PDF / Reddit / Wikipedia / arXiv fetches send a real browser User-Agent (no more 403/429 blocks), retry transient failures with backoff (honoring `Retry-After`), and decode non-UTF-8 pages (UTF-8 → Windows-1252 → ISO-8859-1). A single bad URL degrades gracefully instead of failing the run, and a failed fetch hands its per-worker source slot back instead of burning the budget.
- **Calibrated relevance scores.** Knowledge-base similarity is normalized to a stable `(0, 1]` range (higher = closer) regardless of the backend's distance metric, so the inspector's colour-coded score badges and chunk ranking are actually meaningful.

**Guided first run.** If the selected worker provider has no API key, the home screen shows an inline "add a key" banner that opens Settings — instead of letting a curiosity-click fire a run that only fails deep in the engine. Local providers (Ollama, LM Studio, Apple Foundation Models) need no key at all, and a live elapsed-time clock during runs makes a legitimate multi-minute Thorough run distinguishable from a hang.

---

## Features

### Multi-provider LLM routing
Pick a different provider for the planner, workers, and synthesizer — keep planning cheap, splurge on synthesis.

| Provider | Type | Notes |
|---|---|---|
| **Anthropic** | Cloud | Claude Opus 4.x, Sonnet 4.x — streaming + native `tool_use` |
| **OpenAI** | Cloud | GPT-5.5 / 5.4 / 4.1 series, SSE streaming, function calling |
| **Gemini** | Cloud | 2.0 / 2.5 Flash + Pro, function calling |
| **DeepSeek** | Cloud | `deepseek-chat` (V3) / `deepseek-reasoner` (R1), OpenAI-compatible |
| **MiniMax** | Cloud | MiniMax-M3 / M2.x via the domestic (国内) platform `api.minimaxi.com`, OpenAI-compatible |
| **Moonshot Kimi** | Cloud | Kimi K2.6 / K2 series, OpenAI-compatible |
| **Qwen (Alibaba)** | Cloud | Qwen-Max / Plus / Turbo, Qwen3, QwQ — Alibaba Cloud Model Studio (MaaS), OpenAI-compatible via `/compatible-mode/v1` |
| **LM Studio** | Local server | Any loaded model, no API key, live `/v1/models` discovery |
| **Custom endpoint** | Cloud / Local | Any OpenAI-compatible base URL (+ optional key) — persisted across launches |
| **Ollama** | Local server | Tool calling on qwen2.5 / llama3.3 / gpt-oss / mistral-small; context window auto-set to 131 072 |
| **Foundation Models** | On-device | Apple Intelligence FM, when available on macOS 26 |
| **MLX** | On-device | Mistral Small 24B, Qwen 2.5 7B, DeepSeek-R1 Distill |

DeepSeek, MiniMax, Kimi, Qwen, LM Studio, and custom endpoints all speak the OpenAI Chat Completions wire format and share a single, well-tested `OpenAICompatibleClient`. Provider rows carry brand icons, and your provider/model/endpoint choices persist across relaunches.

**Test keys & pull models from the provider.** Each cloud provider has a one-click **Test key & fetch** button (and every API key a **Test** button) that calls the provider's own model API — Anthropic `/v1/models`, OpenAI `/v1/models`, Gemini `/v1beta/models`, the OpenAI-compatible `/v1/models` for DeepSeek / MiniMax / Kimi / Qwen / LM Studio / custom, and Ollama `/api/tags`. A success both **validates the API key** (auth proven against a live endpoint) and **refreshes the model picker with the latest model ids** straight from the source, so you're never stuck with a stale hardcoded list.

### Multi-backend web search with fallback
Configured priority order: **Tavily** (agent-optimised) → **Exa** (semantic) → **Brave** (general) → **DuckDuckGo** (HTML, no key). Each backend validates HTTP status before decoding, so a 401 / 429 / 422 surfaces in the inspector instead of silently disappearing as "no results."

### Three depth presets
| Preset | Rounds | Workers | Sources/worker | Tool calls/worker | Wall clock |
|---|---|---|---|---|---|
| **Fast** | 1 | 2 | 4 | 6 | 180 s |
| **Standard** | 3 | 4 | 6 | 20 | 900 s |
| **Thorough** | 6 | 6 | 12 | 36 | 1 800 s |

### Inspector & live event stream
Every plan, worker start, tool invocation, tool result, source discovery, source fetch, reflection, and citation flows through a typed `ResearchEvent` async stream. The right-hand inspector renders them live so you can watch the agent think.

### Citation extraction
After synthesis, a dedicated `CitationExtractor` re-reads the draft and maps every `[N]` marker back to the source it claims, exposing the result in a sources panel with title, URL, fetched extract, and click-through.

---

## Getting started

### Requirements
- macOS 26 (Tahoe) on Apple Silicon
- Xcode 26
- Python 3.10+ on `PATH` (the app auto-creates a virtualenv and installs the SeekDB deps on first run — manual `pip install -r sidecar/requirements.txt` is optional)
- Optional: API keys for any combination of Anthropic, OpenAI, Gemini, DeepSeek, MiniMax, Moonshot/Kimi, Qwen (Alibaba Cloud Model Studio), a custom endpoint, Tavily, Exa, Brave
- Optional: Ollama or LM Studio running locally with at least one tool-capable model loaded
- Optional (Forecast): a local DeepResearchForecast checkout (with its vendored DeerFlow), e.g. at `~/Downloads/DeepResearchForecast` — its knowledge graph runs locally, so there's no API key; the in-app onboarding assistant runs its `setup.sh` and launches the backend for you

### Download (.dmg)
> **Requirements: macOS 26.0 (Tahoe) or later, Apple Silicon.** The app won't launch on earlier macOS.

Grab the latest `Swift-Deep-Research-<version>.dmg` from the [Releases](https://github.com/linroger/Swift-Deep-Research/releases) page, open it, and drag **Swift Deep Research** to **Applications**.

The build is ad-hoc signed (not yet notarized with a Developer ID), so on first launch macOS Gatekeeper flags it as "from an unidentified developer." Open it the first time with **either**:
- **Right-click** (Control-click) the app in `/Applications` → **Open** → **Open** in the dialog, **or**
- run once: `xattr -dr com.apple.quarantine "/Applications/Swift Deep Research.app"`

After the first open it launches normally. Building from source in Xcode avoids this entirely.

### Build & run
1. Open `Swift Deep Research.xcodeproj` in Xcode 26.
2. Build (⌘B) and run (⌘R).
3. On first launch the app spawns the SeekDB sidecar (`sidecar/seekdb_sidecar.py`) on `127.0.0.1:9100`, building a virtualenv and installing its Python deps automatically if needed.
4. Open Settings → paste any API keys you want to use (Anthropic, OpenAI, Gemini, DeepSeek, MiniMax, Kimi, …); point the LM Studio / custom-endpoint cards at a local or self-hosted server.
5. Drag PDFs into the Knowledge tab if you want a private KB.
6. Type a question in the hero composer, pick a depth preset, and run.
7. For forecasts: switch the toolbar to **Forecast**, let the onboarding assistant set up and launch the DeepResearchForecast backend (or point Settings → Forecast at an existing checkout), then ask how a society reacts to an event.

### Sidecar manually
If the auto-launch ever fails (PATH issues, missing Python), run it yourself:
```bash
cd sidecar
python3 seekdb_sidecar.py
```
The app will detect the running instance via `/health` and connect automatically.

---

## Project layout

```
Swift Deep Research/
├── Bootstrap/        # App lifecycle, dependency wiring
├── Domain/           # Value types: LLMMessage, LLMRequest, ResearchPlan,
│                     # ResearchEvent, AgentBudget, FetchedSource, …
├── Engine/           # ResearchEngine, Planner, WorkerAgent (ReAct loop),
│                     # Synthesizer, Reflector, IterationController
├── Forecast/         # MiroFishClient (REST), ForecastRun (pipeline state),
│                     # MiroFishSupervisor (backend launch/repair), ForecastOnboarding
├── Interface/        # SwiftUI: MainScene, Composer, ResearchCanvas,
│                     # SourcePanel, KBChunkDetail, SettingsSheet, ConversationView
│   └── Forecast/     # Pipeline stepper, KnowledgeGraphView (Grape), simulation
│                     # telemetry, report + chat, onboarding, backend browser
├── Knowledge/        # SeekDBClient, SidecarSupervisor (venv bootstrap), KnowledgeBase
├── LLM/              # Provider clients (Anthropic, OpenAI, Gemini, Ollama,
│                     # FoundationModels, MLX) + OpenAICompatibleClient
│                     # (DeepSeek/MiniMax/Kimi/LM Studio/custom) behind one LLMClient
├── ResearchTools/    # Tool implementations: WebSearchTool, WebReaderTool,
│                     # KnowledgeBaseTool, ArXivTool, WikipediaTool, …
├── Shared/           # KeychainStore, Logging, HTTP helpers
└── Storage/          # SwiftData @Model persistence
sidecar/              # Python FastAPI seekdb sidecar
```

---

## Inspirations & related work
- Anthropic's "Building effective agents" and multi-agent research notes
- The original **ReAct** paper (Yao et al., *Reasoning + Acting in Language Models*)
- Perplexity / ChatGPT Search citation-rendering pattern
- Open-source agents: STORM, GPT-Researcher, smolagents
- Forecast stack: DeepResearchForecast, ByteDance **DeerFlow**, local **Graphiti** temporal knowledge graph (embedded FalkorDB), CAMEL-AI **OASIS** social simulation, **Grape** force-directed graphs

---

## License
MIT — see `LICENSE`.
