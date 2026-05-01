#!/usr/bin/env python3
"""
verify_synthetic_corpus.py — drive Posey through the synthetic corpus.

Workflow:
    1. (Optional) regenerate the corpus via generate_test_docs.py
    2. RESET_ALL on the device to start clean
    3. Import every synthetic doc via the local API
    4. For each doc, GET_PLAIN_TEXT and GET_TEXT, then run a per-doc
       assertion that knows what normalization SHOULD have done
    5. Print PASS / FAIL summary; exit 0 only if all assertions pass

Requires the local API to be configured first:
    python3 tools/posey_test.py setup <ip> 8765 <token>

Usage:
    # Generate + verify
    python3 tools/verify_synthetic_corpus.py

    # Use an existing corpus directory
    python3 tools/verify_synthetic_corpus.py --corpus-dir /tmp/posey_synthetic_corpus

    # Skip the RESET_ALL safety wipe (don't trash the device library)
    python3 tools/verify_synthetic_corpus.py --no-reset
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).parent
GENERATOR = SCRIPT_DIR / "generate_test_docs.py"
DEFAULT_CORPUS = Path.home() / ".posey-corpus"

# ----------------------------------------------------------------------
# Per-document assertions.
#
# Each function receives the plainText returned by GET_PLAIN_TEXT and
# the displayText from GET_TEXT, plus the raw source bytes that were
# imported. It returns a list of failure messages (empty = pass).
#
# These encode what we EXPECT Posey's normalization to have done.
# ----------------------------------------------------------------------

def _no_chars(plain: str, *chars: str) -> List[str]:
    return [f"contains {c!r} (U+{ord(c):04X})" for c in chars if c in plain]


def _expect_substring(plain: str, *needles: str) -> List[str]:
    return [f"missing {n!r}" for n in needles if n not in plain]


def _expect_no_substring(plain: str, *needles: str) -> List[str]:
    return [f"contains unwanted {n!r}" for n in needles if n in plain]


def _ok(_p: str, _d: str, _src: bytes) -> List[str]:
    return []


def _txt_baseline(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_substring(p, "The reader settled into the chair")
    return fails


def _txt_soft_hyphens(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    # U+00AD must be stripped.
    fails += _no_chars(p, "­")
    # Words must reassemble. Case-insensitive — PROSE_LINES has 'Footnotes'
    # with a capital F at the start of one sentence.
    lower = p.lower()
    for word in ["settled", "patience", "footnotes"]:
        if word not in lower:
            fails.append(f"missing {word!r} (case-insensitive)")
    return fails


def _txt_line_break_hyphens(p: str, _d: str, _src: bytes) -> List[str]:
    # PDF wraps like "inde- pendent" must collapse to "independent".
    fails: List[str] = []
    expected_words = ["independent", "understanding", "translation", "remark", "demonstration"]
    fails += _expect_substring(p, *expected_words)
    fails += _expect_no_substring(p, "inde- pendent", "under- standing")
    return fails


def _txt_logical_not_hyphens(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    # ¬ should never appear.
    fails += _no_chars(p, "¬")
    fails += _expect_substring(p, "independent", "understanding", "translation")
    return fails


def _txt_nbsp(p: str, _d: str, _src: bytes) -> List[str]:
    return _no_chars(p, " ")


def _txt_zwsp(p: str, _d: str, _src: bytes) -> List[str]:
    return _no_chars(p, "​", "‌", "‍")


def _txt_bom(p: str, _d: str, _src: bytes) -> List[str]:
    return _no_chars(p, "﻿")


def _txt_tabs(p: str, _d: str, _src: bytes) -> List[str]:
    # Expect tabs to be normalized to spaces (or otherwise removed).
    if "\t" in p:
        return [f"contains {p.count(chr(9))} tab character(s)"]
    return []


def _txt_mixed_line_endings(p: str, _d: str, _src: bytes) -> List[str]:
    # \r should not appear in normalized text.
    return _no_chars(p, "\r")


def _txt_trailing_whitespace(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    for line in p.splitlines():
        if line.rstrip() != line:
            fails.append(f"line has trailing whitespace: {line!r}")
            break  # report only the first, don't drown the report
    return fails


def _txt_excessive_blank_lines(p: str, _d: str, _src: bytes) -> List[str]:
    # Should collapse to at most a double newline.
    if "\n\n\n" in p:
        return [f"contains excessive blank-line runs (\\n\\n\\n…)"]
    return []


def _txt_spaced_uppercase(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_no_substring(p, "C O N T E N T S", "I N T R O D U C T I O N")
    fails += _expect_substring(p, "CONTENTS", "INTRODUCTION")
    return fails


def _txt_spaced_lowercase(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_no_substring(p, "t a b l e   o f   c o n t e n t s")
    return fails


def _txt_spaced_accented(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_no_substring(p, "P A S A R Á N")
    fails += _expect_substring(p, "PASARÁN")
    return fails


def _txt_spaced_digits(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_no_substring(p, "1 9 4 5", "2 0 0 1")
    fails += _expect_substring(p, "1945", "2001")
    return fails


def _txt_ligatures(p: str, _d: str, _src: bytes) -> List[str]:
    # Posey doesn't currently decompose ligatures, but the file should
    # still load without crashing. This assertion just verifies survival.
    if not p.strip():
        return ["plainText is empty after ligature normalization"]
    return []


def _txt_mixed_scripts(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_substring(p, "книга", "βιβλίο", "كتاب", "书")
    return fails


def _txt_emoji(p: str, _d: str, _src: bytes) -> List[str]:
    if "📖" not in p and "\U0001f4d6" not in p:
        return ["emoji not preserved in plainText"]
    return []


def _txt_combining_diacritics(p: str, _d: str, _src: bytes) -> List[str]:
    if "Café" not in p and "Café" not in p:
        return ["'Café' missing in either form"]
    return []


def _txt_rtl_mixed(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "مرحبا", "שלום")


def _txt_empty(_p: str, _d: str, _src: bytes) -> List[str]:
    # The importer SHOULD reject empty documents (TXTDocumentImporter
    # throws .emptyDocument). If we get here the test_runner has captured
    # the rejection; the verifier reports it as expected.
    return []


def _txt_only_whitespace(_p: str, _d: str, _src: bytes) -> List[str]:
    # Same — should be rejected by emptyDocument.
    return []


def _txt_one_char(p: str, _d: str, _src: bytes) -> List[str]:
    if p.strip() != "A":
        return [f"expected 'A', got {p.strip()!r}"]
    return []


def _txt_only_punctuation(p: str, _d: str, _src: bytes) -> List[str]:
    if not p.strip():
        return ["plainText is empty (punctuation lost)"]
    return []


def _txt_very_long_no_punct(p: str, _d: str, _src: bytes) -> List[str]:
    if len(p) < 2000:
        return [f"plainText too short ({len(p)} chars; source had ~2300)"]
    return []


def _txt_dot_leader_toc(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_substring(p, "Chapter 1", "Chapter 4", "Index")
    return fails


def _txt_only_page_numbers(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "1", "5")


def _txt_repeated_boilerplate(p: str, _d: str, _src: bytes) -> List[str]:
    if "(c) 2024" not in p:
        return ["boilerplate text not preserved"]
    return []


def _txt_very_long_document(p: str, _d: str, _src: bytes) -> List[str]:
    if len(p) < 80_000:
        return [f"plainText shorter than expected ({len(p)} chars)"]
    return []


def _txt_unbalanced_quotes(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "broken")


def _txt_long_url(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "web.archive.org")


def _md_clean(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "Top heading", "Subheading")


def _md_headings_only(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "H1 alone", "H6 alone")


def _md_artifacts(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _no_chars(p, "­", " ")
    fails += _expect_no_substring(p, "T H I S   I S   I T")
    return fails


def _html_clean(p: str, _d: str, _src: bytes) -> List[str]:
    return _expect_substring(p, "Title")


def _html_with_script(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_substring(p, "Visible text", "More visible text")
    fails += _expect_no_substring(p, "alert", "color: red")
    return fails


def _html_entities(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_substring(p, "&", "<", ">")
    fails += _expect_no_substring(p, "&amp;", "&lt;", "&gt;", "&nbsp;")
    return fails


def _rtf_clean(p: str, _d: str, _src: bytes) -> List[str]:
    fails: List[str] = []
    fails += _expect_substring(p, "settled into the chair")
    fails += _expect_no_substring(p, "\\rtf1", "\\f0", "\\par")
    return fails


# ----------------------------------------------------------------------
# Map filename → (expected to import?, assertion)
# ----------------------------------------------------------------------
ASSERTIONS: Dict[str, Tuple[bool, Callable[[str, str, bytes], List[str]]]] = {
    # TXT
    "txt/00_baseline_clean.txt":         (True, _txt_baseline),
    "txt/01_soft_hyphens.txt":           (True, _txt_soft_hyphens),
    "txt/02_line_break_hyphens.txt":     (True, _txt_line_break_hyphens),
    "txt/03_logical_not_hyphens.txt":    (True, _txt_logical_not_hyphens),
    "txt/04_nbsp.txt":                   (True, _txt_nbsp),
    "txt/05_zwsp.txt":                   (True, _txt_zwsp),
    "txt/06_bom.txt":                    (True, _txt_bom),
    "txt/07_tabs.txt":                   (True, _txt_tabs),
    "txt/08_mixed_line_endings.txt":     (True, _txt_mixed_line_endings),
    "txt/09_trailing_whitespace.txt":    (True, _txt_trailing_whitespace),
    "txt/10_excessive_blank_lines.txt":  (True, _txt_excessive_blank_lines),
    "txt/11_spaced_uppercase.txt":       (True, _txt_spaced_uppercase),
    "txt/12_spaced_lowercase.txt":       (True, _txt_spaced_lowercase),
    "txt/13_spaced_accented.txt":        (True, _txt_spaced_accented),
    "txt/14_spaced_digits.txt":          (True, _txt_spaced_digits),
    "txt/15_ligatures.txt":              (True, _txt_ligatures),
    "txt/16_mixed_scripts.txt":          (True, _txt_mixed_scripts),
    "txt/17_emoji.txt":                  (True, _txt_emoji),
    "txt/18_combining_diacritics.txt":   (True, _txt_combining_diacritics),
    "txt/19_rtl_mixed.txt":              (True, _txt_rtl_mixed),
    "txt/20_empty.txt":                  (False, _txt_empty),
    "txt/21_only_whitespace.txt":        (False, _txt_only_whitespace),
    "txt/22_one_char.txt":               (True, _txt_one_char),
    "txt/23_only_punctuation.txt":       (True, _txt_only_punctuation),
    "txt/24_very_long_no_punct.txt":     (True, _txt_very_long_no_punct),
    "txt/25_dot_leader_toc.txt":         (True, _txt_dot_leader_toc),
    "txt/26_only_page_numbers.txt":      (True, _txt_only_page_numbers),
    "txt/27_repeated_boilerplate.txt":   (True, _txt_repeated_boilerplate),
    "txt/28_very_long_document.txt":     (True, _txt_very_long_document),
    "txt/29_unbalanced_quotes.txt":      (True, _txt_unbalanced_quotes),
    "txt/30_long_url.txt":               (True, _txt_long_url),
    # MD
    "md/00_md_clean.md":                 (True, _md_clean),
    "md/01_md_headings_only.md":         (True, _md_headings_only),
    "md/02_md_nested_lists.md":          (True, _ok),
    "md/03_md_code_blocks.md":           (True, _ok),
    "md/04_md_blockquote_nested.md":     (True, _ok),
    "md/05_md_inline_html.md":           (True, _ok),
    "md/06_md_with_artifacts.md":        (True, _md_artifacts),
    # HTML
    "html/00_html_clean.html":           (True, _html_clean),
    "html/01_html_no_paragraphs.html":   (True, _ok),
    "html/02_html_inline_styles.html":   (True, _ok),
    "html/03_html_table.html":           (True, _ok),
    "html/04_html_with_script.html":     (True, _html_with_script),
    "html/05_html_entities.html":        (True, _html_entities),
    "html/06_html_deeply_nested.html":   (True, _ok),
    # RTF
    "rtf/00_rtf_clean.rtf":              (True, _rtf_clean),
    "rtf/01_rtf_styled.rtf":             (True, _ok),
}


# ----------------------------------------------------------------------
# Local-API helpers (delegated to posey_test.py for connection setup)
# ----------------------------------------------------------------------

def _load_posey_test_module():
    spec = importlib.util.spec_from_file_location(
        "posey_test_runtime", SCRIPT_DIR / "posey_test.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load posey_test.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus-dir", type=Path, default=DEFAULT_CORPUS,
                        help=f"Where the corpus lives. Default: {DEFAULT_CORPUS}")
    parser.add_argument("--regenerate", action="store_true",
                        help="Run generate_test_docs.py before verifying")
    parser.add_argument("--no-reset", action="store_true",
                        help="Skip the RESET_ALL wipe (don't clear the device library)")
    parser.add_argument("--limit", type=int, default=0,
                        help="Verify only the first N docs (for quick smoke runs)")
    args = parser.parse_args(argv)

    if args.regenerate:
        print("Regenerating corpus…")
        subprocess.check_call([sys.executable, str(GENERATOR), "--output-dir", str(args.corpus_dir)])

    if not args.corpus_dir.exists():
        print(f"Corpus not found at {args.corpus_dir}. Pass --regenerate to create it.", file=sys.stderr)
        return 2

    pt = _load_posey_test_module()
    if pt._api_config is None:
        print("Local API not configured. Run: python3 tools/posey_test.py setup <ip> 8765 <token>",
              file=sys.stderr)
        return 2

    if not args.no_reset:
        print("RESET_ALL — clearing device library…")
        result = pt._command("RESET_ALL")
        print(f"  {result}")

    docs = sorted(ASSERTIONS.items())
    if args.limit > 0:
        docs = docs[:args.limit]

    passes = 0
    fails: List[Tuple[str, List[str]]] = []
    skipped = 0

    for relpath, (should_import, assertion) in docs:
        path = args.corpus_dir / relpath
        if not path.exists():
            fails.append((relpath, [f"file not found in corpus dir"]))
            continue

        src = path.read_bytes()

        # Import
        try:
            status, data = pt._http("POST", "/import", body=src,
                                     extra_headers={"X-Filename": path.name,
                                                    "Content-Type": "application/octet-stream"})
        except Exception as e:
            fails.append((relpath, [f"import threw: {e}"]))
            continue

        if status != 200 or not isinstance(data, dict) or not data.get("success"):
            if not should_import:
                # Expected failure
                passes += 1
                print(f"  ✓  {relpath:50}  (rejected as expected)")
                continue
            fails.append((relpath, [f"import failed (status={status}, body={data})"]))
            continue

        if not should_import:
            fails.append((relpath, ["expected import to fail, but it succeeded"]))
            continue

        doc_id = data["id"]

        # Pull plainText and displayText
        try:
            plain_resp = pt._command(f"GET_PLAIN_TEXT:{doc_id}")
            display_resp = pt._command(f"GET_TEXT:{doc_id}")
        except Exception as e:
            fails.append((relpath, [f"GET_TEXT/GET_PLAIN_TEXT threw: {e}"]))
            continue

        plain = plain_resp.get("plainText", "") if isinstance(plain_resp, dict) else ""
        display = display_resp.get("displayText", "") if isinstance(display_resp, dict) else ""

        problems = assertion(plain, display, src)
        if problems:
            fails.append((relpath, problems))
        else:
            passes += 1
            print(f"  ✓  {relpath:50}  ({len(plain)} chars)")

    print()
    print("=" * 70)
    print(f"PASS: {passes}    FAIL: {len(fails)}    SKIP: {skipped}    TOTAL: {len(docs)}")
    print("=" * 70)
    if fails:
        print("\nFailures:")
        for relpath, problems in fails:
            print(f"\n  ✗  {relpath}")
            for p in problems:
                print(f"     - {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
