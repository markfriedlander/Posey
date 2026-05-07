#!/usr/bin/env python3
"""Task 3 — full conversation matrix per format.

Per CLAUDE.md / posey_task_sequence.md, each of 7 formats gets:
  factual / honest-refusal / 5+turn-chain / topic-switch /
  vague / structural / passage-scope / document-scope

This script runs ONE coherent conversation per document that
naturally traverses all 8 categories. After each /ask it captures
a screenshot of the device and records the response, intent,
chunks, and category tag. At the end, writes a per-format JSON
report and a Markdown self-assessment to /tmp/posey-task3/.

Usage:
  python3 tools/task3_matrix.py             # run all formats
  python3 tools/task3_matrix.py txt epub    # run specific formats
"""
from __future__ import annotations
import json, base64, time, sys, os, subprocess, urllib.request, urllib.error
from pathlib import Path

CONFIG_PATH = Path(__file__).parent / ".posey_api_config.json"
OUT_DIR = Path("/tmp/posey-task3")
OUT_DIR.mkdir(parents=True, exist_ok=True)

cfg = json.loads(CONFIG_PATH.read_text())
BASE = f"http://{cfg['host']}:{cfg['port']}"
TOKEN = cfg["token"]
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def http(method: str, path: str, payload: dict | None = None, timeout: int = 240):
    """Returns dict, list, or {'error': str}. /command returns raw arrays
    for LIST_DOCUMENTS — caller normalizes."""
    body = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(BASE + path, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode('utf-8', errors='replace')[:500]}"}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}


def cmd(verb: str) -> dict:
    return http("POST", "/command", {"command": verb})


def ask(doc_id: str, q: str, scope: str = "document",
        anchor_text: str | None = None, anchor_offset: int | None = None) -> dict:
    body = {"documentID": doc_id, "question": q, "scope": scope}
    if anchor_text is not None:
        body["anchorText"] = anchor_text
    if anchor_offset is not None:
        body["anchorOffset"] = anchor_offset
    return http("POST", "/ask", body)


def cooldown():
    """Standing CLAUDE.md requirement: 2.5s ± 500ms before each /ask."""
    import random
    time.sleep(2.5 + random.uniform(-0.5, 0.5))


def screenshot(path: Path):
    """Capture the device screen via the SCREENSHOT verb."""
    out = cmd("SCREENSHOT")
    b64 = out.get("base64") or (out.get("raw") or {}).get("base64")
    if not b64:
        return False
    path.write_bytes(base64.b64decode(b64))
    return True


def open_doc(doc_id: str):
    cmd(f"OPEN_DOCUMENT:{doc_id}")
    time.sleep(2.5)


def open_ask_posey(doc_id: str):
    """Open the Ask Posey sheet for this doc (document-scoped)."""
    body = {"documentID": doc_id, "scope": "document"}
    http("POST", "/open-ask-posey", body)
    time.sleep(1.5)


def clear_conversation(doc_id: str):
    cmd(f"CLEAR_ASK_POSEY_CONVERSATION:{doc_id}")


# ---- Question matrix ----
# Each format gets a list of (category_tag, question, scope, anchor_text, anchor_offset).
# The conversation flows naturally — opening question, follow-ups, topic switch, etc.
# 8 categories per format (5+turn chain counts as one category but spans 5 calls).

MATRICES = {
    "TXT": {
        "doc_query": "AI Book",   # title substring; we only want TXT
        "file_type": "txt",
        "questions": [
            ("structural", "What are the main section headings in this document?", "document", None, None),
            ("factual",    "Who are the four contributors?", "document", None, None),
            ("chain-1",    "What is Mark Friedlander's role?", "document", None, None),
            ("chain-2",    "How does that compare to ChatGPT's role?", "document", None, None),
            ("chain-3",    "What about Claude's role?", "document", None, None),
            ("chain-4",    "And Gemini's?", "document", None, None),
            ("chain-5",    "Which contributor wrote the most chapters?", "document", None, None),
            ("topic-switch", "Switching topics — what does the book say about ethics?", "document", None, None),
            ("vague",      "What is this book trying to do?", "document", None, None),
            ("honest-refusal", "What is the ISBN of this book?", "document", None, None),
            ("passage-scope", "Summarise the passage I'm reading.", "passage",
                "Posey is a personal reading companion for serious documents.", 0),
        ],
    },
    "MD": {
        "doc_query": "Hal_Working_Agenda",
        "file_type": "md",
        "questions": [
            ("structural", "What are the major section headings?", "document", None, None),
            ("factual",    "What is the highest-priority item on the agenda?", "document", None, None),
            ("chain-1",    "Why is that item the highest priority?", "document", None, None),
            ("chain-2",    "What blocks it?", "document", None, None),
            ("chain-3",    "Who is responsible for it?", "document", None, None),
            ("chain-4",    "When is it expected to land?", "document", None, None),
            ("chain-5",    "What ships immediately after that?", "document", None, None),
            ("topic-switch", "Setting the agenda aside, does the document mention any architectural decisions?", "document", None, None),
            ("vague",      "What is this document for?", "document", None, None),
            ("honest-refusal", "What's the budget for the project?", "document", None, None),
            ("passage-scope", "What is this section about?", "passage",
                "Working Agenda", 0),
        ],
    },
    "RTF": {
        "doc_query": "AI Book Collaboration",  # the RTF version
        "file_type": "rtf",
        "questions": [
            ("structural", "List the chapter titles.", "document", None, None),
            ("factual",    "What is the moderator's name?", "document", None, None),
            ("chain-1",    "What does the moderator do?", "document", None, None),
            ("chain-2",    "How is the methodology structured?", "document", None, None),
            ("chain-3",    "How many response rounds does each question go through?", "document", None, None),
            ("chain-4",    "Why two rounds rather than one?", "document", None, None),
            ("chain-5",    "What happens after the second round?", "document", None, None),
            ("topic-switch", "Switching topics — does the book talk about bias in AI?", "document", None, None),
            ("vague",      "Tell me about this book.", "document", None, None),
            ("honest-refusal", "How many copies has the book sold?", "document", None, None),
            ("passage-scope", "What is being discussed at this point?", "passage",
                "Embracing Collaboration", 0),
        ],
    },
    "DOCX": {
        "doc_query": "AI Book Collaboration",
        "file_type": "docx",
        "questions": [
            ("structural", "What's in the table of contents?", "document", None, None),
            ("factual",    "Who wrote the introduction?", "document", None, None),
            ("chain-1",    "What does the introduction argue?", "document", None, None),
            ("chain-2",    "What evidence does it offer?", "document", None, None),
            ("chain-3",    "Who is the intended audience?", "document", None, None),
            ("chain-4",    "What should they take away from it?", "document", None, None),
            ("chain-5",    "How does the introduction set up the rest of the book?", "document", None, None),
            ("topic-switch", "Setting the introduction aside, what does the book say about creativity in AI?", "document", None, None),
            ("vague",      "What is this document about?", "document", None, None),
            ("honest-refusal", "Was this book reviewed by The New York Times?", "document", None, None),
            ("passage-scope", "Summarise this passage.", "passage",
                "Mark Friedlander", 0),
        ],
    },
    "HTML": {
        "doc_query": "AI Book",   # title substring; will pick HTML version
        "file_type": "html",
        "questions": [
            ("structural", "What are the chapter titles?", "document", None, None),
            ("factual",    "Who are the contributors?", "document", None, None),
            ("chain-1",    "What does each contributor specialize in?", "document", None, None),
            ("chain-2",    "Whose contribution is most quoted?", "document", None, None),
            ("chain-3",    "Why?", "document", None, None),
            ("chain-4",    "Which chapter has the most cross-references?", "document", None, None),
            ("chain-5",    "What does that suggest about its importance?", "document", None, None),
            ("topic-switch", "Topic switch — what does the book say about regulation of AI?", "document", None, None),
            ("vague",      "What is the goal of this book?", "document", None, None),
            ("honest-refusal", "What awards has this book won?", "document", None, None),
            ("passage-scope", "What is this section saying?", "passage",
                "Having long been fascinated", 0),
        ],
    },
    "EPUB": {
        "doc_query": "Illuminatus",
        "file_type": "epub",
        "questions": [
            ("structural", "What are the major section headings?", "document", None, None),
            ("factual",    "Who is Hagbard Celine?", "document", None, None),
            ("chain-1",    "What ship does Hagbard captain?", "document", None, None),
            ("chain-2",    "What does the ship's name mean?", "document", None, None),
            ("chain-3",    "Who else is on the ship?", "document", None, None),
            ("chain-4",    "What is the crew's mission?", "document", None, None),
            ("chain-5",    "Who are they fighting against?", "document", None, None),
            ("topic-switch", "Topic switch — what does the book say about discordianism?", "document", None, None),
            ("vague",      "What is the book about?", "document", None, None),
            ("honest-refusal", "What was the publisher's first print run?", "document", None, None),
            ("passage-scope", "What is happening in this passage?", "passage",
                "Hagbard Celine", 0),
        ],
    },
    "PDF": {
        "doc_query": "Clouds Of High-tech Copyright",
        "file_type": "pdf",
        "questions": [
            ("structural", "What are the main sections of the paper?", "document", None, None),
            ("factual",    "What course was this paper written for?", "document", None, None),
            ("chain-1",    "What is the central thesis?", "document", None, None),
            ("chain-2",    "What evidence supports it?", "document", None, None),
            ("chain-3",    "What objections does the author anticipate?", "document", None, None),
            ("chain-4",    "How are those objections addressed?", "document", None, None),
            ("chain-5",    "What is the conclusion?", "document", None, None),
            ("topic-switch", "Topic switch — does the paper discuss the DMCA?", "document", None, None),
            ("vague",      "What is this paper about?", "document", None, None),
            ("honest-refusal", "Who is the author's spouse?", "document", None, None),
            ("passage-scope", "What is the author saying here?", "passage",
                "Alternative Dispute Resolution", 0),
        ],
    },
}


def find_doc_id(query: str, file_type: str) -> str | None:
    listing = cmd("LIST_DOCUMENTS")
    # /command returns the array directly for LIST_DOCUMENTS;
    # other callers may wrap it in {"raw": [...]}.
    if isinstance(listing, list):
        docs = listing
    elif isinstance(listing, dict):
        docs = listing.get("raw") or []
    else:
        docs = []
    for d in docs:
        if file_type.lower() == (d.get("fileType") or "").lower() and \
           query.lower() in (d.get("title") or "").lower():
            return d.get("id")
    return None


def run_format(format_name: str, spec: dict, log_lines: list[str]) -> dict:
    out_subdir = OUT_DIR / format_name
    out_subdir.mkdir(exist_ok=True)
    log_lines.append(f"\n## {format_name}\n")

    doc_id = find_doc_id(spec["doc_query"], spec["file_type"])
    if not doc_id:
        msg = f"  [SKIP] no {spec['file_type']} doc matching '{spec['doc_query']}' on device"
        print(msg); log_lines.append(msg)
        return {"format": format_name, "skipped": True}

    log_lines.append(f"Doc: {doc_id} ({spec['file_type']})\n")
    print(f"\n=== {format_name} — {doc_id} ===")

    # Open doc + clear conversation + open Ask Posey sheet so screenshots
    # capture the live conversation thread.
    open_doc(doc_id)
    clear_conversation(doc_id)
    time.sleep(1)
    open_ask_posey(doc_id)
    time.sleep(2)

    results = []
    for i, (tag, question, scope, anchor_text, anchor_offset) in enumerate(spec["questions"], start=1):
        cooldown()
        print(f"  Q{i:02d} [{tag}] scope={scope} : {question[:60]}")
        log_lines.append(f"### Q{i:02d} — {tag} ({scope})\n")
        log_lines.append(f"**Q:** {question}\n")

        r = ask(doc_id, question, scope=scope,
                anchor_text=anchor_text, anchor_offset=anchor_offset)
        resp = r.get("response") or ""
        err  = r.get("error") or ""
        intent = r.get("intent") or ""
        chunks = len(r.get("chunksInjected") or [])

        log_lines.append(f"**A:** {resp[:600]}\n")
        if err:
            log_lines.append(f"**ERROR:** {err[:240]}\n")
        log_lines.append(f"_intent: {intent}, chunks injected: {chunks}_\n")

        # Screenshot AFTER the response lands.
        time.sleep(1)
        png = out_subdir / f"q{i:02d}_{tag}.png"
        ok = screenshot(png)
        if not ok:
            log_lines.append("_(screenshot failed)_\n")

        results.append({
            "n": i, "tag": tag, "scope": scope, "question": question,
            "response": resp, "error": err, "intent": intent,
            "chunks": chunks, "screenshot": str(png),
        })
        log_lines.append("")

    return {"format": format_name, "doc": doc_id, "results": results}


def main():
    target_formats = [a.upper() for a in sys.argv[1:]] or list(MATRICES.keys())
    log_lines = ["# Task 3 — Conversation Matrix Report\n",
                 f"_Run: {time.strftime('%Y-%m-%d %H:%M:%S')}_\n",
                 f"_Device: Mark's iPhone via local API_\n"]
    summary = {}
    for fmt in target_formats:
        if fmt not in MATRICES:
            print(f"  unknown format: {fmt}")
            continue
        try:
            summary[fmt] = run_format(fmt, MATRICES[fmt], log_lines)
        except Exception as e:
            print(f"  [{fmt}] FATAL: {e}")
            log_lines.append(f"  [{fmt}] FATAL: {e}\n")

    # Save report
    md = OUT_DIR / "report.md"
    js = OUT_DIR / "report.json"
    md.write_text("\n".join(log_lines))
    js.write_text(json.dumps(summary, indent=2))
    print(f"\nWrote report to {md}")
    print(f"Wrote JSON to {js}")


if __name__ == "__main__":
    main()
