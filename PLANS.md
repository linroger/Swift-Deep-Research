# Swift Deep Research Robustness Plan

**Created (UTC):** 2026-05-25T09:50Z
**Scope:** One focused implementation slice that improves deep-research quality without running an app build.

## Objective

Make the existing v2 deep-research framework more reliable and useful by improving three user-visible flows:

1. Provider tool calls must deliver complete JSON arguments to tools, especially Anthropic streaming tool use.
2. Uploaded documents queried through pyseekdb must become first-class evidence that workers, the synthesizer, citations, persistence, and the UI can all see.
3. Document ingestion must reject bad inputs clearly and chunk text along semantic boundaries rather than blind fixed windows.

## Constraints

- Do not build the app because package dependencies have not been fetched.
- Preserve the in-place rebuild and existing dirty worktree.
- Keep edits narrowly scoped to provider parsing, worker evidence handling, knowledge-base tooling, sidecar ingestion, and documentation.

## Steps

1. Patch Anthropic SSE handling so streamed tool arguments are keyed by the actual tool-use ID.
2. Add generic worker payload parsing so any tool that returns `FetchedSource` or `[FetchedSource]` can contribute citation evidence.
3. Update `KnowledgeBaseTool` to emit and return synthetic `FetchedSource` records for `kb://` document passages.
4. Make worker prompting explicitly prefer `knowledge_base` when that tool is available.
5. Harden the pyseekdb sidecar with empty-document validation and paragraph-aware chunking.
6. Update progress/handoff artifacts and run non-build validation checks.

## Acceptance Checks

| Check | Evidence |
|---|---|
| Anthropic tool-call deltas attach to real tool-call IDs | Source review of `AnthropicClient` parser state |
| Knowledge-base hits are available to citation extraction | Source review of `KnowledgeBaseTool` payload and `WorkerAgent` generic extraction |
| Sidecar rejects empty documents and chunks better | `python3 -m py_compile sidecar/seekdb_sidecar.py` plus source review |
| No build was run | Final notes and handoff verification summary |

