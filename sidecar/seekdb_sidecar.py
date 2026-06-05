"""
Swift Deep Research — pyseekdb sidecar.

A tiny FastAPI server that wraps pyseekdb so the Swift app can ingest, query,
and delete documents in an OceanBase seekdb collection without needing a
Python embedding directly inside the macOS process.

Run manually from a terminal:

    python3 -m pip install pyseekdb fastapi uvicorn pydantic
    python3 sidecar/seekdb_sidecar.py --host 127.0.0.1 --port 9100 \
        --data-dir ~/Library/Application\\ Support/SwiftDeepResearch/seekdb \
        --collection research_kb

Endpoints (all JSON, no auth — bound to localhost only by default):

    GET  /health
    GET  /documents                  → [{id, title, chunks, added_at, source}]
    POST /documents                  → upsert {id?, title, text, metadata?}
    POST /documents/bulk             → upsert [{...}, ...]
    POST /query  {query, k}          → [{id, text, score, metadata}]
    DELETE /documents/{id}
    POST /reset                      → wipe collection
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import logging
import math
import os
import re
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

try:
    from fastapi import FastAPI, HTTPException
    from pydantic import BaseModel
    import uvicorn
except ImportError as exc:  # pragma: no cover
    sys.stderr.write(
        "Missing dependencies. Install with:\n"
        "    python3 -m pip install pyseekdb fastapi uvicorn pydantic\n"
    )
    raise SystemExit(2) from exc

try:
    import pyseekdb
except ImportError as exc:  # pragma: no cover
    sys.stderr.write(
        "pyseekdb is not installed. Install with:\n"
        "    python3 -m pip install pyseekdb\n"
    )
    raise SystemExit(2) from exc

LOG = logging.getLogger("seekdb_sidecar")
LOG.setLevel(logging.INFO)


def _distance_to_score(dist: Any) -> Optional[float]:
    """Convert a raw vector distance into a similarity score in (0, 1].

    The previous `1.0 - dist` formula assumed a cosine distance in [0, 1].
    pyseekdb/OceanBase may return L2 or inner-product distances that exceed 1.0
    (or are NaN on degenerate vectors), which produced negative/NaN scores that
    mis-sorted results and rendered as "0%" in the UI. `1 / (1 + d)` is monotonic
    decreasing in distance, always lands in (0, 1], and keeps "higher = closer".
    """
    if dist is None:
        return None
    try:
        d = float(dist)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(d):
        return None
    if d < 0.0:
        d = 0.0
    return 1.0 / (1.0 + d)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


class Settings(BaseModel):
    data_dir: Path
    database: str = "research"
    collection: str = "research_kb"
    server_host: Optional[str] = None
    server_port: int = 2881

    def ensure_dir(self) -> None:
        # The local journal lives here in both embedded and server mode so the
        # Swift UI can list document-level metadata consistently.
        self.data_dir.mkdir(parents=True, exist_ok=True)

    @property
    def mode(self) -> str:
        return "server" if self.server_host else "embedded"


# ---------------------------------------------------------------------------
# Storage adapter
# ---------------------------------------------------------------------------


class KnowledgeBase:
    """Thin wrapper around pyseekdb embedded mode + metadata journal.

    pyseekdb already persists vectors; we keep a small JSON sidecar so the
    UI can list "documents" (groups of chunks) cleanly even though the
    underlying storage is chunk-level.
    """

    def __init__(self, settings: Settings):
        self.settings = settings
        self.settings.ensure_dir()
        self._lock = threading.Lock()
        if settings.server_host:
            self._client = pyseekdb.Client(
                host=settings.server_host,
                port=settings.server_port,
                database=settings.database,
            )
        else:
            # Embedded mode bootstrap: pyseekdb's seekdb engine does NOT
            # create user databases on init — the only one that always
            # exists is `information_schema`. So use AdminClient (which
            # connects via information_schema) to create our database
            # first, then open a Client pointing at it. Without this we'd
            # hit OB_ERR_BAD_DATABASE(1049) "Unknown database".
            admin = pyseekdb.AdminClient(path=str(settings.data_dir))
            try:
                admin.create_database(settings.database)
            except Exception as exc:
                # `CREATE DATABASE IF NOT EXISTS` shouldn't fail, but ignore
                # benign "already exists" races defensively.
                if "exists" not in str(exc).lower():
                    raise
            self._client = pyseekdb.Client(
                path=str(settings.data_dir),
                database=settings.database,
            )
        # `get_or_create_collection` is the documented entry point.
        self._collection = self._client.get_or_create_collection(
            name=settings.collection
        )
        self._journal_path = settings.data_dir / "documents.json"
        self._journal: dict[str, dict[str, Any]] = {}
        if self._journal_path.exists():
            try:
                self._journal = json.loads(self._journal_path.read_text())
            except json.JSONDecodeError:
                LOG.warning("Corrupt journal at %s, starting fresh", self._journal_path)

    # --- journal helpers ------------------------------------------------

    def _persist_journal(self) -> None:
        tmp = self._journal_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._journal, indent=2, sort_keys=True))
        os.replace(tmp, self._journal_path)

    # --- mutations ------------------------------------------------------

    def upsert(
        self,
        doc_id: str,
        title: str,
        text: str,
        metadata: Optional[dict[str, Any]] = None,
        chunk_chars: int = 1500,
        overlap_chars: int = 200,
    ) -> dict[str, Any]:
        metadata = dict(metadata or {})
        metadata.setdefault("title", title)
        if not text.strip():
            raise ValueError("document text is empty")
        chunks = self._split(text, chunk_chars, overlap_chars)
        if not chunks:
            raise ValueError("document produced no chunks")
        with self._lock:
            # Remove any old chunks for this document first so re-uploads don't
            # leave stale embeddings.
            self._delete_chunks_of(doc_id)
            ids = [f"{doc_id}::{i:04d}" for i in range(len(chunks))]
            metadatas = [
                {**metadata, "doc_id": doc_id, "chunk_index": i}
                for i in range(len(chunks))
            ]
            self._collection.add(
                ids=ids,
                documents=chunks,
                metadatas=metadatas,
            )
            self._journal[doc_id] = {
                "id": doc_id,
                "title": title,
                "chunks": len(chunks),
                "added_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
                "source": metadata.get("source"),
                "metadata": metadata,
            }
            self._persist_journal()
        return self._journal[doc_id]

    def delete(self, doc_id: str) -> bool:
        with self._lock:
            removed = self._delete_chunks_of(doc_id)
            if doc_id in self._journal:
                del self._journal[doc_id]
                self._persist_journal()
            return removed > 0

    def reset(self) -> None:
        with self._lock:
            try:
                self._client.delete_collection(self.settings.collection)
            except Exception:  # pragma: no cover
                pass
            self._collection = self._client.get_or_create_collection(
                name=self.settings.collection
            )
            self._journal = {}
            self._persist_journal()

    def _delete_chunks_of(self, doc_id: str) -> int:
        try:
            # `ids` are always returned; "ids" is NOT a valid `include` token and
            # raises ValueError on pyseekdb/Chroma-style backends — which would
            # leave stale chunks behind on re-upsert (duplicate retrieval hits)
            # and make delete() a no-op. Request no extra fields.
            results = self._collection.get(where={"doc_id": doc_id})
            ids = results.get("ids") or []
            if isinstance(ids, list) and ids and isinstance(ids[0], list):
                ids = ids[0]
            if ids:
                self._collection.delete(ids=ids)
            return len(ids)
        except Exception as exc:  # pragma: no cover
            LOG.warning("delete-by-doc-id failed: %s", exc)
            return 0

    # --- reads ----------------------------------------------------------

    def list_documents(self) -> list[dict[str, Any]]:
        return sorted(self._journal.values(), key=lambda d: d.get("added_at", ""), reverse=True)

    def query(self, text: str, k: int = 6) -> list[dict[str, Any]]:
        if not text.strip():
            return []
        with self._lock:
            res = self._collection.query(
                query_texts=[text],
                n_results=max(1, min(k, 25)),
                include=["documents", "metadatas", "distances"],
            )
        # pyseekdb returns parallel lists, one per query. We sent one query.
        ids = (res.get("ids") or [[]])[0]
        documents = (res.get("documents") or [[]])[0]
        metadatas = (res.get("metadatas") or [[]])[0]
        distances = (res.get("distances") or [[]])[0]
        out = []
        for chunk_id, doc, meta, dist in zip(ids, documents, metadatas, distances):
            out.append(
                {
                    "id": chunk_id,
                    "text": doc,
                    "score": _distance_to_score(dist),
                    "metadata": meta or {},
                }
            )
        return out

    # --- utilities ------------------------------------------------------

    @staticmethod
    def _split(text: str, chunk_chars: int, overlap_chars: int) -> list[str]:
        text = re.sub(r"\r\n?", "\n", text).strip()
        if not text:
            return []
        if len(text) <= chunk_chars:
            return [text]

        def overlap_tail(chunk: str) -> str:
            if overlap_chars <= 0 or len(chunk) <= overlap_chars:
                return ""
            return chunk[-overlap_chars:].strip()

        def split_long_block(block: str) -> list[str]:
            sentences = re.split(r"(?<=[.!?。！？])\s+", block.strip())
            pieces: list[str] = []
            current = ""
            for sentence in sentences:
                if not sentence:
                    continue
                if len(sentence) > chunk_chars:
                    if current:
                        pieces.append(current.strip())
                        current = ""
                    step = max(1, chunk_chars - overlap_chars)
                    for start in range(0, len(sentence), step):
                        pieces.append(sentence[start : start + chunk_chars].strip())
                    continue
                candidate = sentence if not current else f"{current} {sentence}"
                if len(candidate) <= chunk_chars:
                    current = candidate
                else:
                    pieces.append(current.strip())
                    tail = overlap_tail(current)
                    current = f"{tail} {sentence}".strip() if tail else sentence
            if current:
                pieces.append(current.strip())
            return [piece for piece in pieces if piece]

        paragraphs = [
            para.strip()
            for para in re.split(r"\n\s*\n+", text)
            if para.strip()
        ]
        chunks: list[str] = []
        current = ""
        for paragraph in paragraphs:
            for block in split_long_block(paragraph):
                if not current:
                    current = block
                    continue
                candidate = f"{current}\n\n{block}"
                if len(candidate) <= chunk_chars:
                    current = candidate
                else:
                    chunks.append(current.strip())
                    tail = overlap_tail(current)
                    current = f"{tail}\n\n{block}".strip() if tail else block
        if current:
            chunks.append(current.strip())
        return chunks


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


class UpsertBody(BaseModel):
    # Module-level (not nested inside build_app) so Pydantic v2 / FastAPI can
    # resolve the forward ref when generating the request-body schema. When
    # these were defined inside the function, FastAPI fell back to treating
    # them as query parameters and every POST 422'd with `body is required`.
    id: Optional[str] = None
    title: str
    text: str
    metadata: Optional[dict[str, Any]] = None


class QueryBody(BaseModel):
    query: str
    k: int = 6


def build_app(kb: KnowledgeBase) -> FastAPI:
    app = FastAPI(title="Swift Deep Research — seekdb sidecar")

    def _derive_id(body: UpsertBody) -> str:
        if body.id:
            return body.id
        digest = hashlib.sha1(
            (body.title + "::" + body.text[:1024]).encode("utf-8")
        ).hexdigest()[:16]
        return f"doc-{digest}"

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {
            "ok": True,
            "mode": kb.settings.mode,
            "database": kb.settings.database,
            "collection": kb.settings.collection,
            "documents": len(kb._journal),
        }

    @app.get("/documents")
    def list_docs() -> list[dict[str, Any]]:
        return kb.list_documents()

    @app.post("/documents")
    def upsert(body: UpsertBody) -> dict[str, Any]:
        doc_id = _derive_id(body)
        try:
            return kb.upsert(
                doc_id=doc_id,
                title=body.title,
                text=body.text,
                metadata=body.metadata,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/documents/bulk")
    def upsert_bulk(bodies: list[UpsertBody]) -> list[dict[str, Any]]:
        out = []
        for body in bodies:
            doc_id = _derive_id(body)
            try:
                out.append(
                    kb.upsert(
                        doc_id=doc_id,
                        title=body.title,
                        text=body.text,
                        metadata=body.metadata,
                    )
                )
            except ValueError as exc:
                raise HTTPException(status_code=400, detail=str(exc)) from exc
        return out

    @app.delete("/documents/{doc_id}")
    def delete(doc_id: str) -> dict[str, Any]:
        ok = kb.delete(doc_id)
        if not ok:
            raise HTTPException(status_code=404, detail="document not found")
        return {"deleted": doc_id}

    @app.post("/reset")
    def reset() -> dict[str, Any]:
        kb.reset()
        return {"ok": True}

    @app.post("/query")
    def query(body: QueryBody) -> list[dict[str, Any]]:
        return kb.query(body.query, body.k)

    return app


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def _start_parent_watchdog() -> None:
    """Self-terminate when the launching app process dies.

    The Swift app launches this sidecar as a child process but cannot reliably
    kill it on crash, force-quit, or debugger stop — leaving an orphan that
    keeps holding the port and blocks the next launch with "address already in
    use". We watch the parent PID: when the app exits, this process is
    re-parented to launchd (PID 1), so `getppid() == 1` means "parent died" and
    we exit immediately, freeing the port. `os._exit` skips atexit/uvicorn
    shutdown hooks deliberately — we want a prompt, unconditional exit.
    """
    initial_parent = os.getppid()
    # If we were already orphaned at launch (parent == 1), there is nothing to
    # watch; rely on normal shutdown.
    if initial_parent <= 1:
        return

    def _watch() -> None:
        while True:
            try:
                ppid = os.getppid()
            except Exception:  # pragma: no cover
                ppid = 1
            if ppid == 1 or ppid != initial_parent:
                LOG.info("parent process %s exited; sidecar shutting down", initial_parent)
                os._exit(0)
            time.sleep(2.0)

    t = threading.Thread(target=_watch, name="parent-watchdog", daemon=True)
    t.start()


def main() -> int:
    parser = argparse.ArgumentParser(description="pyseekdb sidecar for Swift Deep Research")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9100)
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path.home() / "Library" / "Application Support" / "SwiftDeepResearch" / "seekdb",
    )
    parser.add_argument("--database", default="research")
    parser.add_argument("--collection", default="research_kb")
    parser.add_argument(
        "--server-host",
        default=None,
        help="Optional server-mode seekdb host, for example a Homebrew/tap-installed seekdb service.",
    )
    parser.add_argument("--server-port", type=int, default=2881)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    settings = Settings(
        data_dir=args.data_dir,
        database=args.database,
        collection=args.collection,
        server_host=args.server_host,
        server_port=args.server_port,
    )
    kb = KnowledgeBase(settings)
    app = build_app(kb)
    _start_parent_watchdog()
    LOG.info(
        "seekdb sidecar starting on %s:%s (mode=%s, data=%s, collection=%s)",
        args.host,
        args.port,
        settings.mode,
        settings.data_dir,
        settings.collection,
    )
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
