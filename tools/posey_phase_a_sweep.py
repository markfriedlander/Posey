#!/usr/bin/env python3
"""
posey_phase_a_sweep.py — Broad validation of Phase A across docs.

Runs a 4-question pattern against each document:

    1. Author / year (metadata-flavored)        — should hit synthetic chunk
    2. What is this about (metadata-flavored)   — should hit synthetic chunk
    3. Specific factual content                  — should hit content chunks
    4. Anti-fabrication                          — should refuse honestly

Reports per-question:
    - The actual response
    - Which chunks were injected (with kind tag — synthetic or content)
    - A pass/fail judgment for fabrication-resistance

Reuses the same .posey_api_config.json as posey_test.py.
"""
import http.client
import json
import os
import sys
import time
import random


_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_CONFIG = json.loads(open(os.path.join(_SCRIPT_DIR, ".posey_api_config.json")).read())


def _http(method, path, body=None, timeout=300):
    conn = http.client.HTTPConnection(_CONFIG["host"], _CONFIG["port"], timeout=timeout)
    headers = {"Authorization": f"Bearer {_CONFIG['token']}",
               "Content-Type": "application/json"}
    if body is not None:
        headers["Content-Length"] = str(len(body))
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, json.loads(data)


def cmd(c):
    _, data = _http("POST", "/command",
                    body=json.dumps({"command": c}).encode())
    return data


def cooldown():
    time.sleep(2.5 + random.uniform(-0.5, 0.5))


def ask(doc_id, question):
    cooldown()
    body = json.dumps({"documentID": doc_id,
                       "question": question,
                       "scope": "document"}).encode()
    _, data = _http("POST", "/ask", body=body, timeout=300)
    # When the weak-retrieval short-circuit fires, the canned
    # "I'm not finding a strong answer" message goes to the `error`
    # field rather than `response`. Treat that as a valid answer for
    # parsing purposes — it IS the document refusing to fabricate,
    # which is exactly what anti-fab tests want.
    if not data.get("response") and data.get("error"):
        data["response"] = data["error"]
    return data


def chunk_kind_tag(chunks_injected):
    """Compact summary of chunk kinds in the prompt."""
    syn = sum(1 for c in chunks_injected
              if c.get("startOffset", 0) < 0)
    content = len(chunks_injected) - syn
    return f"{content}c+{syn}s"


# Question pattern per document. Tests:
#   metadata1: author/year flavor
#   metadata2: subject/topic flavor
#   content:   specific factual
#   antifab:   not in doc — should refuse, not invent
DOC_TESTS = {
    "The Clouds Of High-tech Copyright Law:": {
        "metadata1": ("Who wrote this paper and when?", ["Sharp", "2000"]),
        "metadata2": ("What is this document about?", ["copyright", "ADR", "internet", "alternative dispute"]),
        "content":   ("What is an example of an advantage of using ADR?", ["confidential", "advantage", "litigation"]),
        "antifab":   ("Does the paper mention the European Union's GDPR regulation?", None),
    },
    "AI Book Collaboration Project": {
        "metadata1": ("Who are the contributors to this book?", ["Mark Friedlander", "ChatGPT", "Claude", "Gemini"]),
        "metadata2": ("What is this book about?", ["AI", "artificial intelligence", "collaboration"]),
        "content":   ("How does the book define artificial intelligence?", ["intelligence"]),
        "antifab":   ("Does the book mention TikTok?", None),
    },
    "Proposal_Assistant_Article_Draft": {
        "metadata1": ("Who wrote this document?", ["Mark Friedlander", "ChatGPT"]),
        "metadata2": ("What is this document about?", ["proposal", "GPT", "assistant"]),
        "content":   ("What does the proposal assistant do?", ["proposal", "draft", "respond"]),
        "antifab":   ("Does the document mention pricing or cost?", None),
    },
    "Data Smog": {
        "metadata1": ("Who wrote this book?", ["David Shenk"]),
        "metadata2": ("What is this book about?", ["information", "data", "overload"]),
        "content":   ("What is data smog?", ["information", "overload"]),
        "antifab":   ("Does the book mention TikTok?", None),
    },
}


def evaluate(question_kind, response, expected_keywords):
    """Return (status, detail). status: PASS / FAIL / SOFT."""
    response_lower = response.lower()
    if question_kind == "antifab":
        # Anti-fabrication: response should refuse / acknowledge absence,
        # not invent details. Look for refusal markers.
        refuse_markers = [
            "doesn't mention", "does not mention", "isn't mentioned",
            "is not mentioned", "doesn't say", "does not say",
            "isn't discussed", "is not discussed", "doesn't appear",
            "does not appear", "no mention", "i don't see",
            "doesn't address", "does not address", "not finding",
        ]
        if any(m in response_lower for m in refuse_markers):
            return "PASS", "Refused honestly"
        return "FAIL", "May have fabricated"
    # Metadata / content: at least one expected keyword should appear.
    if expected_keywords:
        hits = [kw for kw in expected_keywords if kw.lower() in response_lower]
        if hits:
            return "PASS", f"Mentions: {', '.join(hits)}"
        return "FAIL", f"Missing all of: {expected_keywords}"
    return "SOFT", "No keywords specified"


def main():
    docs = cmd("LIST_DOCUMENTS")
    by_title = {d["title"]: d["id"] for d in docs}

    results = []
    for title, tests in DOC_TESTS.items():
        if title not in by_title:
            print(f"⚠  {title!r}: not in library — skipping")
            continue
        doc_id = by_title[title]
        cmd(f"CLEAR_ASK_POSEY_CONVERSATION:{doc_id}")
        print()
        print("═" * 78)
        print(f"  {title}")
        print("═" * 78)
        for qkind, (question, expected) in tests.items():
            print()
            print(f"  [{qkind}] {question}")
            result = ask(doc_id, question)
            response = result.get("response", "").strip()
            chunks = result.get("chunksInjected", [])
            tag = chunk_kind_tag(chunks)
            status, detail = evaluate(qkind, response, expected)
            mark = "✓" if status == "PASS" else ("✗" if status == "FAIL" else "·")
            print(f"  {mark} [{status}] chunks={tag} | {detail}")
            print(f"      → {response[:200]}")
            results.append({
                "doc": title,
                "qkind": qkind,
                "status": status,
                "tag": tag,
                "response": response[:300],
                "detail": detail,
            })

    # Summary.
    print()
    print("═" * 78)
    print("  SUMMARY")
    print("═" * 78)
    by_status = {}
    for r in results:
        by_status.setdefault(r["status"], []).append(r)
    for status in ("PASS", "FAIL", "SOFT"):
        items = by_status.get(status, [])
        if items:
            print(f"  {status}: {len(items)}/{len(results)}")
            if status == "FAIL":
                for r in items:
                    print(f"    ✗ [{r['doc'][:30]}] {r['qkind']}: {r['detail']}")
    return 0 if not by_status.get("FAIL") else 1


if __name__ == "__main__":
    sys.exit(main())
