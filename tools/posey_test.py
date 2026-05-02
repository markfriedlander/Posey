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
import io
import zipfile

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


def _zip_epub_directory(dir_path: str) -> bytes:
    """Zip a directory-format EPUB into an in-memory zip, preserving relative paths."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(dir_path):
            for fname in files:
                full = os.path.join(root, fname)
                arcname = os.path.relpath(full, dir_path)
                zf.write(full, arcname)
    return buf.getvalue()


def _import_file(path: str) -> dict:
    if os.path.isdir(path):
        # Directory-format EPUB — zip in memory before sending.
        data = _zip_epub_directory(path)
    else:
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

def _audit_text(display_text: str, title: str, file_type: str = "") -> dict:
    """Run heuristic checks on extracted display text and return a report dict."""
    import re

    total_chars = len(display_text)

    # Spaced-letter sequences: "I N T R O D U C T I O N"
    spaced_upper = re.findall(r'(?<![A-Z])[A-Z](?: [A-Z]){2,}(?![A-Z])', display_text)
    spaced_lower = re.findall(r'(?<![a-z])[a-z](?: [a-z]){2,}(?![a-z])', display_text)

    # Line-break hyphens: "fas- cism" (ASCII hyphen + whitespace + lowercase word)
    linebreak_hyphens = re.findall(r'[A-Za-z]+-\s[a-z]+', display_text)

    # Unicode soft hyphens (U+00AD) — should be stripped at normalization
    unicode_soft_hyphens = re.findall('\u00ad', display_text)

    # Non-breaking spaces (U+00A0) — should be converted to regular spaces
    nbsp_chars = re.findall('\u00a0', display_text)

    # Zero-width spaces (U+200B) and zero-width non-joiners (U+200C)
    zwsp_chars = re.findall('[\u200b\u200c]', display_text)

    # BOM / zero-width no-break space (U+FEFF)
    bom_chars = re.findall('\ufeff', display_text)

    # Tab characters (should be normalised to spaces)
    tab_count = display_text.count('\t')

    # Form-feed characters outside POSEY visual-page markers.
    # PDFs legitimately use \x0c as the page separator in displayText — don't flag those.
    # For all other formats a form-feed is noise (e.g. old Unix files, man pages).
    if file_type.lower() == "pdf":
        stray_formfeeds = 0   # all \x0c in PDF displayText are intentional page separators
    else:
        text_sans_markers = re.sub(r'\[\[POSEY[^\]]*\]\]', '', display_text)
        stray_formfeeds = text_sans_markers.count('\x0c')

    # Long blocks: paragraphs > 800 chars between visual-page markers or double-newlines.
    # Split on complete [[POSEY...]] markers and \n\n only — NOT on \x0c (PDF page separator).
    # A long block signals that SentenceSegmenter will have to work hard; whether NLTokenizer
    # succeeds depends on punctuation density (see longBlockPunctDensity below).
    raw_blocks = re.split(r'\[\[POSEY[^\]]*\]\]|\n\n', display_text)
    long_block_items = [b.strip() for b in raw_blocks if len(b.strip()) > 800]
    long_block_samples = [b[:120] + "…" if len(b) > 120 else b for b in long_block_items[:5]]
    # Punctuation density for long blocks: periods + ! + ? per 100 chars.
    # > 2.0 → NLTokenizer will likely split fine. < 0.5 → likely produces one giant segment.
    def punct_density(s: str) -> float:
        return round(100.0 * sum(s.count(c) for c in ".!?") / max(len(s), 1), 1)
    long_block_punct_densities = [punct_density(b) for b in long_block_items[:5]]

    # Visual page markers
    visual_pages = re.findall(r'\[\[POSEY_VISUAL_PAGE:\d+:[^\]]+\]\]', display_text)

    return {
        "title": title,
        "totalChars": total_chars,
        "spacedUpperSequences": len(spaced_upper),
        "spacedUpperExamples": spaced_upper[:5],
        "spacedLowerSequences": len(spaced_lower),
        "spacedLowerExamples": spaced_lower[:5],
        "linebreakHyphens": len(linebreak_hyphens),
        "linebreakHyphenExamples": linebreak_hyphens[:5],
        "unicodeSoftHyphens": len(unicode_soft_hyphens),
        "nbspChars": len(nbsp_chars),
        "zwspChars": len(zwsp_chars),
        "bomChars": len(bom_chars),
        "tabChars": tab_count,
        "strayFormfeeds": stray_formfeeds,
        "longBlocks": len(long_block_items),
        "longBlockSamples": long_block_samples,
        "longBlockPunctDensities": long_block_punct_densities,
        "visualPageMarkers": len(visual_pages),
    }


def run_audit(verbose: bool = False) -> None:
    """Import every file in Posey Test Materials, audit text quality, print report."""
    if not os.path.isdir(_TEST_MATERIALS_DIR):
        print(f"Test materials directory not found: {_TEST_MATERIALS_DIR}")
        sys.exit(1)

    def _entry_size(fname: str) -> int:
        fpath = os.path.join(_TEST_MATERIALS_DIR, fname)
        if os.path.isdir(fpath):
            # Directory EPUB — sum all file sizes inside
            return sum(
                os.path.getsize(os.path.join(root, f))
                for root, _dirs, files in os.walk(fpath)
                for f in files
            )
        return os.path.getsize(fpath)

    files = sorted(
        (f for f in os.listdir(_TEST_MATERIALS_DIR)
         if not f.startswith(".") and (
             os.path.isfile(os.path.join(_TEST_MATERIALS_DIR, f)) or
             (os.path.isdir(os.path.join(_TEST_MATERIALS_DIR, f)) and
              f.lower().endswith(".epub"))
         )),
        key=_entry_size
    )
    if not files:
        print("No files found in Posey Test Materials/")
        return

    print(f"Auditing {len(files)} file(s)...\n")
    results = []

    # Clear existing documents so we start clean
    print("  ⚙  RESET_ALL")
    _command("RESET_ALL")

    for fname in files:
        fpath = os.path.join(_TEST_MATERIALS_DIR, fname)
        size_mb = _entry_size(fname) / 1_048_576
        print(f"  ▶  {fname} ({size_mb:.1f} MB)")
        try:
            result = _import_file(fpath)
        except (ConnectionResetError, ConnectionError, OSError) as exc:
            print(f"     ✗  Transfer failed: {exc}")
            results.append({"file": fname, "error": f"transfer: {exc}"})
            print()
            continue
        except Exception as exc:
            print(f"     ✗  Unexpected error: {exc}")
            results.append({"file": fname, "error": f"unexpected: {exc}"})
            print()
            continue
        if not result.get("success"):
            print(f"     ✗  Import failed: {result.get('error', result)}")
            results.append({"file": fname, "error": result.get("error", "unknown")})
            continue
        doc_id = result["id"]
        print(f"     ✓  Imported → {result['title']} ({result['characterCount']:,} chars)")

        text_result = _command(f"GET_TEXT:{doc_id}")
        display_text = text_result.get("displayText", "")
        audit = _audit_text(display_text, result["title"], file_type=result.get("fileType", ""))
        audit["file"] = fname
        audit["fileType"] = result.get("fileType", "?")
        results.append(audit)

        # Summary line
        issues = []
        if audit["spacedUpperSequences"]: issues.append(f"{audit['spacedUpperSequences']} spaced-upper")
        if audit["spacedLowerSequences"]: issues.append(f"{audit['spacedLowerSequences']} spaced-lower")
        if audit["linebreakHyphens"]:     issues.append(f"{audit['linebreakHyphens']} linebreak-hyphens")
        if audit["unicodeSoftHyphens"]:   issues.append(f"{audit['unicodeSoftHyphens']} unicode-soft-hyphens")
        if audit["nbspChars"]:            issues.append(f"{audit['nbspChars']} nbsp")
        if audit["zwspChars"]:            issues.append(f"{audit['zwspChars']} zwsp")
        if audit["bomChars"]:             issues.append(f"{audit['bomChars']} bom")
        if audit["tabChars"]:             issues.append(f"{audit['tabChars']} tabs")
        if audit["strayFormfeeds"]:       issues.append(f"{audit['strayFormfeeds']} stray-formfeeds")
        if audit["longBlocks"]:           issues.append(f"{audit['longBlocks']} long-blocks")
        if audit["visualPageMarkers"]:    issues.append(f"{audit['visualPageMarkers']} visual-pages")
        print(f"     {'⚠  ' + ', '.join(issues) if issues else '✓  Clean'}")

        if verbose and issues:
            if audit["spacedUpperExamples"]:
                print(f"        Spaced upper:    {audit['spacedUpperExamples']}")
            if audit["spacedLowerExamples"]:
                print(f"        Spaced lower:    {audit['spacedLowerExamples']}")
            if audit["linebreakHyphenExamples"]:
                print(f"        LB hyphens:      {audit['linebreakHyphenExamples']}")
            if audit["longBlockSamples"]:
                densities = audit.get("longBlockPunctDensities", [])
                print(f"        Long-block samples (punct/100chars):")
                for i, s in enumerate(audit["longBlockSamples"]):
                    d = densities[i] if i < len(densities) else "?"
                    flag = " ⚠ LOW" if isinstance(d, float) and d < 0.5 else ""
                    print(f"          · [{d}]{flag} {repr(s)}")
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

    # ── ask ──────────────────────────────────────────────────────────────────
    # Drives the full Ask Posey pipeline (intent classify -> prompt build ->
    # AFM stream) for a single turn. M6 test infrastructure per Mark.
    #
    # Examples:
    #   posey_test.py ask <doc-id> "what does this passage mean?"
    #   posey_test.py ask <doc-id> "summarize this document" --scope document
    #   posey_test.py ask <doc-id> "what does this mean?" \
    #                    --anchor-text "Two roads diverged" --anchor-offset 1024
    elif verb == "ask":
        if len(args) < 3:
            print("Usage: posey_test.py ask <doc-id> <question> "
                  "[--scope passage|document] "
                  "[--anchor-text <text>] [--anchor-offset <int>]")
            sys.exit(1)
        doc_id = args[1]
        question = args[2]
        scope = "passage"
        anchor_text = None
        anchor_offset = None
        i = 3
        while i < len(args):
            if args[i] == "--scope" and i + 1 < len(args):
                scope = args[i + 1].lower(); i += 2
            elif args[i] == "--anchor-text" and i + 1 < len(args):
                anchor_text = args[i + 1]; i += 2
            elif args[i] == "--anchor-offset" and i + 1 < len(args):
                anchor_offset = int(args[i + 1]); i += 2
            else:
                print(f"Unknown ask flag: {args[i]}"); sys.exit(1)
        body_dict = {"documentID": doc_id, "question": question, "scope": scope}
        if anchor_text is not None:
            body_dict["anchorText"] = anchor_text
        if anchor_offset is not None:
            body_dict["anchorOffset"] = anchor_offset
        body = json.dumps(body_dict).encode()
        status, data = _http("POST", "/ask", body=body,
                             extra_headers={"Content-Type": "application/json"},
                             timeout=600)
        if status != 200:
            print(f"HTTP {status}: {data}"); sys.exit(1)
        print(json.dumps(data, indent=2))

    # ── open-ask-posey ───────────────────────────────────────────────────────
    # Programmatically opens the Ask Posey sheet on a given document so the
    # simulator MCP can screenshot the user experience. Posts a notification
    # the running app's UI layer observes.
    elif verb in ("open-ask-posey", "openask"):
        if len(args) < 2:
            print("Usage: posey_test.py open-ask-posey <doc-id> [--scope passage|document]")
            sys.exit(1)
        doc_id = args[1]
        scope = "passage"
        i = 2
        while i < len(args):
            if args[i] == "--scope" and i + 1 < len(args):
                scope = args[i + 1].lower(); i += 2
            else:
                print(f"Unknown open-ask-posey flag: {args[i]}"); sys.exit(1)
        body = json.dumps({"documentID": doc_id, "scope": scope}).encode()
        status, data = _http("POST", "/open-ask-posey", body=body,
                             extra_headers={"Content-Type": "application/json"},
                             timeout=30)
        if status != 200:
            print(f"HTTP {status}: {data}"); sys.exit(1)
        print(json.dumps(data, indent=2))

    else:
        print(f"Unknown command: {verb}\n")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
