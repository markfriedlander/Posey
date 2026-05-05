#!/usr/bin/env python3
"""
posey_rag_debug.py — End-to-end RAG pipeline diagnostic
========================================================

Generalized RAG diagnostic harness. Answers "why did Posey give that
answer?" by tracing a question through the full retrieval pipeline:

    question
      → embedding (cosine + lexical + entity-boost components)
      → top-K ranked chunks
      → which chunks made it into the AFM prompt
      → what AFM said back
      → cross-check vs ground-truth (was the answer literally findable
        in the document; did retrieval find that chunk?)

Reuses the same .posey_api_config.json as posey_test.py — run setup
through that tool first.

USAGE
-----
  # Trace retrieval only (fast, no AFM call):
  python3 tools/posey_rag_debug.py <doc-id> "What is an example of an advantage of using ADR?"

  # With ground-truth probe — prove the answer exists in the doc:
  python3 tools/posey_rag_debug.py <doc-id> "What advantage does ADR have?" \
      --ground-truth "less time-consuming"

  # Multiple ground-truth probes (any one match counts as "found"):
  python3 tools/posey_rag_debug.py <doc-id> "..." \
      --ground-truth "less time-consuming" \
      --ground-truth "lower cost"

  # Include the AFM call to see what Posey actually answers, with
  # cross-check against retrieved chunks:
  python3 tools/posey_rag_debug.py <doc-id> "..." --ground-truth "..." --with-ask

  # Wider top-K window (default 10):
  python3 tools/posey_rag_debug.py <doc-id> "..." --top-k 20

  # Quick document lookup if you don't have the ID:
  python3 tools/posey_rag_debug.py --list-docs

INTERPRETING THE OUTPUT
-----------------------
The diagnostic produces three sections + a verdict:

  TOP-K RETRIEVAL    Ranked list with cosine / lexical / entity columns
                     visible separately. Tells you WHICH signal moved a
                     chunk up the ranking.
  GROUND TRUTH       For each --ground-truth keyword: every offset where
                     it appears, which chunk(s) own those offsets, and
                     where those chunks landed in retrieval.
  AFM RESPONSE       (--with-ask) The actual prompt + answer, with each
                     injected chunk's retrieval rank annotated.

The VERDICT classifies the failure mode (or success):

  ✓ FOUND            Ground truth chunk was retrieved AND made the
                     budget; AFM had the evidence.
  ✗ CHUNKING MISS    Ground truth keyword IS in the document but NOT in
                     any retrieved chunk's top-K. Suggests chunking
                     boundaries split the answer or the embedder didn't
                     surface it.
  ✗ BUDGET MISS      Ground truth chunk is in top-K but ranked too low
                     to be injected. Suggests scoring tuning or top-K
                     widening.
  ✗ PROMPT/MODEL     Ground truth chunk WAS injected but AFM still
                     answered incorrectly. Suggests prompt-side or
                     AFM-side fix, NOT retrieval.
  ?  UNVERIFIABLE    No --ground-truth supplied; can't classify the
                     failure mode. Add ground-truth keyword(s).
"""

import argparse
import http.client
import json
import os
import sys

# ─── Config (shared with posey_test.py) ──────────────────────────────────────

_SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
_CONFIG_FILE = os.path.join(_SCRIPT_DIR, ".posey_api_config.json")


def _load_config() -> dict:
    if not os.path.exists(_CONFIG_FILE):
        sys.exit(
            "No API config. Run:\n"
            "  python3 tools/posey_test.py setup <ip> 8765 <token>\n"
            "first (the IP and token are printed to the device console "
            "when the antenna is enabled)."
        )
    with open(_CONFIG_FILE) as f:
        return json.load(f)


# ─── HTTP transport ──────────────────────────────────────────────────────────

def _http(cfg: dict, method: str, path: str, body: bytes | None = None,
          extra_headers: dict | None = None, timeout: int = 300):
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


def _command(cfg: dict, cmd: str):
    """Returns the parsed JSON response. Can be a dict or a list — callers
    check the type. HTTP-level failures come back as a dict with 'error'."""
    body = json.dumps({"command": cmd}).encode()
    status, data = _http(cfg, "POST", "/command", body=body,
                         extra_headers={"Content-Type": "application/json"})
    if status != 200:
        return {"error": f"HTTP {status}", "detail": data}
    return data


def _ask(cfg: dict, doc_id: str, question: str) -> dict:
    body = json.dumps({"documentID": doc_id, "question": question,
                       "scope": "document"}).encode()
    status, data = _http(cfg, "POST", "/ask", body=body,
                         extra_headers={"Content-Type": "application/json"},
                         timeout=600)
    if status != 200 or not isinstance(data, dict):
        return {"error": f"HTTP {status}", "detail": data}
    return data


# ─── Pretty-print helpers ────────────────────────────────────────────────────

def _truncate(s: str, n: int) -> str:
    s = s.replace("\n", " ").replace("\r", " ")
    return s if len(s) <= n else s[: n - 1] + "…"


def _print_header(text: str, char: str = "═") -> None:
    print()
    print(char * 78)
    print(text)
    print(char * 78)


def _print_topk(diag: dict, top_k: int) -> None:
    _print_header(f"TOP-{top_k} RETRIEVAL  ({diag.get('embeddingProvider', '?')}, "
                  f"{diag.get('totalChunks', '?')} chunks total)")
    print(f"  Query: {diag.get('query')!r}")
    print(f"  NOTE: production also force-prepends front-matter chunks 0-3 ")
    print(f"        (or chunk 0 only for long docs) for unanchored questions.")
    print(f"        Those aren't shown here unless they ranked organically.")
    print()
    print(f"  {'#':>2}  {'chnk':>4}  {'comb':>5}  {'cos':>5}  {'lex':>5}  "
          f"{'ent':>3}  {'offset':>7}  text")
    print(f"  {'-'*2}  {'-'*4}  {'-'*5}  {'-'*5}  {'-'*5}  "
          f"{'-'*3}  {'-'*7}  {'-'*48}")
    for m in diag.get("topMatches", []):
        ent = "★" if m.get("entityBoosted") else " "
        print(f"  {m['rank']:>2}  {m['chunkIndex']:>4}  "
              f"{m['combined']:>5.3f}  {m['cosine']:>5.3f}  {m['lexical']:>5.3f}  "
              f"{ent:>3}  {m['startOffset']:>7}  {_truncate(m['text'], 48)}")


def _print_ground_truth(probes: list[tuple[str, dict]],
                        diag_top_indices: list[int]) -> None:
    _print_header("GROUND TRUTH PROBE")
    if not probes:
        print("  (no --ground-truth supplied; verdict will be unverifiable)")
        return
    # Front-matter prepend is part of the production /ask path. Treat
    # chunks 0-3 (short doc) as effectively retrieved when scoring the
    # verdict so unanchored questions don't get a false "chunking miss"
    # when the answer literally lives in the TOC/byline region. The
    # cutoff-by-length is documented in retrieveRAGChunks (long-doc
    # threshold ≥ 200K chars uses chunk 0 only). We don't have the
    # document length here in this function — for printing purposes
    # we annotate the top-K membership as observed.
    diag_set = set(diag_top_indices)
    for keyword, probe in probes:
        match_count = probe.get("matchCount", 0)
        if match_count == 0:
            print(f"  ✗ {keyword!r}: NOT FOUND in document plainText "
                  "(re-check spelling, casing isn't an issue — search is "
                  "case-insensitive — but the substring must be exact)")
            continue
        print(f"  ✓ {keyword!r}: {match_count} match(es) in document")
        # Show first 5 matches.
        for m in probe.get("matches", [])[:5]:
            owners = m.get("chunks", [])
            if not owners:
                owner_str = "(no chunk owns this offset)"
            else:
                ranked = []
                for o in owners:
                    idx = o["chunkIndex"]
                    in_topk = "in top-K" if idx in diag_set else "NOT in top-K"
                    ranked.append(f"chunk {idx} [{in_topk}]")
                owner_str = ", ".join(ranked)
            excerpt = _truncate(m.get("excerpt", ""), 100)
            print(f"      offset {m['offset']:>7}: …{excerpt}…")
            print(f"                       owned by: {owner_str}")
        if len(probe.get("matches", [])) > 5:
            print(f"      … and {len(probe['matches']) - 5} more match(es)")


def _print_afm(ask: dict, diag_top_indices: list[int]) -> None:
    _print_header("AFM RESPONSE")
    if "error" in ask:
        print(f"  ERROR: {ask.get('error')}: {ask.get('detail')}")
        return
    print(f"  Intent:           {ask.get('intent', '?')}")
    print(f"  Prompt tokens:    {ask.get('promptTokens', '?')}")
    print(f"  Inference (s):    {ask.get('inferenceDuration', '?')}")
    breakdown = ask.get("breakdown", {})
    if breakdown:
        print(f"  Token breakdown:  system={breakdown.get('system')} "
              f"anchor={breakdown.get('anchor')} "
              f"surrounding={breakdown.get('surrounding')} "
              f"summary={breakdown.get('conversationSummary')} "
              f"stm={breakdown.get('stm')} "
              f"rag={breakdown.get('ragChunks')} "
              f"q={breakdown.get('userQuestion')}")
    dropped = ask.get("droppedSections", [])
    if dropped:
        print(f"  Dropped sections: {len(dropped)}")
        for d in dropped:
            print(f"      {d.get('section')} #{d.get('identifier')}: {d.get('reason')}")
    chunks = ask.get("chunksInjected", [])
    if chunks:
        diag_set = set(diag_top_indices)
        print(f"  Chunks injected:  {len(chunks)}")
        for c in chunks:
            idx = c.get("chunkID")
            mark = "✓" if idx in diag_set else "?"
            print(f"      {mark} chunk {idx} @ offset {c.get('startOffset')} "
                  f"relevance={c.get('relevance', 0):.3f}")
    print()
    print("  Response:")
    response = ask.get("response", "").strip()
    if response:
        for line in response.splitlines():
            print(f"      {line}")
    else:
        print("      (empty)")


def _verdict(probes: list[tuple[str, dict]],
             diag: dict,
             top_k: int,
             ask: dict | None,
             doc_length: int) -> str:
    """Classify the outcome. See module docstring."""
    if not probes:
        return "?  UNVERIFIABLE — no --ground-truth supplied; cannot classify."

    # Production retrieveRAGChunks force-prepends front matter for
    # unanchored questions: chunks 0-3 for short docs, chunk 0 only
    # for long docs (≥ 200K chars). These count as effectively
    # retrieved even when they don't rank organically.
    long_doc_threshold = 200_000
    if doc_length >= long_doc_threshold:
        forced = {0}
    else:
        forced = {0, 1, 2, 3}
    top_indices = {m["chunkIndex"] for m in diag.get("topMatches", [])} | forced
    # Collect every chunk-index that owns any ground-truth match.
    gt_chunks: set[int] = set()
    gt_anywhere = False
    for _kw, probe in probes:
        if probe.get("matchCount", 0) > 0:
            gt_anywhere = True
            for m in probe.get("matches", []):
                for o in m.get("chunks", []):
                    gt_chunks.add(o["chunkIndex"])

    if not gt_anywhere:
        return ("✗ KEYWORD ABSENT — none of the ground-truth keywords are in the "
                "document plainText. Re-check spelling.")

    gt_in_topk = gt_chunks & top_indices
    if not gt_in_topk:
        return ("✗ CHUNKING MISS — ground-truth keyword(s) found in document, but "
                f"NO chunk containing them ranked in top-{top_k}. Likely chunking "
                "boundaries split the answer, or the embedder failed to surface it. "
                "Investigate: chunk size/overlap, whether the answer crosses a chunk "
                "boundary, embedding quality.")

    if not ask or "error" in (ask or {}):
        # Ground truth in retrieval; can't verify AFM behavior without --with-ask.
        return (f"✓ RETRIEVAL OK — ground-truth chunk(s) {sorted(gt_in_topk)} in "
                f"top-{top_k}. Run with --with-ask to verify AFM uses the evidence "
                "correctly.")

    injected_indices = {c.get("chunkID") for c in ask.get("chunksInjected", [])
                        if c.get("chunkID") is not None}
    gt_injected = gt_chunks & injected_indices
    if not gt_injected:
        return (f"✗ BUDGET MISS — ground-truth chunk(s) {sorted(gt_in_topk)} "
                "ranked in top-K but did NOT make it into the AFM prompt "
                "(dropped by token budget). Investigate: RAG token budget, chunk "
                "size, or rank-cutoff in retrieveRAGChunks.")

    return (f"✓→? PROMPT/MODEL — ground-truth chunk(s) {sorted(gt_injected)} were "
            "injected into the AFM prompt. If the response is wrong, the failure is "
            "downstream of retrieval (prompt construction, AFM behavior, or "
            "presentation). Read the response above and judge.")


# ─── Main ────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="End-to-end RAG pipeline diagnostic for Ask Posey.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See module docstring for output interpretation guide.")
    parser.add_argument("doc_id", nargs="?", help="Document UUID (use --list-docs to find)")
    parser.add_argument("question", nargs="?", help="The question to trace")
    parser.add_argument("--ground-truth", "-g", action="append", default=[],
                        metavar="KEYWORD",
                        help="Substring expected in the answering passage. "
                             "Repeat the flag for multiple probes (any match "
                             "counts as found).")
    parser.add_argument("--top-k", "-k", type=int, default=10,
                        help="Number of top retrieval results to show (default: 10).")
    parser.add_argument("--with-ask", action="store_true",
                        help="Also run the full AFM /ask call and report the answer.")
    parser.add_argument("--list-docs", action="store_true",
                        help="List documents and exit (helper for finding doc IDs).")
    args = parser.parse_args()

    cfg = _load_config()

    if args.list_docs:
        docs = _command(cfg, "LIST_DOCUMENTS")
        if isinstance(docs, list):
            for d in docs:
                print(f"  {d['id']}  {d['fileType']:>4}  "
                      f"{d['characterCount']:>8} chars  {d['title']}")
        else:
            print(json.dumps(docs, indent=2))
        return 0

    if not args.doc_id or not args.question:
        parser.print_help()
        return 2

    # 1. Validate document.
    docs = _command(cfg, "LIST_DOCUMENTS")
    if not isinstance(docs, list):
        print(f"LIST_DOCUMENTS failed: {docs}")
        return 1
    doc = next((d for d in docs if d["id"] == args.doc_id), None)
    if not doc:
        print(f"Document {args.doc_id} not found. Use --list-docs to see available.")
        return 1

    print()
    print(f"Document: {doc['title']}")
    print(f"  ID: {doc['id']}  type: {doc['fileType']}  length: {doc['characterCount']} chars")

    # 2. Run retrieval trace.
    # Don't pass --top-k as the third colon-separated field if the
    # query itself contains colons; the local-API verb falls back to
    # default 10 in that case. Keep things simple: include topK only
    # when the query is colon-free.
    if ":" in args.question:
        cmd = f"RAG_TRACE:{args.doc_id}:{args.question}"
    else:
        cmd = f"RAG_TRACE:{args.doc_id}:{args.question}:{args.top_k}"
    diag = _command(cfg, cmd)
    if not isinstance(diag, dict) or "error" in diag:
        print(f"RAG_TRACE failed: {diag}")
        return 1
    _print_topk(diag, args.top_k)
    diag_indices = [m["chunkIndex"] for m in diag.get("topMatches", [])]

    # 3. Ground-truth probes.
    probes: list[tuple[str, dict]] = []
    for kw in args.ground_truth:
        probe = _command(cfg, f"RAG_FIND:{args.doc_id}:{kw}")
        if not isinstance(probe, dict) or "error" in probe:
            print(f"RAG_FIND for {kw!r} failed: {probe}")
            continue
        probes.append((kw, probe))
    _print_ground_truth(probes, diag_indices)

    # 4. Optional AFM call.
    ask: dict | None = None
    if args.with_ask:
        ask = _ask(cfg, args.doc_id, args.question)
        _print_afm(ask, diag_indices)

    # 5. Verdict.
    _print_header("VERDICT", char="─")
    print(f"  {_verdict(probes, diag, args.top_k, ask, doc['characterCount'])}")
    print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
