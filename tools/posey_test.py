#!/usr/bin/env python3
"""
posey_test.py — Posey Local API Test Runner
=============================================
Single-file, zero-dependency test runner for Posey's Local API.

SETUP (one time)
----------------
  1. In Posey, tap the antenna icon (top-left of Library screen) to enable the API.
  2. The IP address and token are printed to the Xcode / device console on startup.
  3. Run setup with those values:

     python3 tools/posey_test.py setup <ip> 8765 <token>

  Config saved to tools/.posey_api_config.json — auto-used from then on.

USAGE
-----
  python3 tools/posey_test.py state
  python3 tools/posey_test.py cmd LIST_DOCUMENTS
  python3 tools/posey_test.py cmd GET_TEXT:<document-id>
  python3 tools/posey_test.py cmd GET_PLAIN_TEXT:<document-id>
  python3 tools/posey_test.py cmd DELETE_DOCUMENT:<document-id>
  python3 tools/posey_test.py cmd RESET_ALL
  python3 tools/posey_test.py cmd DB_STATS
  python3 tools/posey_test.py import <path/to/file.pdf>
  python3 tools/posey_test.py audit                   # import + text quality report for all test materials
  python3 tools/posey_test.py ls                      # pretty-print document list

COMMANDS
--------
  LIST_DOCUMENTS              → [{id, title, fileType, characterCount, importedAt}]
  GET_TEXT:<id>               → {id, title, fileType, displayText}  (with markers)
  GET_PLAIN_TEXT:<id>         → {id, title, fileType, plainText}
  DELETE_DOCUMENT:<id>        → {deleted, id}
  RESET_ALL                   → {deleted: N}
  DB_STATS                    → {documentCount, byFileType}

API ENDPOINTS
-------------
  POST /command  {"command": "..."}     → JSON result
  POST /import   (raw bytes)            → {success, id, title, fileType, characterCount}
  GET  /state                           → app state JSON
  All requests require: Authorization: Bearer <token>
"""

import os
import sys
import json
import http.client

# ─── Config ───────────────────────────────────────────────────────────────────

_SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
_CONFIG_FILE = os.path.join(_SCRIPT_DIR, ".posey_api_config.json")

_api_config: dict | None = None

def _load_config() -> dict | None:
    global _api_config
    if os.path.exists(_CONFIG_FILE):
        try:
            with open(_CONFIG_FILE) as f:
                _api_config = json.load(f)
        except Exception as e:
            print(f"  ⚠  Could not read config: {e}")
    return _api_config

_load_config()

# ─── HTTP Transport ────────────────────────────────────────────────────────────

def _http(method: str, path: str, body: bytes | None = None,
          extra_headers: dict | None = None, timeout: int = 300) -> tuple[int, dict | str]:
    cfg  = _api_config
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
    raw  = resp.read()
    conn.close()
    try:
        return resp.status, json.loads(raw)
    except Exception:
        return resp.status, raw.decode("utf-8", errors="replace")


def _command(cmd: str) -> dict:
    body = json.dumps({"command": cmd}).encode()
    status, data = _http("POST", "/command", body=body,
                         extra_headers={"Content-Type": "application/json"})
    if status != 200:
        return {"error": f"HTTP {status}", "detail": data}
    return data if isinstance(data, dict) else {"raw": data}


def _import_file(path: str) -> dict:
    with open(path, "rb") as f:
        data = f.read()
    filename = os.path.basename(path)
    status, result = _http(
        "POST", "/import", body=data,
        extra_headers={"X-Filename": filename,
                       "Content-Type": "application/octet-stream"},
        timeout=600
    )
    if status != 200:
        return {"error": f"HTTP {status}", "detail": result}
    return result if isinstance(result, dict) else {"raw": result}


def _state() -> dict:
    status, data = _http("GET", "/state")
    if status == 200:
        return data if isinstance(data, dict) else {"raw": data}
    return {"error": f"HTTP {status}"}

# ─── Text quality audit ───────────────────────────────────────────────────────

_TEST_MATERIALS_DIR = os.path.join(os.path.dirname(_SCRIPT_DIR), "Posey Test Materials")

def _audit_text(display_text: str, title: str) -> dict:
    """Run heuristic checks on extracted display text and return a report dict."""
    import re

    lines = display_text.splitlines()
    total_chars = len(display_text)

    # Spaced-letter sequences: "I N T R O D U C T I O N"
    spaced_upper = re.findall(r'(?<![A-Z])[A-Z](?: [A-Z]){2,}(?![A-Z])', display_text)
    spaced_lower = re.findall(r'(?<![a-z])[a-z](?: [a-z]){2,}(?![a-z])', display_text)

    # Line-break hyphens: "fas- cism"
    soft_hyphens = re.findall(r'[A-Za-z]+-\s[a-z]+', display_text)

    # Long blocks (segments > 800 chars between page markers or double-newlines)
    long_blocks = [b for b in re.split(r'\[\[POSEY|\\f|\n\n', display_text)
                   if len(b.strip()) > 800]

    # Visual page markers
    visual_pages = re.findall(r'\[\[POSEY_VISUAL_PAGE:\d+:[^\]]+\]\]', display_text)

    return {
        "title": title,
        "totalChars": total_chars,
        "spacedUpperSequences": len(spaced_upper),
        "spacedUpperExamples": spaced_upper[:5],
        "spacedLowerSequences": len(spaced_lower),
        "spacedLowerExamples": spaced_lower[:5],
        "softHyphens": len(soft_hyphens),
        "softHyphenExamples": soft_hyphens[:5],
        "longBlocks": len(long_blocks),
        "visualPageMarkers": len(visual_pages),
    }


def run_audit(verbose: bool = False) -> None:
    """Import every file in Posey Test Materials, audit text quality, print report."""
    if not os.path.isdir(_TEST_MATERIALS_DIR):
        print(f"Test materials directory not found: {_TEST_MATERIALS_DIR}")
        sys.exit(1)

    files = sorted(
        f for f in os.listdir(_TEST_MATERIALS_DIR)
        if not f.startswith(".") and os.path.isfile(
            os.path.join(_TEST_MATERIALS_DIR, f))
    )
    if not files:
        print("No files found in Posey Test Materials/")
        return

    print(f"Auditing {len(files)} file(s)...\n")
    results = []

    # Clear existing documents so we start clean
    print("  ⚙  RESET_ALL")
    _command("RESET_ALL")

    _MAX_MB = 50

    for fname in files:
        fpath = os.path.join(_TEST_MATERIALS_DIR, fname)
        size_mb = os.path.getsize(fpath) / 1_048_576
        print(f"  ▶  {fname} ({size_mb:.1f} MB)")
        if size_mb > _MAX_MB:
            print(f"     ⚠  Skipped — {size_mb:.0f} MB exceeds {_MAX_MB} MB limit (too large for in-memory transfer)\n")
            results.append({"file": fname, "error": f"skipped: {size_mb:.0f} MB > {_MAX_MB} MB limit"})
            continue
        result = _import_file(fpath)
        if not result.get("success"):
            print(f"     ✗  Import failed: {result.get('error', result)}")
            results.append({"file": fname, "error": result.get("error", "unknown")})
            continue
        doc_id = result["id"]
        print(f"     ✓  Imported → {result['title']} ({result['characterCount']:,} chars)")

        text_result = _command(f"GET_TEXT:{doc_id}")
        display_text = text_result.get("displayText", "")
        audit = _audit_text(display_text, result["title"])
        audit["file"] = fname
        audit["fileType"] = result.get("fileType", "?")
        results.append(audit)

        # Summary line
        issues = []
        if audit["spacedUpperSequences"]: issues.append(f"{audit['spacedUpperSequences']} spaced-upper")
        if audit["spacedLowerSequences"]: issues.append(f"{audit['spacedLowerSequences']} spaced-lower")
        if audit["softHyphens"]:         issues.append(f"{audit['softHyphens']} soft-hyphens")
        if audit["longBlocks"]:          issues.append(f"{audit['longBlocks']} long-blocks")
        if audit["visualPageMarkers"]:   issues.append(f"{audit['visualPageMarkers']} visual-pages")
        print(f"     {'⚠  ' + ', '.join(issues) if issues else '✓  Clean'}")

        if verbose and issues:
            if audit["spacedUpperExamples"]:
                print(f"        Spaced upper: {audit['spacedUpperExamples']}")
            if audit["spacedLowerExamples"]:
                print(f"        Spaced lower: {audit['spacedLowerExamples']}")
            if audit["softHyphenExamples"]:
                print(f"        Soft hyphens: {audit['softHyphenExamples']}")
        print()

    # Write report
    report_path = os.path.join(_SCRIPT_DIR, "audit_report.json")
    with open(report_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"✓ Full report written to: {report_path}")

# ─── CLI ──────────────────────────────────────────────────────────────────────

def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)

    verb = args[0].lower()

    # ── setup ────────────────────────────────────────────────────────────────
    if verb == "setup":
        if len(args) < 4:
            print("Usage: posey_test.py setup <host> <port> <token>")
            sys.exit(1)
        host, port, token = args[1], int(args[2]), args[3]
        cfg = {"host": host, "port": port, "token": token}
        with open(_CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
        print(f"✓ Config written to {_CONFIG_FILE}")
        print(f"  Host:  {host}:{port}")
        print(f"  Token: {token[:8]}...")
        print(f"\nVerify: python3 tools/posey_test.py state")

    # ── state ────────────────────────────────────────────────────────────────
    elif verb == "state":
        print(json.dumps(_state(), indent=2))

    # ── cmd ──────────────────────────────────────────────────────────────────
    elif verb == "cmd":
        if len(args) < 2:
            print("Usage: posey_test.py cmd <COMMAND>")
            sys.exit(1)
        result = _command(" ".join(args[1:]))
        print(json.dumps(result, indent=2))

    # ── ls ───────────────────────────────────────────────────────────────────
    elif verb == "ls":
        result = _command("LIST_DOCUMENTS")
        docs = result if isinstance(result, list) else result.get("raw", result)
        if isinstance(docs, list):
            if not docs:
                print("No documents.")
            for doc in docs:
                print(f"  {doc['id']}  {doc['fileType']:6}  {doc['characterCount']:>10,} chars  {doc['title']}")
        else:
            print(json.dumps(result, indent=2))

    # ── import ───────────────────────────────────────────────────────────────
    elif verb == "import":
        if len(args) < 2:
            print("Usage: posey_test.py import <path/to/file>")
            sys.exit(1)
        path = args[1]
        if not os.path.exists(path):
            print(f"File not found: {path}")
            sys.exit(1)
        result = _import_file(path)
        print(json.dumps(result, indent=2))

    # ── audit ────────────────────────────────────────────────────────────────
    elif verb == "audit":
        verbose = "--verbose" in args or "-v" in args
        run_audit(verbose=verbose)

    else:
        print(f"Unknown command: {verb}\n")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
