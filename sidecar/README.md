# pyseekdb Sidecar

A small FastAPI server that wraps [pyseekdb](https://github.com/oceanbase/pyseekdb)
(OceanBase's Python SDK for seekdb vector search). The Swift app talks to it
over plain HTTP so the macOS process never has to embed a Python runtime.

## One-time install

Dependencies are pinned in [`requirements.txt`](requirements.txt) (pydantic v2
is mandatory — the sidecar is Pydantic-v2-specific):

```bash
python3 -m pip install -r sidecar/requirements.txt
```

## Run

```bash
python3 sidecar/seekdb_sidecar.py --port 9100
```

If you already run a standalone seekdb service installed through Homebrew or an
OceanBase tap, keep this sidecar as the Swift-facing HTTP bridge and point it
at the server-mode database:

```bash
python3 sidecar/seekdb_sidecar.py --port 9100 --server-host 127.0.0.1 --server-port 2881
```

Optional flags:

| flag | default | what it does |
|------|---------|--------------|
| `--host` | `127.0.0.1` | Bind address. Keep localhost-only unless you know what you're doing. |
| `--port` | `9100` | TCP port the Swift app dials into. |
| `--data-dir` | `~/Library/Application Support/SwiftDeepResearch/seekdb` | Where embeddings + the journal live. |
| `--database` | `research` | seekdb database name. |
| `--collection` | `research_kb` | seekdb collection name. |
| `--server-host` | unset | Optional server-mode seekdb host instead of embedded mode. |
| `--server-port` | `2881` | Optional server-mode seekdb port. |

## What the Swift app expects

The Swift app calls these endpoints. The exact response shapes live in
`Swift Deep Research/Knowledge/SeekDBClient.swift`.

- `GET  /health`
- `GET  /documents`
- `POST /documents`         body: `{ title, text, metadata?, id? }`
- `POST /documents/bulk`    body: `[ {...}, ... ]`
- `POST /query`             body: `{ query, k }`
- `DELETE /documents/{id}`
- `POST /reset`

## Architecture

The sidecar keeps a tiny JSON journal (`documents.json`) next to seekdb's
own storage so the UI can show document-level metadata (title, chunk count,
added-at) even though seekdb itself stores per-chunk embeddings. Re-uploading
a document with the same title and similar prefix replaces all its chunks.

Chunking happens server-side: documents over 1500 chars are split on paragraph
and sentence boundaries with 200 chars of overlap. That's enough to keep most
semantic boundaries while fitting comfortably in a worker LLM's context.
