"""Rebuildable local FTS5 + CPU embeddings. Never downloads at request time."""
import json
import os
import re
import sqlite3
import threading
from collections import OrderedDict
from contextlib import contextmanager
from pathlib import Path
from services.paths_service import RUNTIME_DIR
from services.logging_service import get_logger

MODEL = "BAAI/bge-small-zh-v1.5"
_model = None
_model_lock = threading.RLock()
_queries = OrderedDict()
_warned = False


def encoder():
    global _model
    with _model_lock:
        if _model is None:
            from fastembed import TextEmbedding
            _model = TextEmbedding(MODEL, cache_dir=os.environ.get("ZEROCHAT_MODEL_DIR", str(RUNTIME_DIR / "models")),
                                   threads=4, providers=["CPUExecutionProvider"], local_files_only=True)
        return _model


def vectors(texts):
    global _warned
    if os.environ.get("ZEROCHAT_MEMORY_FTS_ONLY") == "1":
        return [None] * len(texts)
    try:
        with _model_lock:
            return [v.astype("float32").tobytes() for v in encoder().embed(texts, batch_size=32)]
    except (ValueError, OSError, ImportError, RuntimeError):
        if not _warned:
            get_logger("memory").warning("", extra={"event": "local_vector_unavailable"})
            _warned = True
        return [None] * len(texts)


def tokens(text):
    # FTS unicode61 doesn't segment Chinese: explicit character bigrams do.
    words = re.findall(r"[a-z0-9_]+|[\u3400-\u9fff]", text.lower())
    return " ".join(words + [a + b for a, b in zip(words, words[1:]) if len(a) == len(b) == 1])


@contextmanager
def database(root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(root / "memory-index.sqlite3", timeout=30)
    db.row_factory = sqlite3.Row
    try:
        with db:
            db.executescript("""
              CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY, payload TEXT, vector BLOB, model TEXT);
              CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, terms);
              CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT);
            """)
            yield db
    finally:
        db.close()


def project(root, entries):
    if not entries:
        return
    with database(root) as db:
        changed = []
        for entry in entries:
            old = db.execute("SELECT payload,vector FROM entries WHERE id=?", (entry["id"],)).fetchone()
            payload = json.dumps(entry, ensure_ascii=False, sort_keys=True)
            if old is None or old["payload"] != payload or (not entry.get("deleted") and old["vector"] is None and os.environ.get("ZEROCHAT_MEMORY_FTS_ONLY") != "1"):
                changed.append((entry, payload, old))
        need = [e[0]["content"] for e in changed if not e[0].get("deleted") and (e[2] is None or json.loads(e[2]["payload"])["content"] != e[0]["content"] or e[2]["vector"] is None)]
        encoded = iter(vectors(need))
        for entry, payload, old in changed:
            db.execute("DELETE FROM search WHERE id=?", (entry["id"],))
            vector = None
            if not entry.get("deleted"):
                vector = next(encoded) if old is None or json.loads(old["payload"])["content"] != entry["content"] or old["vector"] is None else old["vector"]
                db.execute("INSERT INTO search VALUES (?,?)", (entry["id"], tokens(entry["content"])))
            db.execute("INSERT OR REPLACE INTO entries VALUES (?,?,?,?)", (entry["id"], payload, vector, MODEL))


def ranked(root, allowed, query, limit):
    """Callers pass only authorized IDs. Neither vectors nor text bypass ACLs."""
    try:
        import numpy as np
    except ImportError:
        np = None
    if not allowed:
        return [], False
    with database(root) as db:
        lexical = {}
        parts = list(dict.fromkeys(tokens(query).split()))[:80]
        if parts:
            # Names and operators are never interpolated from untrusted text.
            match = " OR ".join('"' + p.replace('"', '""') + '"' for p in parts)
            for row in db.execute("SELECT id,bm25(search) AS score FROM search WHERE search MATCH ? ORDER BY score", (match,)):
                if row["id"] in allowed:
                    lexical[row["id"]] = len(lexical) + 1
        key = (MODEL, query[:2000])
        q = _queries.get(key)
        if q is None and query.strip() and np is not None:
            value = vectors([query[:2000]])[0]
            q = np.frombuffer(value, dtype="float32") if value is not None else None
            if q is not None:
                _queries[key] = q
                if len(_queries) > 128:
                    _queries.popitem(last=False)
        rows = []
        # Chunked IN prevents both SQLite parameter overflow and private-vector scans.
        ids = list(allowed)
        for start in range(0, len(ids), 500):
            batch = ids[start:start + 500]
            rows.extend(db.execute("SELECT * FROM entries WHERE id IN (" + ",".join("?" for _ in batch) + ")", batch).fetchall())
        dense = {}
        if q is not None:
            valid = [(r["id"], np.frombuffer(r["vector"], dtype="float32")) for r in rows if r["vector"] is not None]
            if valid:
                matrix = np.stack([v for _, v in valid])
                scores = matrix @ q / (np.linalg.norm(matrix, axis=1) * np.linalg.norm(q) + 1e-8)
                dense = {valid[i][0]: (rank + 1, float(scores[i])) for rank, i in enumerate(np.argsort(-scores)) if scores[i] >= 0.40}
        result = []
        for row in rows:
            entry = json.loads(row["payload"])
            identity = entry["id"]
            if query.strip() and identity not in lexical and identity not in dense:
                continue
            score = (1 / (60 + lexical[identity]) if identity in lexical else 0) + (1 / (60 + dense[identity][0]) if identity in dense else 0)
            # Old episodes fade; pinned/core facts retain their relevance.
            if entry["category"] in ("episodic", "short_term"):
                from datetime import datetime, timezone
                age = max(0, (datetime.now(timezone.utc) - datetime.fromisoformat(entry["updated_at"])).total_seconds() / 86400)
                score *= max(0.15, 1 / (1 + age / 90))
            result.append({**entry, "score": score, "vector_score": dense.get(identity, (0, None))[1]})
        result.sort(key=lambda x: (x["score"], x["updated_at"]), reverse=True)
        return result[:limit], q is not None
