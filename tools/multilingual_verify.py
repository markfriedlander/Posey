#!/usr/bin/env python3
"""multilingual_verify.py — Posey M8 multilingual embedding verification harness

Drives Posey's `/ask` endpoint with known questions against a curated
multilingual corpus and prints retrieval quality metrics. Per
`NEXT.md` "Multilingual embedding improvements" — the M2 multilingual
NLEmbedding + language detection path needs verification on real
texts.

Usage:
    python3 tools/multilingual_verify.py setup           # one-time corpus download
    python3 tools/multilingual_verify.py run             # drive /ask + score

Setup downloads from Project Gutenberg (English / French / German /
Spanish / Italian) into ~/.posey-multilingual-corpus/, then imports
each into Posey via /import. Run executes a fixed set of language-
specific questions and reports retrieval quality.

The harness is intentionally a SKELETON. Mark provides:
- Curated test questions per language with expected-passage
  signatures
- Acceptance thresholds (what "good retrieval" looks like)

Until those land, the harness exercises the API plumbing and reports
basic retrieval shape — chunks_injected count, prompt_tokens,
inference_duration. Iteration on real questions builds on top of the
plumbing this script provides.

Requires the local API to be configured (see posey_test.py setup).
"""

from __future__ import annotations

import http.client
import json
import os
import sys
from typing import Any
from urllib.request import urlopen, Request


_CONFIG_FILE = os.path.join(os.path.dirname(__file__), ".posey_api_config.json")
_CORPUS_DIR = os.path.expanduser("~/.posey-multilingual-corpus")


# Project Gutenberg IDs across five languages. Small books (under
# 200 KB extracted) so import + indexing finishes in seconds.
_CORPUS = [
    # (gutenberg_id, language_code, filename, blurb)
    (1342,    "en", "Pride_and_Prejudice.txt",  "Jane Austen — Pride and Prejudice (English)"),
    (135,     "fr", "Les_Miserables_FR.txt",    "Victor Hugo — Les Misérables (French sample)"),
    (2229,    "de", "Faust_I_DE.txt",            "Goethe — Faust I (German)"),
    (2000,    "es", "Don_Quijote_ES.txt",        "Cervantes — Don Quijote (Spanish)"),
    (1012,    "it", "Divina_Commedia_IT.txt",    "Dante — Divina Commedia (Italian)"),
]


def _load_config() -> dict | None:
    if not os.path.exists(_CONFIG_FILE):
        return None
    try:
        with open(_CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def _http(method: str, path: str, body: bytes | None = None,
          extra_headers: dict | None = None, timeout: int = 600) -> tuple[int, Any]:
    cfg = _load_config()
    if not cfg:
        print("No config. Run: python3 tools/posey_test.py setup <ip> <port> <token>")
        sys.exit(1)
    conn = http.client.HTTPConnection(cfg["host"], cfg["port"], timeout=timeout)
    hdrs = {"Authorization": f"Bearer {cfg['token']}"}
    if extra_headers:
        hdrs.update(extra_headers)
    if body is not None and "Content-Length" not in hdrs:
        hdrs["Content-Length"] = str(len(body))
    conn.request(method, path, body=body, headers=hdrs)
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    try:
        return resp.status, json.loads(raw)
    except Exception:
        return resp.status, raw.decode("utf-8", errors="replace")


def setup_corpus() -> None:
    """One-time: download corpus from Project Gutenberg."""
    os.makedirs(_CORPUS_DIR, exist_ok=True)
    for gid, lang, filename, blurb in _CORPUS:
        out = os.path.join(_CORPUS_DIR, filename)
        if os.path.exists(out):
            print(f"  ✓ already have {filename}")
            continue
        url = f"https://www.gutenberg.org/cache/epub/{gid}/pg{gid}.txt"
        print(f"  ↓ {blurb}")
        try:
            req = Request(url, headers={"User-Agent": "PoseyMultilingualHarness/1.0"})
            with urlopen(req, timeout=60) as resp:
                data = resp.read()
            with open(out, "wb") as f:
                f.write(data)
            print(f"     {len(data):,} bytes → {out}")
        except Exception as e:
            print(f"     FAILED: {e}")


def import_corpus() -> list[dict]:
    """Push each corpus document into Posey via /import."""
    imported: list[dict] = []
    for gid, lang, filename, blurb in _CORPUS:
        path = os.path.join(_CORPUS_DIR, filename)
        if not os.path.exists(path):
            print(f"  ✗ missing {filename} — run setup first")
            continue
        with open(path, "rb") as f:
            data = f.read()
        status, result = _http(
            "POST", "/import", body=data,
            extra_headers={"X-Filename": filename,
                           "Content-Type": "application/octet-stream"},
            timeout=600
        )
        if status == 200 and isinstance(result, dict):
            print(f"  ✓ {filename:35s} → id {result.get('id', '?')[:8]}…  ({result.get('characterCount', 0):,} chars, lang={lang})")
            result["language"] = lang
            result["blurb"] = blurb
            imported.append(result)
        else:
            print(f"  ✗ {filename}: HTTP {status} — {result}")
    return imported


# Sample questions per language. Mark to refine these to specific
# expected-passage anchors; for v1 we just exercise the retrieval
# path and report shape.
_SAMPLE_QUESTIONS = {
    "en": "Who is Mr. Darcy?",
    "fr": "Qui est Jean Valjean?",
    "de": "Wer ist Mephistopheles?",
    "es": "¿Quién es Sancho Panza?",
    "it": "Chi è Beatrice?",
}


def run_questions(documents: list[dict]) -> None:
    print("\n=== /ask retrieval shape per language ===\n")
    for doc in documents:
        lang = doc.get("language", "?")
        question = _SAMPLE_QUESTIONS.get(lang, "What is this about?")
        body = json.dumps({
            "documentID": doc["id"],
            "question": question,
            "scope": "document"
        }).encode()
        print(f"[{lang}] '{question}' against '{doc['title']}'")
        status, response = _http(
            "POST", "/ask", body=body,
            extra_headers={"Content-Type": "application/json"},
            timeout=600
        )
        if status != 200 or not isinstance(response, dict):
            print(f"  ✗ HTTP {status}: {response}")
            continue
        chunks = response.get("chunksInjected", [])
        breakdown = response.get("breakdown", {})
        rag_tokens = breakdown.get("ragChunks", 0)
        prompt_tokens = response.get("promptTokens", 0)
        duration = response.get("inferenceDuration", 0.0)
        if "error" in response:
            print(f"  ! AFM error: {response['error'][:100]}")
        print(f"  chunks={len(chunks)}  rag_tokens={rag_tokens}  prompt_tokens={prompt_tokens}  duration={duration:.2f}s")
        if chunks:
            top = chunks[0]
            print(f"  top chunk @offset {top.get('startOffset')} relevance={top.get('relevance', 0):.3f}")
        else:
            print(f"  no chunks retrieved — multilingual embedding may need tuning for {lang}")


def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)
    verb = args[0].lower()
    if verb == "setup":
        print(f"Downloading corpus to {_CORPUS_DIR}…\n")
        setup_corpus()
        print("\nDone. Next: enable Posey API on a device, run posey_test.py setup, then:")
        print("  python3 tools/multilingual_verify.py run")
    elif verb == "run":
        print("=== Multilingual import + retrieval verification ===\n")
        print("Importing corpus into Posey…\n")
        imported = import_corpus()
        if not imported:
            print("\nNo documents imported — exiting.")
            sys.exit(1)
        run_questions(imported)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
