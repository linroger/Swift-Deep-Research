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
import contextlib
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
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import JSONResponse
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

# Pinned embedding model. pyseekdb's default auto-embedding model is
# all-MiniLM-L6-v2 (384-dim). We name it explicitly so a future change to
# pyseekdb's default can't silently swap the model and make new query
# embeddings incompatible with vectors already stored on disk (kb-implicit-
# embedding-fn). If you ever change this, existing collections must be reset.
EMBEDDING_MODEL = "all-MiniLM-L6-v2"

# Upper bound on a single document's text. Embedding is synchronous and holds
# the writer lock; an unbounded document could stall the KB for minutes. ~8 MB
# of text is far larger than any realistic single ingest (kb-no-ingest-batching).
MAX_DOCUMENT_CHARS = 8_000_000

# Number of chunks embedded per _collection.add() call. Batching lets a large
# document embed incrementally and releases the writer lock between batches so
# queries aren't starved for the whole ingest (kb-no-ingest-batching,
# kb-global-lock-serializes-query).
ADD_BATCH_SIZE = 96

# Max accepted request body. A document is at most MAX_DOCUMENT_CHARS of text,
# plus JSON framing and metadata, plus headroom for a bulk array of a few docs.
# Anything larger is almost certainly abusive and is rejected with 413 before
# it is buffered/embedded (kb-no-request-size-limit). NOTE: this is a body-size
# defense-in-depth cap only — the sidecar is still unauthenticated and bound to
# loopback; a shared-secret token between the app and sidecar is a recommended
# follow-up (kb-no-request-size-limit) but is a cross-process change.
MAX_REQUEST_BYTES = 64 * 1024 * 1024


class _ReadWriteLock:
    """A small writer-preferring readers-writer lock (stdlib only).

    The previous single ``threading.Lock`` serialized every ``query()`` behind
    any in-flight ingest because both took the same mutex (kb-global-lock-
    serializes-query). Vector search is read-only, so multiple queries may run
    concurrently; only writers (upsert/delete/reset) need exclusivity. Writers
    are preferred so a steady stream of queries can't starve an ingest.
    """

    def __init__(self) -> None:
        self._cond = threading.Condition(threading.Lock())
        self._readers = 0
        self._writers_waiting = 0
        self._writer_active = False

    def acquire_read(self) -> None:
        with self._cond:
            # Wait while a writer holds the lock or is queued (writer preference).
            while self._writer_active or self._writers_waiting > 0:
                self._cond.wait()
            self._readers += 1

    def release_read(self) -> None:
        with self._cond:
            self._readers -= 1
            if self._readers == 0:
                self._cond.notify_all()

    def acquire_write(self) -> None:
        with self._cond:
            self._writers_waiting += 1
            try:
                while self._writer_active or self._readers > 0:
                    self._cond.wait()
            finally:
                self._writers_waiting -= 1
            self._writer_active = True

    def release_write(self) -> None:
        with self._cond:
            self._writer_active = False
            self._cond.notify_all()

    @contextlib.contextmanager
    def read(self):
        self.acquire_read()
        try:
            yield
        finally:
            self.release_read()

    @contextlib.contextmanager
    def write(self):
        self.acquire_write()
        try:
            yield
        finally:
            self.release_write()


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
        # Readers-writer lock: many concurrent queries, exclusive writers
        # (kb-global-lock-serializes-query).
        self._lock = _ReadWriteLock()
        # Pin the embedding function explicitly so the model is not an implicit
        # pyseekdb default that could change between versions (kb-implicit-
        # embedding-fn). We capture it on self so the warm-up can reuse it.
        try:
            self._embedding_fn: Any = pyseekdb.DefaultEmbeddingFunction(
                model_name=EMBEDDING_MODEL
            )
        except Exception as exc:  # pragma: no cover - defensive
            # If this pyseekdb build doesn't accept the kwarg, fall back to its
            # default factory rather than failing startup outright.
            LOG.warning(
                "could not pin embedding model %s (%s); using pyseekdb default",
                EMBEDDING_MODEL,
                exc,
            )
            self._embedding_fn = pyseekdb.get_default_embedding_function()
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
        # `get_or_create_collection` is the documented entry point. Pass the
        # pinned embedding function so add()/query() auto-embedding is explicit.
        self._collection = self._open_collection()
        self._journal_path = settings.data_dir / "documents.json"
        self._journal: dict[str, dict[str, Any]] = {}
        if self._journal_path.exists():
            try:
                self._journal = json.loads(self._journal_path.read_text())
            except json.JSONDecodeError:
                LOG.warning("Corrupt journal at %s, starting fresh", self._journal_path)
        # Warm up the embedding model at boot so any first-use model download
        # happens during the app's "launching" window, not on the user's first
        # query (kb-implicit-embedding-fn).
        self._warm_up_embeddings()
        # Reconcile the JSON journal against the vector store so list/query
        # agree even if a previous run crashed between add() and journal
        # persist (kb-journal-vector-drift).
        self._reconcile_journal()

    def _open_collection(self) -> Any:
        """Open the collection with the pinned embedding function.

        Some pyseekdb builds reject an embedding_function kwarg on an existing
        collection created without one; fall back to the plain call so we don't
        fail to start on an older on-disk collection.
        """
        try:
            return self._client.get_or_create_collection(
                name=self.settings.collection,
                embedding_function=self._embedding_fn,
            )
        except TypeError:
            # Older pyseekdb without the embedding_function kwarg.
            return self._client.get_or_create_collection(name=self.settings.collection)
        except Exception as exc:
            LOG.warning(
                "get_or_create_collection with pinned embedding failed (%s); "
                "retrying without explicit embedding function",
                exc,
            )
            return self._client.get_or_create_collection(name=self.settings.collection)

    def _warm_up_embeddings(self) -> None:
        """Embed a tiny string so the model loads/downloads at boot, not on the
        user's first query (kb-implicit-embedding-fn). Best-effort: a failure
        here must not prevent the sidecar from serving."""
        try:
            self._embedding_fn(["warm up"])
        except Exception as exc:  # pragma: no cover - environment dependent
            LOG.warning("embedding warm-up failed (will retry on first use): %s", exc)

    def _reconcile_journal(self) -> None:
        """Best-effort startup reconciliation of journal vs. vector store.

        The vector store is the source of truth. We group existing chunk
        metadata by doc_id and (a) drop journal entries whose vectors are gone,
        (b) rebuild journal entries for docs that have vectors but no journal
        record (e.g. a crash between add() and _persist_journal). This keeps
        list_documents()/health in sync with what /query can actually return
        (kb-journal-vector-drift)."""
        try:
            results = self._collection.get(include=["metadatas"])
        except Exception as exc:  # pragma: no cover - depends on backend
            LOG.warning("journal reconciliation skipped (collection.get failed): %s", exc)
            return
        ids = results.get("ids") or []
        metadatas = results.get("metadatas") or []
        # pyseekdb may nest results one level deep; flatten defensively.
        if ids and isinstance(ids[0], list):
            ids = ids[0]
            metadatas = metadatas[0] if metadatas and isinstance(metadatas[0], list) else metadatas
        counts: dict[str, int] = {}
        meta_by_doc: dict[str, dict[str, Any]] = {}
        for meta in metadatas:
            if not isinstance(meta, dict):
                continue
            doc_id = meta.get("doc_id")
            if not doc_id:
                continue
            counts[doc_id] = counts.get(doc_id, 0) + 1
            meta_by_doc.setdefault(doc_id, meta)
        changed = False
        # Drop journal entries with no surviving vectors.
        for doc_id in list(self._journal.keys()):
            if doc_id not in counts:
                LOG.warning("journal drift: doc %s has no vectors; dropping entry", doc_id)
                del self._journal[doc_id]
                changed = True
        # Rebuild journal entries for orphaned vectors.
        for doc_id, n_chunks in counts.items():
            if doc_id not in self._journal:
                meta = meta_by_doc.get(doc_id, {})
                LOG.warning("journal drift: vectors for %s have no journal entry; rebuilding", doc_id)
                self._journal[doc_id] = {
                    "id": doc_id,
                    "title": meta.get("title") or doc_id,
                    "chunks": n_chunks,
                    "added_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
                    "source": meta.get("source"),
                    "metadata": {k: v for k, v in meta.items() if k not in ("chunk_index",)},
                }
                changed = True
        if changed:
            try:
                self._persist_journal()
            except Exception as exc:  # pragma: no cover
                LOG.warning("failed to persist reconciled journal: %s", exc)

    # --- journal helpers ------------------------------------------------

    def _persist_journal(self) -> None:
        tmp = self._journal_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._journal, indent=2, sort_keys=True))
        os.replace(tmp, self._journal_path)

    # --- mutations ------------------------------------------------------

    @staticmethod
    def _coerce_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
        """Coerce metadata values to scalars the vector store + Swift client
        round-trip cleanly.

        The Swift AnyCodableValue decoder only handles String/Int/Double/Bool
        and silently turns arrays/objects into null (kb-anycodable-silent-null).
        Rather than drop structured values on the floor, JSON-encode any
        list/dict to a string so it survives the round-trip, and log when we do
        so the coercion is observable instead of silent."""
        out: dict[str, Any] = {}
        for key, value in metadata.items():
            if isinstance(value, (str, int, float, bool)) or value is None:
                out[key] = value
            else:
                LOG.info(
                    "metadata key %r has non-scalar value (%s); JSON-stringifying "
                    "for scalar-only storage",
                    key,
                    type(value).__name__,
                )
                try:
                    out[key] = json.dumps(value, ensure_ascii=False, sort_keys=True)
                except (TypeError, ValueError):
                    out[key] = str(value)
        return out

    def upsert(
        self,
        doc_id: str,
        title: str,
        text: str,
        metadata: Optional[dict[str, Any]] = None,
        chunk_chars: int = 1500,
        overlap_chars: int = 200,
    ) -> dict[str, Any]:
        metadata = self._coerce_metadata(dict(metadata or {}))
        metadata.setdefault("title", title)
        if not text.strip():
            raise ValueError("document text is empty")
        if len(text) > MAX_DOCUMENT_CHARS:
            # Guard against pathological inputs that would embed for minutes
            # while holding the writer lock (kb-no-ingest-batching).
            raise ValueError(
                f"document is too large ({len(text)} chars > {MAX_DOCUMENT_CHARS} limit)"
            )
        # Chunking is pure CPU work and the most expensive non-embedding step;
        # do it OUTSIDE the lock so concurrent queries aren't blocked by it
        # (kb-global-lock-serializes-query).
        chunks = self._split(text, chunk_chars, overlap_chars)
        if not chunks:
            raise ValueError("document produced no chunks")
        ids = [f"{doc_id}::{i:04d}" for i in range(len(chunks))]
        metadatas = [
            {**metadata, "doc_id": doc_id, "chunk_index": i}
            for i in range(len(chunks))
        ]
        with self._lock.write():
            # Remove any old chunks for this document first so re-uploads don't
            # leave stale embeddings. Failures propagate (kb-journal-vector-drift).
            self._delete_chunks_of(doc_id)
            # Batch the add so a large document embeds incrementally; the lock is
            # held for the whole upsert (one doc is atomic), but batching keeps
            # per-call memory bounded and aids progress (kb-no-ingest-batching).
            for start in range(0, len(chunks), ADD_BATCH_SIZE):
                end = start + ADD_BATCH_SIZE
                self._collection.add(
                    ids=ids[start:end],
                    documents=chunks[start:end],
                    metadatas=metadatas[start:end],
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
        with self._lock.write():
            removed = self._delete_chunks_of(doc_id)
            if doc_id in self._journal:
                del self._journal[doc_id]
                self._persist_journal()
            return removed > 0

    def reset(self) -> None:
        with self._lock.write():
            try:
                self._client.delete_collection(self.settings.collection)
            except Exception as exc:
                # Tolerate only the benign "already gone" case so reset stays
                # idempotent; any other delete failure must surface rather than
                # silently wiping the journal while vectors remain
                # (kb-journal-vector-drift). The emptiness check below is the
                # real guarantee.
                msg = str(exc).lower()
                if "exist" not in msg and "not found" not in msg:
                    raise
            self._collection = self._open_collection()
            # Verify the collection is actually empty before wiping the journal,
            # so a failed/partial delete can't leave queryable vectors with no
            # journal record (kb-journal-vector-drift).
            try:
                remaining = self._collection.get(include=["metadatas"])
                rem_ids = remaining.get("ids") or []
                if rem_ids and isinstance(rem_ids[0], list):
                    rem_ids = rem_ids[0]
            except Exception as exc:  # pragma: no cover
                LOG.warning("reset: could not verify empty collection: %s", exc)
                rem_ids = []
            if rem_ids:
                raise RuntimeError(
                    f"reset did not empty collection ({len(rem_ids)} chunks remain)"
                )
            self._journal = {}
            self._persist_journal()

    def _delete_chunks_of(self, doc_id: str) -> int:
        # `ids` are always returned; "ids" is NOT a valid `include` token and
        # raises ValueError on pyseekdb/Chroma-style backends — which would
        # leave stale chunks behind on re-upsert (duplicate retrieval hits)
        # and make delete() a no-op. Request no extra fields.
        #
        # Exceptions are NOT swallowed here (kb-journal-vector-drift): a failed
        # delete that still let the journal be overwritten is exactly how the
        # journal and vector store drift apart. Callers hold the writer lock and
        # let the failure abort the mutation so the journal is not updated.
        results = self._collection.get(where={"doc_id": doc_id})
        ids = results.get("ids") or []
        if isinstance(ids, list) and ids and isinstance(ids[0], list):
            ids = ids[0]
        if ids:
            self._collection.delete(ids=ids)
        return len(ids)

    # --- reads ----------------------------------------------------------

    def list_documents(self) -> list[dict[str, Any]]:
        # Snapshot under the read lock so we never iterate the journal while a
        # writer is reassigning it (reset) or deleting keys.
        with self._lock.read():
            snapshot = list(self._journal.values())
        return sorted(snapshot, key=lambda d: d.get("added_at", ""), reverse=True)

    def document_count(self) -> int:
        with self._lock.read():
            return len(self._journal)

    def query(self, text: str, k: int = 6) -> list[dict[str, Any]]:
        if not text.strip():
            return []
        # Read lock: concurrent queries run in parallel and only block while a
        # writer (ingest/delete/reset) holds the lock (kb-global-lock-
        # serializes-query).
        with self._lock.read():
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

    @app.middleware("http")
    async def _limit_body_size(request: Request, call_next):
        # Reject oversized payloads before they are buffered/embedded
        # (kb-no-request-size-limit). The Swift URLSession client always sends a
        # Content-Length, so the cheap header check covers the real path. For a
        # request with no/invalid Content-Length we buffer the body once (which
        # caps memory, since request.body() itself is bounded by the streamed
        # bytes we count) and reject if it exceeds the limit; downstream
        # handlers then read the already-cached body normally.
        declared = request.headers.get("content-length")
        if declared is not None:
            try:
                length = int(declared)
            except ValueError:
                return JSONResponse(
                    status_code=400, content={"detail": "invalid Content-Length"}
                )
            if length > MAX_REQUEST_BYTES:
                return JSONResponse(
                    status_code=413, content={"detail": "request body too large"}
                )
        else:
            # Unknown length: buffer and measure. Starlette caches the result on
            # the request so the route handler can read it again without loss.
            body = await request.body()
            if len(body) > MAX_REQUEST_BYTES:
                return JSONResponse(
                    status_code=413, content={"detail": "request body too large"}
                )
        return await call_next(request)

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
            "documents": kb.document_count(),
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


# Fallback poll interval for the parent-death watchdog when kqueue isn't
# available. Tightened from 2.0s to 0.5s to shrink the orphan window in which a
# dead parent's child still holds the port and a rapid relaunch could collide
# (kb-watchdog-orphan-window).
_WATCHDOG_POLL_SECONDS = 0.5


def _start_parent_watchdog() -> None:
    """Self-terminate when the launching app process dies.

    The Swift app launches this sidecar as a child process but cannot reliably
    kill it on crash, force-quit, or debugger stop — leaving an orphan that
    keeps holding the port and blocks the next launch with "address already in
    use". When the app exits, this process is re-parented to launchd (PID 1),
    so `getppid() == 1` (or a changed ppid) means "parent died".

    Primary mechanism (macOS/BSD): a kqueue EVFILT_PROC/NOTE_EXIT watch on the
    parent PID delivers an *immediate* event the instant the parent dies, so
    there is essentially no orphan window (kb-watchdog-orphan-window). If kqueue
    is unavailable, we fall back to a tightened 0.5s getppid() poll.

    `os._exit` skips atexit/uvicorn shutdown hooks deliberately — we want a
    prompt, unconditional exit that frees the port.
    """
    initial_parent = os.getppid()
    # If we were already orphaned at launch (parent == 1), there is nothing to
    # watch; rely on normal shutdown.
    if initial_parent <= 1:
        return

    def _exit_on_parent_death() -> None:
        LOG.info("parent process %s exited; sidecar shutting down", initial_parent)
        os._exit(0)

    def _watch() -> None:
        import select as _select

        # Try event-driven kqueue first for instant notification.
        if hasattr(_select, "kqueue"):
            try:
                queue = _select.kqueue()
                event = _select.kevent(
                    initial_parent,
                    filter=_select.KQ_FILTER_PROC,
                    flags=_select.KQ_EV_ADD,
                    fflags=_select.KQ_NOTE_EXIT,
                )
                # Register the watch. Block in kevent() until the parent exits.
                queue.control([event], 0, 0)
                # Guard against a race where the parent died between getppid()
                # and registration: re-check immediately.
                if os.getppid() != initial_parent:
                    _exit_on_parent_death()
                while True:
                    events = queue.control(None, 1, None)
                    for ev in events:
                        if ev.fflags & _select.KQ_NOTE_EXIT:
                            _exit_on_parent_death()
                    # Defensive: also re-check ppid in case the event was
                    # spurious / the kernel coalesced it.
                    if os.getppid() != initial_parent:
                        _exit_on_parent_death()
            except Exception as exc:  # pragma: no cover - fall back to polling
                LOG.warning("kqueue parent watch unavailable (%s); polling", exc)

        # Polling fallback (or if kqueue raised above).
        while True:
            try:
                ppid = os.getppid()
            except Exception:  # pragma: no cover
                ppid = 1
            if ppid == 1 or ppid != initial_parent:
                _exit_on_parent_death()
            time.sleep(_WATCHDOG_POLL_SECONDS)

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
