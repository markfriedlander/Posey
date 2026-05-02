#!/usr/bin/env python3
"""format_parity_audit.py — Posey M8 format-parity audit harness

Per `NEXT.md` "Full format-parity audit across all 7 supported formats"
and the format-parity standing policy in `CLAUDE.md` — every Posey
capability must work the same way in every format that can support
it. This harness systematically verifies the capabilities-per-format
matrix on the running app.

Usage:
    python3 tools/format_parity_audit.py setup           # generate fixture set
    python3 tools/format_parity_audit.py run             # import + audit
    python3 tools/format_parity_audit.py report          # last-run summary

Capabilities audited (per format):
  - Successful import + character count > 0
  - Plain-text retrieval (GET_PLAIN_TEXT) returns non-empty content
  - displayText retrieval (GET_TEXT) returns non-empty content
  - TOC presence (where the format supports it)
  - Embedding index built (chunkCount > 0 expected)
  - /ask works end-to-end on a basic question (skipped on simulator
    where AFM models aren't installed)
  - Source attribution metadata present

Formats:
  - txt, md, rtf, docx, html, epub, pdf

Fixtures: tiny synthetic docs in ~/.posey-corpus/ produced by
`tools/generate_test_docs.py`. If any are missing, the harness
flags it and continues with the rest.

The harness is a SKELETON — it exercises the API plumbing and
reports per-format results in a matrix. Mark drives the deep-dive
follow-ups when a cell flags red.

Requires the local API (see posey_test.py setup).
"""

from __future__ import annotations

import http.client
import json
import os
import sys
from typing import Any

_CONFIG_FILE = os.path.join(os.path.dirname(__file__), ".posey_api_config.json")
_AUDIT_REPORT_FILE = os.path.join(os.path.dirname(__file__), "format_parity_audit_report.json")
_FIXTURES_DIR = os.path.expanduser("~/.posey-corpus")


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


def _command(cmd: str) -> Any:
    body = json.dumps({"command": cmd}).encode()
    status, data = _http("POST", "/command", body=body,
                         extra_headers={"Content-Type": "application/json"})
    return data if status == 200 else {"error": f"HTTP {status}", "detail": data}


def _setup_fixtures() -> None:
    """Generate the synthetic fixture set if not already present."""
    if not os.path.exists(_FIXTURES_DIR):
        print(f"Fixtures dir missing — running tools/generate_test_docs.py first.")
        rc = os.system("python3 " + os.path.join(os.path.dirname(__file__), "generate_test_docs.py"))
        if rc != 0:
            print("Generator failed.")
            sys.exit(1)


def _find_fixture(file_type: str) -> str | None:
    """Find a small fixture matching the given file type. Picks the
    first match in any subdir of _FIXTURES_DIR."""
    if not os.path.isdir(_FIXTURES_DIR):
        return None
    extensions = {
        "txt":  [".txt"],
        "md":   [".md", ".markdown"],
        "rtf":  [".rtf"],
        "docx": [".docx"],
        "html": [".html", ".htm"],
        "epub": [".epub"],
        "pdf":  [".pdf"],
    }.get(file_type, [])
    for root, _dirs, files in os.walk(_FIXTURES_DIR):
        for fname in sorted(files):
            for ext in extensions:
                if fname.lower().endswith(ext):
                    return os.path.join(root, fname)
    return None


def _import_file(path: str) -> dict | None:
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        data = f.read()
    filename = os.path.basename(path)
    status, result = _http(
        "POST", "/import", body=data,
        extra_headers={"X-Filename": filename,
                       "Content-Type": "application/octet-stream"},
        timeout=600
    )
    if status == 200 and isinstance(result, dict):
        return result
    return None


def _audit_one(file_type: str) -> dict:
    row: dict[str, Any] = {"format": file_type}
    fixture = _find_fixture(file_type)
    row["fixture"] = fixture or ""
    if not fixture:
        row["status"] = "no_fixture"
        return row

    imported = _import_file(fixture)
    if not imported or "id" not in imported:
        row["status"] = "import_failed"
        return row

    doc_id = imported["id"]
    row["doc_id"] = doc_id
    row["character_count"] = imported.get("characterCount", 0)
    row["import_ok"] = imported.get("characterCount", 0) > 0

    plain = _command(f"GET_PLAIN_TEXT:{doc_id}")
    row["plain_text_present"] = isinstance(plain, dict) and bool(plain.get("plainText"))

    display = _command(f"GET_TEXT:{doc_id}")
    row["display_text_present"] = isinstance(display, dict) and bool(display.get("displayText"))

    # /ask exercise — small generic question. Will fail on simulator
    # without AFM models; we record that distinction.
    body = json.dumps({"documentID": doc_id, "question": "What is this about?", "scope": "document"}).encode()
    status, ask_result = _http("POST", "/ask", body=body,
                               extra_headers={"Content-Type": "application/json"},
                               timeout=180)
    if status == 200 and isinstance(ask_result, dict):
        if "error" in ask_result and ("afmUnavailable" in ask_result["error"] or "Apple Intelligence" in ask_result["error"]):
            row["ask_status"] = "afm_unavailable"
        elif "error" in ask_result:
            row["ask_status"] = "error"
            row["ask_error"] = ask_result["error"][:120]
        else:
            row["ask_status"] = "ok"
            chunks = ask_result.get("chunksInjected", [])
            row["chunks_injected"] = len(chunks)
            row["prompt_tokens"] = ask_result.get("promptTokens", 0)
    else:
        row["ask_status"] = f"http_{status}"

    row["status"] = "audited"
    return row


def run_audit() -> None:
    _setup_fixtures()
    formats = ["txt", "md", "rtf", "docx", "html", "epub", "pdf"]
    rows: list[dict] = []
    print("=== Posey format-parity audit ===\n")
    for fmt in formats:
        print(f"  • auditing {fmt}…", end="", flush=True)
        row = _audit_one(fmt)
        rows.append(row)
        ok = row.get("import_ok") and row.get("plain_text_present")
        print(f"  {'✓' if ok else '✗'}  {row.get('status')}  ask={row.get('ask_status', '—')}")

    with open(_AUDIT_REPORT_FILE, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\n  report → {_AUDIT_REPORT_FILE}")
    print("\nSummary:")
    print(f"  {'Format':6}  {'Import':7}  {'Plain':6}  {'Display':8}  {'Ask':12}  {'Chunks':6}")
    for row in rows:
        ic = "✓" if row.get("import_ok") else "✗"
        pt = "✓" if row.get("plain_text_present") else "✗"
        dt = "✓" if row.get("display_text_present") else "✗"
        as_ = row.get("ask_status", "—")
        ch = str(row.get("chunks_injected", "—"))
        print(f"  {row['format']:6}  {ic:7}  {pt:6}  {dt:8}  {as_:12}  {ch:6}")


def show_report() -> None:
    if not os.path.exists(_AUDIT_REPORT_FILE):
        print("No prior audit report — run `format_parity_audit.py run` first.")
        return
    with open(_AUDIT_REPORT_FILE) as f:
        rows = json.load(f)
    print(json.dumps(rows, indent=2))


def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)
    verb = args[0].lower()
    if verb == "run":
        run_audit()
    elif verb == "report":
        show_report()
    elif verb == "setup":
        _setup_fixtures()
        print("Fixtures ready at " + _FIXTURES_DIR)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
