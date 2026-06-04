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

Built top-to-bottom in Swift 6.2 / SwiftUI for macOS 26 Tahoe with strict concurrency, structured tool calling across every provider, and a Liquid Glass UI.

---

## Screenshots

| | |
|:--|:--:|
| **Hero composer** — Spotlight-style entry with depth presets, knowledge-base toggle, and live provider/model status | ![Composer](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.21%402x.png) |
| **Iterative research canvas** — Round-by-round plan, parallel workers, tool-call drill-down, live activity inspector | ![Canvas](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.39%402x.png) |
| **Sources inspector** — Discovered, fetched, and cited sources beside the draft, plus a Knowledge base section listing retrieved chunks by relevance score (click to read the full chunk) | ![Sources](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.19.44%402x.png) |
| **Knowledge base** — Drop PDFs to chunk + embed via the auto-launched SeekDB sidecar; queried automatically during research | ![Knowledge Base](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.53.03%402x.png) |
| **Settings** — Provider routing for orchestrator / worker / synthesizer across 11 providers, API keys, LM Studio / custom endpoints, sidecar controls, budget tuning | ![Settings](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2011.17.46%402x.png) |

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
- **Provider-agnostic tool calling.** A unified `LLMRequest(messages:, tools:, …)` envelope is translated into Anthropic's `tool_use`, OpenAI's `tools[].function`, Gemini's `function_declarations`, *and* Ollama's `/api/chat tools` field — including streaming `tool_call` parsing for each. DeepSeek, MiniMax, Kimi, LM Studio, and custom endpoints reuse the OpenAI path through one shared `OpenAICompatibleClient` (reasoning-model `reasoning_content` is parsed but never leaks into answers).
- **Hard budget envelope.** A shared `BudgetMeter` actor enforces wall-clock, token, per-worker tool-call, and per-worker source caps. Fast / Standard / Thorough presets scale every dimension together.

---

## SeekDB — your private knowledge base, embedded

Most research questions have *some* answer in documents you already own. Swift Deep Research integrates **SeekDB** (via `pyseekdb`) as a first-class tool the agent reaches for *before* the web:

- **Embedded vector store.** No external server. A small FastAPI **sidecar** ships with the app and auto-launches at startup (`SidecarSupervisor` watches `/health` and PATH-augments for pyenv/Homebrew Python). Quit the app, the sidecar quits with it.
- **Zero-setup dependencies.** If the Python packages aren't installed, the supervisor builds a private virtualenv under `~/Library/Application Support/SwiftDeepResearch/sidecar-venv` and `pip install`s `pyseekdb fastapi uvicorn pydantic` automatically, then relaunches from it — the knowledge base just works on first run, no terminal required. Settings → Knowledge has Start/repair and Reinstall buttons for recovery.
- **Drop-in ingestion.** Drag a PDF onto the Knowledge tab; the sidecar chunks it (paragraph/sentence-aware), embeds each chunk, and persists locally.
- **Semantic retrieval as a tool.** Workers see a `knowledge_base(query, k)` tool in their tool catalogue. The system prompt instructs them to call it *first* whenever private documents could be relevant, then corroborate with the web. Results stream into the same `sourceDiscovered` / `sourceFetched` event channel as web hits, so the citation extractor and inspector treat them uniformly. If the sidecar is offline mid-run, the tool asks the supervisor to recover it and retries once.
- **See the chunks you retrieved.** The inspector has a dedicated **Knowledge base** section listing every chunk the agent pulled, ranked by semantic relevance score (colour-coded). Click any chunk to read its full text in a reader sheet — knowledge-base sources in the final report open the same reader, since `kb://` URLs have no browser handler.
- **`kb://` citation scheme.** Knowledge-base passages get synthetic URLs of the form `kb://<doc-id>/<chunk-id>` so the source panel can distinguish them from web hits and link back to the document.

End-to-end this means: ingest the DeepSeek-v4 paper into the KB, ask *"research the architectural innovations of DeepSeek-v4"*, and the worker fires `knowledge_base` first, gets five high-relevance passages, then runs `web_search` to find external benchmarks — producing a synthesis that cites both your private PDF *and* recent blog posts in the same report.

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
| **MiniMax** | Cloud | MiniMax-M2 / Text-01, OpenAI-compatible |
| **Moonshot Kimi** | Cloud | Kimi K2.6 / K2 series, OpenAI-compatible |
| **LM Studio** | Local server | Any loaded model, no API key, live `/v1/models` discovery |
| **Custom endpoint** | Cloud / Local | Any OpenAI-compatible base URL (+ optional key) — persisted across launches |
| **Ollama** | Local server | Tool calling on qwen2.5 / llama3.3 / gpt-oss / mistral-small; context window auto-set to 131 072 |
| **Foundation Models** | On-device | Apple Intelligence FM, when available on macOS 26 |
| **MLX** | On-device | Mistral Small 24B, Qwen 2.5 7B, DeepSeek-R1 Distill |

DeepSeek, MiniMax, Kimi, LM Studio, and custom endpoints all speak the OpenAI Chat Completions wire format and share a single, well-tested `OpenAICompatibleClient`. Your provider/model/endpoint choices persist across relaunches.

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
- Python 3.10+ on `PATH` (the app auto-creates a virtualenv and installs the SeekDB deps on first run — manual `pip install pyseekdb fastapi uvicorn pydantic` is optional)
- Optional: API keys for any combination of Anthropic, OpenAI, Gemini, DeepSeek, MiniMax, Moonshot/Kimi, a custom endpoint, Tavily, Exa, Brave
- Optional: Ollama or LM Studio running locally with at least one tool-capable model loaded

### Build & run
1. Open `Swift Deep Research.xcodeproj` in Xcode 26.
2. Build (⌘B) and run (⌘R).
3. On first launch the app spawns the SeekDB sidecar (`sidecar/seekdb_sidecar.py`) on `127.0.0.1:9100`, building a virtualenv and installing its Python deps automatically if needed.
4. Open Settings → paste any API keys you want to use (Anthropic, OpenAI, Gemini, DeepSeek, MiniMax, Kimi, …); point the LM Studio / custom-endpoint cards at a local or self-hosted server.
5. Drag PDFs into the Knowledge tab if you want a private KB.
6. Type a question in the hero composer, pick a depth preset, and run.

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
├── Interface/        # SwiftUI: MainScene, Composer, ResearchCanvas,
│                     # SourcePanel, KBChunkDetail, SettingsSheet, ConversationView
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

---

## License
MIT — see `LICENSE`.
