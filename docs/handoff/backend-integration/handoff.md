# Handoff.md — Backend Integration (MiroFish → DeepResearchForecast / Graphiti)

**Last Updated (UTC):** 2026-06-15
**Status:** Complete
**Current Focus:** DONE — Swift app integrated with the new DeepResearchForecast (Graphiti) backend; onboarding Zep step removed; build green; runtime contract verified against the live backend.

## Implementation log (what changed — 11 slices, all landed)
- `Forecast/ForecastModels.swift`: default repo path → `~/Downloads/DeepResearchForecast`; `.graph` subtitle "(Zep)"→"(Graphiti)"; doc comments.
- `Forecast/ForecastOnboarding.swift`: **deerflowDir fallback → `<repo>/deer-flow`** (was sibling); removed `zepConfigured/zepKeyInput/zepSaveMessage`, the `5-zep` check (→ `5-graph` info row, always pass), `saveZepKey()`, the Zep sync in `startBackend()`; class doc.
- `Interface/Forecast/ForecastOnboardingView.swift`: removed `zepSection` card + call; renumbered steps (1 checks → 2 setup → 3 launch); refreshed copy.
- `Interface/AppEnvironment.swift`: `syncMiroFishEnv` no longer injects `ZEP_API_KEY`; docs.
- `Forecast/MiroFishSupervisor.swift`: set `SETUP_NONINTERACTIVE=1` for setup.sh; removed dead `ZEP_API_KEY` error branch (+ `GRAPH_BACKEND` hint); header/path/dependency comments.
- `Interface/SettingsSheet.swift`: "MiroFish location"→"Backend location" + placeholder `~/Downloads/DeepResearchForecast`; "Zep knowledge graph" group → "Knowledge graph" (local, no key); footers/help; `provider(for:)` bucket drops `.zep`.
- `Shared/KeychainStore.swift`: removed `.zep` case + its 2 switch arms.
- Copy: `KnowledgeGraphView.swift`, `ForecastPipelineView.swift`, `ForecastRun.swift`, `MiroFishClient.swift` (Zep→Graphiti comments).
- No backend/setup.sh edits needed (already migrated).

## 7) Scenario verification (against the LIVE backend)
- `xcodebuild` Debug build **SUCCEEDED** (0 errors, 0 new warnings).
- Backend live at `127.0.0.1:5001`: `GET /health` → `{"service":"MiroFish Backend","status":"ok"}` (decodes as `MFHealth`, passes supervisor signature).
- `GET /api/settings/llm` → exact `MFProviderInfo`/`MFProvider` shape. `GET /api/research/list` → exact `MFPipelineSummary` shape (created_at, global_progress, pipeline_id, prompt, report_id, status).
- `.env`: `APP_API_TOKEN` unset → loopback (`127.0.0.1`) always allowed by the auth gate (`__init__.py:85`) even for mutating calls → no 401 risk.
- All required files present at `~/Downloads/DeepResearchForecast` (backend/run.py, setup.sh, backend/.venv/bin/python3.12, deer-flow/deerflow_research.py, .env).

## Open follow-ups (optional, not blocking)
- Swift repo README.md/README_zh.md still describe the MiroFish/Zep flow — doc pass.
- Optional: surface new backend capabilities (`/api/research/<id>/scenario`, `/continue`, `GET /api/research/preflight`, `/api/v1` SDK) in the UI.
- Stale untracked copies at Swift repo root (`MiroFish-0.1.2/`, `deer-flow/`, `deerflow_bridge/`) are unused by the app (it targets `~/Downloads/DeepResearchForecast`).

## 1) Request & Context
- **User's request:** "read through this codebase to get acquainted with the app. I changed the backend to `/Users/rogerlin/Downloads/DeepResearchForecast` which is an optimized & streamlined version of the old backend, with the zep knowledge graph feature replaced with graphiti for a local knowledge graph. Read through that codebase and the updated github repo https://github.com/linroger/DeepResearchForecast.git, integrate this app with this updated version of the backend, and update the setup script in the onboarding portion." Also: "employ a team of subagents running in parallel orchestrated by you."
- **Operational constraints:** macOS 26, Swift 6.2, Xcode 26. Backend = Flask :5001. Ultracode mode on (orchestrate with workflows).
- **Old backend (what the Swift client currently encodes):** MiroFish-0.1.2 at `~/Downloads/mirofish/MiroFish-0.1.2` (Zep Cloud graph; needs ZEP_API_KEY).
- **New backend:** `~/Downloads/DeepResearchForecast` (repo "DeepAgentForecast"/"DeepResearchForecast"). Local Graphiti (embedded FalkorDB / falkordblite, no API key). Same Flask blueprint families + new `/api/v1` SDK blueprint.

## 2) Key findings (pre-orchestration scouting)
- **HTTP contract is ~identical.** Every route the Swift `MiroFishClient` calls exists in the new backend with the same path/verb.
- **Graph data shape preserved.** New `graph_builder.get_graph_data()` returns nodes `{uuid,name,labels,summary,created_at}` + edges `{uuid,name,fact,fact_type,source_node_uuid,target_node_uuid,source_node_name,target_node_name}` — matches Swift `MFNode`/`MFEdge` exactly.
- **Zep → Graphiti.** `Config.validate()` no longer requires `ZEP_API_KEY` (kept as sentinel `'local-graphiti'`). New env: `GRAPH_BACKEND` (auto|falkordblite|falkordb|kuzu), `GRAPHITI_DATA_DIR`, `GRAPHITI_EMBED_MODEL`, `GRAPHITI_EMBED_DIM`, `GRAPHITI_RERANKER`, `FALKORDB_HOST/PORT`. Embedded falkordblite needs Python ≥3.12, no Docker.

## 3) Plan
1. [DONE] Scout both codebases; confirm contract + graph-shape compatibility.
2. [IN PROGRESS] Orchestrate parallel agents: full endpoint-contract diff, setup.sh analysis (old vs new), Swift edit-site map, supervisor launch contract, backend launch/venv contract.
3. Implement Swift edits: paths/naming, onboarding Zep→Graphiti, supervisor env-sync, settings UI, stage subtitle.
4. Update setup.sh wiring in onboarding.
5. Build (xcodebuild) + smoke verify.

## 4) Assumptions
- New backend default location = `~/Downloads/DeepResearchForecast` (matches current disk + repo name). User can override in Settings → Forecast.
- "Update the setup script in the onboarding portion" = make Swift onboarding correctly drive the NEW setup.sh and drop the Zep step.

## 5) Verified verdict (from 6-agent workflow wf_a49d69ec-58f)
- **Wire contract byte-compatible.** Zero changes to MiroFishClient/ForecastRun/MF* structs. Every route, the {success,data,error} envelope, bare /health (service "MiroFish Backend"), graph node/edge shapes preserved; decoder has no keyDecodingStrategy so backend's extra keys are dropped.
- **Two BREAKING path defaults:** ForecastModels.swift:182 (repo path) and ForecastOnboarding.swift:178 (deer-flow now in-repo, was sibling).
- **Dead Zep credential flow** across ForecastOnboarding, ForecastOnboardingView, SettingsSheet, AppEnvironment, KeychainStore, MiroFishSupervisor — backend defaults ZEP_API_KEY to 'local-graphiti' sentinel; validate() only checks GRAPH_BACKEND.
- **Launch hardening:** pass SETUP_NONINTERACTIVE=1 to setup.sh (new interactive provider picker).
- Backend launch otherwise works unmodified once repoRoot points at the new folder (backend/.venv python3.12 verified on disk).
- **No backend/setup.sh code changes required** — setup.sh already migrated.

## 6) Baseline
- `xcodebuild` Debug build **SUCCEEDED** before edits (clean baseline).

## 10) Updates (append-only)
- 2026-06-15: Created. Scouting complete; launching orchestration workflow for exhaustive contract/edit-site mapping.
- 2026-06-15: Workflow complete (6 agents, 741k tokens). Verdict recorded. Baseline build green. Implementing the 11-slice checklist.
- 2026-06-16: Integration implemented + verified (build green, live-backend E2E). Committed on branch `backend-graphiti-integration-and-execplan3` (10edbf5). READMEs (EN+ZH) migrated to Graphiti via 2 agents, committed (b9390e2). Added `scripts/build_dmg.sh` (ad-hoc Release→DMG). Release recon: bundle `com.linroger.Swift-Deep-Research`, ad-hoc sign, hardened runtime, macOS 26, empty entitlements (no sandbox — needed for subprocess launch); only Apple Development identity (no Developer ID → DMG not notarizable, needs Gatekeeper note). Launched EXECPLAN3 survey workflow (8 analysts) → wrote EXECPLAN3.md.
- 2026-06-16: EXECPLAN3 = 69 items (1 P0, 20 P1, 27 P2, 21 P3). Implemented ALL 21 P0/P1 (Wave 1, commit 0b44acc) + 10 P2/P3 (Wave 2, commit 3ea862d) via two parallel agent teams (6 + 3 agents on disjoint files) + a hand-implemented central cluster (AppEnvironment/EngineConfiguration/MiroFishClient/ForecastRun/etc.). All integration builds green, 0 warnings. Version bumped to 2.0/build 2. EXECPLAN3 checkboxes updated; ~38 P2/P3 remain (unchecked) as a follow-up backlog. E3-oobe-2 partial (ad-hoc DMG + README Gatekeeper note; notarization needs a Developer ID). Building v2.0 Release .dmg next → smoke-test → push branch → GitHub release.
</content>
