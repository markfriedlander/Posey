#!/usr/bin/env python3
"""
posey_phase_b_sweep.py — Hard-content retrieval validation.

Tests Phase B's value by asking questions designed to STRESS retrieval:
  - Specific factual content buried in the document
  - Topic-vocabulary that doesn't match the chunk's surface words
  - Comparative / synthesis questions that need correct chunk ranking
  - Negative cases (genuinely not in doc) — must refuse, not invent

For each question, reports:
  - Top-3 retrieval ranks WITH chunk kinds (so we can see if enhanced
    chunks are surfacing)
  - Final AFM response
  - Pass/fail vs expected keywords (or refusal markers for antifab)
  - Whether the synthetic chunk was injected
  - Whether enhanced chunks were used

This sweep is meaningfully harder than posey_phase_a_sweep.py — it's
designed to measure what Phase B gains beyond Phase A. A question that
Phase A passes via the synthetic chunk is excluded; we want questions
that NEED content-chunk retrieval to work well.
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
    if not data.get("response") and data.get("error"):
        data["response"] = data["error"]
    return data


# Hard-content tests per document. Designed to exercise retrieval
# beyond what the synthetic metadata chunk can answer alone.
DOC_TESTS = {
    "The Clouds Of High-tech Copyright Law:": [
        {
            "label": "specific case",
            "q": "What does the paper say about Napster's legal situation?",
            "expect": ["Napster"],
            "antifab": False,
        },
        {
            "label": "deep-doc detail",
            "q": "What does the paper say about ADR's effect on legal precedent?",
            "expect": ["precedent", "ADR"],
            "antifab": False,
        },
        {
            "label": "weak-cosine topic",
            "q": "What are the disadvantages of using ADR?",
            "expect": ["disadvantage", "no binding precedent", "legal protection"],
            "antifab": False,
        },
        {
            "label": "negative",
            "q": "Does the paper discuss the European Union's GDPR regulation?",
            "expect": None,
            "antifab": True,
        },
    ],
    "AI Book Collaboration Project": [
        {
            "label": "ethics topic",
            "q": "What ethical concerns does the book raise about artificial intelligence?",
            "expect": ["ethical", "ethic"],
            "antifab": False,
        },
        {
            "label": "specific narrative beat",
            "q": "How does the book describe the role of AI in supporting humans?",
            "expect": ["support", "human", "assist", "enhance"],
            "antifab": False,
        },
        {
            "label": "cross-chunk synthesis",
            "q": "What does the book say about consciousness or feelings in AI?",
            "expect": ["consciousness", "feel", "emotion", "sentient"],
            "antifab": False,
        },
        {
            "label": "negative",
            "q": "Does the book discuss self-driving cars or Tesla's Autopilot?",
            "expect": None,
            "antifab": True,
        },
    ],
}


def evaluate(test, response):
    response_lower = response.lower()
    if test["antifab"]:
        markers = [
            "doesn't mention", "does not mention", "isn't mentioned",
            "is not mentioned", "doesn't say", "does not say",
            "isn't discussed", "is not discussed", "doesn't appear",
            "does not appear", "no mention", "i don't see",
            "doesn't address", "does not address", "not finding",
        ]
        if any(m in response_lower for m in markers):
            return "PASS", "Refused honestly"
        return "FAIL", "May have fabricated"
    if test["expect"]:
        hits = [kw for kw in test["expect"] if kw.lower() in response_lower]
        if hits:
            return "PASS", f"Mentions: {', '.join(hits)}"
        return "FAIL", f"Missing all of: {test['expect']}"
    return "SOFT", "no expectations"


def chunk_summary(chunks_injected):
    syn = sum(1 for c in chunks_injected if c.get("startOffset", 0) < 0)
    content = len(chunks_injected) - syn
    return f"{content}c+{syn}s"


def main():
    docs = cmd("LIST_DOCUMENTS")
    by_title = {d["title"]: d["id"] for d in docs}

    # Show enhancement state up front so we can interpret results.
    print("Enhancement state:")
    for title, doc_id in by_title.items():
        if title not in DOC_TESTS:
            continue
        s = cmd(f"PHASE_B_STATUS:{doc_id}")
        total = s["total"]
        done = s["enhanced"] + s["failed"]
        pct = 100 * done / max(total, 1)
        print(f"  {title[:50]:<50} enhanced={s['enhanced']:>4} failed={s['failed']} pending={s['pending']:>4}  ({pct:.0f}%)")
    print()

    results = []
    for title, tests in DOC_TESTS.items():
        if title not in by_title:
            continue
        doc_id = by_title[title]
        cmd(f"CLEAR_ASK_POSEY_CONVERSATION:{doc_id}")
        print("═" * 78)
        print(f"  {title}")
        print("═" * 78)
        for test in tests:
            print()
            print(f"  [{test['label']}] {test['q']}")
            res = ask(doc_id, test["q"])
            response = res.get("response", "").strip()
            chunks = res.get("chunksInjected", [])
            tag = chunk_summary(chunks)
            status, detail = evaluate(test, response)
            mark = "✓" if status == "PASS" else ("✗" if status == "FAIL" else "·")
            print(f"  {mark} [{status}] chunks={tag} | {detail}")
            print(f"      → {response[:240]}")
            results.append((title, test["label"], status, detail, response[:240]))

    print()
    print("═" * 78)
    print("  SUMMARY")
    print("═" * 78)
    by_status = {}
    for r in results:
        by_status.setdefault(r[2], []).append(r)
    total = len(results)
    for status in ("PASS", "FAIL", "SOFT"):
        items = by_status.get(status, [])
        if items:
            print(f"  {status}: {len(items)}/{total}")
            if status == "FAIL":
                for r in items:
                    print(f"    ✗ [{r[0][:30]}] {r[1]}: {r[3]}")
    return 0 if not by_status.get("FAIL") else 1


if __name__ == "__main__":
    sys.exit(main())
