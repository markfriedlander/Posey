#!/usr/bin/env python3
"""verify_image_corpus.py — Image-extraction regression for Posey.

Imports every fixture in TestFixtures/parity/images/ via the local API,
calls LIST_IMAGES on each, and asserts the expected image count. Designed
to be run after non-trivial importer / display-block / rendering changes
to catch silent regressions in image extraction.

Two corpora:
- **Core fixtures**: image-stress.docx (5), image-stress.html (5 + 1
  broken src that must NOT crash), real-image-stress.docx (5 real
  JPEGs), real-image-stress.html (5 base64 photos), illustrated.epub
  (55 figures). These ship with the repo.
- **Adversarial fixtures**: built by `tools/generate_adversarial_images.py`
  (1px, transparent, table-embedded, consecutive, etc.). Generated
  on-demand if not present.

Usage:
  python3 tools/verify_image_corpus.py
  python3 tools/verify_image_corpus.py --adversarial   # also runs the
                                                       # adversarial set
  python3 tools/verify_image_corpus.py --skip-import   # assume already
                                                       # imported; only
                                                       # re-verify counts

Requires the Local API to be enabled on the running app and the runner
configured via `tools/posey_test.py setup` first.
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "TestFixtures" / "parity" / "images"
ADVERSARIAL = REPO / "TestFixtures" / "parity" / "images-adversarial"
CONFIG = REPO / "tools" / ".posey_api_config.json"

# Core fixture expectations — what each file should produce from
# LIST_IMAGES. Numbers come from the README and the 2026-05-12
# pre-submission verification.
CORE_EXPECT = {
    "image-stress.docx":      {"min_images": 5,  "max_images": 8},
    "image-stress.html":      {"min_images": 5,  "max_images": 8,
                               "must_not_crash": True},  # has broken <img src>
    "real-image-stress.docx": {"min_images": 5,  "max_images": 8},
    "real-image-stress.html": {"min_images": 5,  "max_images": 8},
    "illustrated.epub":       {"min_images": 50, "max_images": 60},
}


def load_config():
    if not CONFIG.exists():
        print(f"ERROR: no API config at {CONFIG}. Run `python3 tools/posey_test.py setup <ip> 8765 <token>` first.",
              file=sys.stderr)
        sys.exit(1)
    return json.loads(CONFIG.read_text())


def api_command(cfg, command):
    req = urllib.request.Request(
        f"http://{cfg['host']}:{cfg['port']}/command",
        method="POST",
        headers={
            "Authorization": f"Bearer {cfg['token']}",
            "Content-Type": "application/json",
        },
        data=json.dumps({"command": command}).encode("utf-8"),
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def api_import(cfg, file_path):
    with open(file_path, "rb") as fh:
        body = fh.read()
    req = urllib.request.Request(
        f"http://{cfg['host']}:{cfg['port']}/import",
        method="POST",
        headers={
            "Authorization": f"Bearer {cfg['token']}",
            "Content-Type": "application/octet-stream",
            "X-Filename": os.path.basename(file_path),
        },
        data=body,
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def resolve_doc_id(cfg, filename_basename):
    """Find the most recently imported document whose fileName matches.
    Title-substring lookup first; falls back to most-recent doc of the
    matching fileType extension (handles cases where the importer
    pulled a title from EPUB metadata that doesn't match the filename
    stem — e.g. illustrated.epub → 'Alice's Adventures in Wonderland').
    """
    docs = api_command(cfg, "LIST_DOCUMENTS")
    if isinstance(docs, dict):
        docs = docs.get("raw", docs)
    matches = [d for d in docs if filename_basename.lower() in
               (d.get("title") or "").lower()]
    if not matches:
        ext = os.path.splitext(filename_basename)[1].lstrip(".").lower()
        matches = [d for d in docs if d.get("fileType") == ext]
    if not matches:
        return None
    matches.sort(key=lambda d: d.get("importedAt", ""), reverse=True)
    return matches[0].get("id")


def verify_one(cfg, fixture_path, spec, skip_import=False):
    name = os.path.basename(fixture_path)
    title_stem = os.path.splitext(name)[0]
    imported_id = None
    if not skip_import:
        try:
            resp = api_import(cfg, fixture_path)
        except Exception as e:
            return {"name": name, "status": "FAIL",
                    "reason": f"import threw: {e}"}
        if not resp.get("success"):
            err = resp.get("error", "no error returned")
            if spec.get("must_not_crash"):
                # Importer rejected but didn't crash — partial pass
                return {"name": name, "status": "PASS-WITH-REJECT",
                        "reason": f"rejected (no crash): {err[:80]}"}
            return {"name": name, "status": "FAIL", "reason": err[:120]}
        # Prefer the just-returned id — avoids ambiguity when multiple
        # fixtures have the same publisher title (e.g. three copies of
        # illustrated.epub all titled "Alice's Adventures in Wonderland").
        imported_id = resp.get("id")

    doc_id = imported_id or resolve_doc_id(cfg, name)
    if not doc_id:
        return {"name": name, "status": "FAIL",
                "reason": "could not resolve doc id after import"}

    images = api_command(cfg, f"LIST_IMAGES:{doc_id}")
    if isinstance(images, dict):
        # antenna returns { "documentID": ..., "images": [...] } or { "raw": [...] }
        if "images" in images:
            count = len(images["images"])
        elif "raw" in images and isinstance(images["raw"], list):
            count = len(images["raw"])
        else:
            count = images.get("count") or 0
    elif isinstance(images, list):
        count = len(images)
    else:
        count = 0

    lo = spec.get("min_images", 0)
    hi = spec.get("max_images", 10**6)
    if count < lo:
        return {"name": name, "status": "FAIL",
                "reason": f"got {count} images, expected ≥ {lo}"}
    if count > hi:
        return {"name": name, "status": "FAIL",
                "reason": f"got {count} images, expected ≤ {hi}"}
    return {"name": name, "status": "PASS",
            "reason": f"{count} images extracted"}


def ensure_adversarial(force=False):
    """Run the generator if needed."""
    if ADVERSARIAL.exists() and not force:
        return
    gen = REPO / "tools" / "generate_adversarial_images.py"
    if not gen.exists():
        print(f"WARN: no adversarial generator at {gen}", file=sys.stderr)
        return
    subprocess.run([sys.executable, str(gen)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adversarial", action="store_true",
                    help="also verify the adversarial corpus")
    ap.add_argument("--skip-import", action="store_true",
                    help="don't re-import; assume fixtures already loaded")
    args = ap.parse_args()

    cfg = load_config()
    print(f"=== Image-corpus regression — {cfg['host']}:{cfg['port']} ===")

    results = []
    for name, spec in CORE_EXPECT.items():
        path = FIXTURES / name
        if not path.exists():
            results.append({"name": name, "status": "SKIP",
                            "reason": f"fixture missing at {path}"})
            continue
        r = verify_one(cfg, str(path), spec, skip_import=args.skip_import)
        print(f"  {r['status']:18s} {r['name']:30s} {r['reason']}")
        results.append(r)

    if args.adversarial:
        ensure_adversarial()
        if ADVERSARIAL.exists():
            for path in sorted(ADVERSARIAL.iterdir()):
                if path.is_file() and path.suffix.lower() in {".docx", ".html",
                                                              ".epub", ".pdf"}:
                    # Adversarial fixtures should import without crashing
                    # but image counts vary by fixture — we just verify
                    # the importer survived.
                    r = verify_one(cfg, str(path),
                                   {"min_images": 0, "max_images": 10**6,
                                    "must_not_crash": True},
                                   skip_import=args.skip_import)
                    print(f"  {r['status']:18s} {r['name']:30s} {r['reason']}")
                    results.append(r)

    passes = sum(1 for r in results if r["status"].startswith("PASS"))
    fails = sum(1 for r in results if r["status"] == "FAIL")
    skips = sum(1 for r in results if r["status"] == "SKIP")
    print(f"\n=== Summary: {passes} pass, {fails} fail, {skips} skip ===")
    sys.exit(0 if fails == 0 else 1)


if __name__ == "__main__":
    main()
