#!/usr/bin/env python3
"""
fetch_gutenberg.py — pull a representative sample of real EPUBs from
Project Gutenberg via the Gutendex API (https://gutendex.com).

Why this exists:
  Posey's normalization, segmentation, and display pipelines need to be
  exercised against actual books, not just hand-crafted edge cases.
  Project Gutenberg has 70 000+ public-domain works in many shapes:
  19th-century prose, dense non-fiction, poetry, technical works,
  illustrated children's books, plays, philosophy, etc. A small but
  carefully selected slice is a more honest stress test than any
  synthetic corpus.

What it does:
  1. Hits the Gutendex /books API for each curated category (queries
     defined below).
  2. Takes the most-downloaded result that has an EPUB format link.
  3. Downloads the EPUB to the corpus directory.
  4. Writes manifest.json next to the EPUBs with id, title, author,
     download count, language, subjects, source URL, and category.
  5. Prints a summary at the end.

The selection is deliberately small (20–30 books) and deliberately
varied — one example from each kind of writing Posey is likely to
encounter.

Usage:
    python3 tools/fetch_gutenberg.py
    python3 tools/fetch_gutenberg.py --output-dir /tmp/gutenberg
    python3 tools/fetch_gutenberg.py --categories prose,poetry
    python3 tools/fetch_gutenberg.py --list      # show what would be fetched
    python3 tools/fetch_gutenberg.py --refresh   # re-download even if present

Pair with verify_synthetic_corpus.py-style auditing to run the books
through Posey and capture any failures.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional

GUTENDEX_BASE = "https://gutendex.com/books"
DEFAULT_OUTPUT = Path.home() / ".posey-gutenberg-corpus"
USER_AGENT = "Posey-Test-Harness/1.0 (contact: localhost)"
TIMEOUT = 30


# ----------------------------------------------------------------------
# Curated queries — each is one example from one category. The selection
# is deliberately small. If Gutendex returns nothing, the entry is
# skipped with a warning rather than failing the whole run.
# ----------------------------------------------------------------------

@dataclass
class Query:
    category: str           # which kind of book this represents
    label: str              # human-readable description
    # Either a known-good Gutenberg ID (preferred for determinism)
    # or search terms for the Gutendex /books endpoint.
    book_id: Optional[int] = None
    search: Optional[str] = None
    languages: str = "en"


CURATED: List[Query] = [
    # --- Simple prose ----------------------------------------------------
    Query("prose", "American 19th-c. realism (Twain)",       book_id=76),       # Adventures of Huckleberry Finn
    Query("prose", "Brontë (Wuthering Heights)",             book_id=768),
    Query("prose", "Dickens (A Tale of Two Cities)",         book_id=98),
    Query("prose", "Austen (Pride and Prejudice)",           book_id=1342),
    Query("prose", "Hemingway short / minimalist style",     search="hemingway in our time"),

    # --- Structured non-fiction -----------------------------------------
    Query("nonfiction", "Darwin (Origin of Species)",        book_id=1228),
    Query("nonfiction", "Smith (Wealth of Nations)",         book_id=3300),
    Query("nonfiction", "Mill (On Liberty)",                 book_id=34901),
    Query("nonfiction", "Thoreau (Walden)",                  book_id=205),
    Query("nonfiction", "James (Varieties of Religious Experience)", book_id=621),

    # --- Poetry ----------------------------------------------------------
    Query("poetry", "Whitman (Leaves of Grass)",             book_id=1322),
    Query("poetry", "Shakespeare (Sonnets)",                 book_id=1041),
    Query("poetry", "Dickinson (collected)",                 book_id=12242),
    Query("poetry", "Eliot (The Waste Land)",                search="t s eliot waste land"),

    # --- Drama -----------------------------------------------------------
    Query("drama", "Shakespeare (Hamlet)",                   book_id=1524),
    Query("drama", "Shaw (Pygmalion)",                       book_id=3825),

    # --- Technical / philosophical (dense, footnoted) -------------------
    Query("technical", "Euclid (Elements)",                  book_id=21076),
    Query("technical", "Plato (The Republic)",               book_id=1497),
    Query("technical", "Kant (Critique of Pure Reason)",     book_id=4280),

    # --- Illustrated / children's (likely has images) -------------------
    Query("illustrated", "Carroll (Alice in Wonderland)",    book_id=11),
    Query("illustrated", "Barrie (Peter Pan)",               book_id=16),
    Query("illustrated", "Grahame (The Wind in the Willows)", book_id=27827),

    # --- Short stories ---------------------------------------------------
    Query("shortstories", "Poe (collected)",                 book_id=2147),
    Query("shortstories", "Chekhov (selected)",              search="chekhov stories"),

    # --- Other languages (catches encoding & script edge cases) ---------
    Query("multilang", "French — Hugo (Les Misérables)",     book_id=17489, languages="fr"),
    Query("multilang", "German — Goethe (Faust)",            book_id=21000, languages="de"),

    # --- Long & dense (stress test) -------------------------------------
    Query("longform", "Tolstoy (War and Peace)",             book_id=2600),
    Query("longform", "Melville (Moby Dick)",                book_id=2701),
]


# ----------------------------------------------------------------------
# Networking
# ----------------------------------------------------------------------

def _http_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def _json_get(url: str) -> dict:
    return json.loads(_http_get(url))


def _gutendex_search(search: str, languages: str) -> Optional[dict]:
    qs = urllib.parse.urlencode({"search": search, "languages": languages})
    url = f"{GUTENDEX_BASE}?{qs}"
    try:
        results = _json_get(url).get("results", [])
    except Exception as e:
        print(f"  ⚠  Gutendex search '{search}' failed: {e}", file=sys.stderr)
        return None
    return results[0] if results else None


def _gutendex_by_id(book_id: int) -> Optional[dict]:
    try:
        return _json_get(f"{GUTENDEX_BASE}/{book_id}")
    except Exception as e:
        print(f"  ⚠  Gutendex /books/{book_id} failed: {e}", file=sys.stderr)
        return None


def _pick_epub_url(book: dict) -> Optional[str]:
    """Prefer EPUB images, then EPUB no-images, then plain text. Skip
    formats with charset suffixes that aren't easy to handle (e.g.
    'application/x-mobipocket-ebook')."""
    fmts = book.get("formats", {}) or {}
    # Most-preferred first.
    for key in [
        "application/epub+zip",
        "application/epub+zip; charset=utf-8",
    ]:
        if key in fmts and not fmts[key].endswith(".images"):
            # Skip the .images variant only when a non-.images is also present.
            return fmts[key]
    for key, url in fmts.items():
        if key.startswith("application/epub"):
            return url
    return None


def _pick_text_fallback(book: dict) -> Optional[str]:
    fmts = book.get("formats", {}) or {}
    for key in [
        "text/plain; charset=utf-8",
        "text/plain; charset=us-ascii",
        "text/plain",
    ]:
        if key in fmts:
            return fmts[key]
    return None


# ----------------------------------------------------------------------
# Per-query fetch
# ----------------------------------------------------------------------

@dataclass
class Fetched:
    category: str
    label: str
    book_id: int
    title: str
    authors: List[str]
    languages: List[str]
    download_count: int
    subjects: List[str]
    source_url: str
    saved_to: str
    format: str            # "epub" or "txt"


def _resolve_query(q: Query) -> Optional[dict]:
    if q.book_id is not None:
        return _gutendex_by_id(q.book_id)
    if q.search:
        return _gutendex_search(q.search, q.languages)
    return None


def _author_names(book: dict) -> List[str]:
    return [a.get("name", "?") for a in (book.get("authors") or [])]


def _slug(s: str, max_len: int = 60) -> str:
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in s)
    return safe[:max_len].strip("_") or "untitled"


def fetch_one(q: Query, output: Path, refresh: bool) -> Optional[Fetched]:
    book = _resolve_query(q)
    if not book:
        print(f"  ✗  {q.category:14}  {q.label}  (not found)")
        return None

    book_id = book["id"]
    title = book.get("title", "(untitled)")
    epub_url = _pick_epub_url(book)
    text_url = _pick_text_fallback(book)

    if not epub_url and not text_url:
        print(f"  ✗  {q.category:14}  {q.label}  (no epub/txt format available)")
        return None

    use_url = epub_url or text_url
    fmt = "epub" if epub_url else "txt"

    sub = output / q.category
    sub.mkdir(parents=True, exist_ok=True)
    name = f"{book_id:05d}_{_slug(title)}.{fmt}"
    target = sub / name

    if target.exists() and not refresh:
        print(f"  •  {q.category:14}  {target.relative_to(output)}  (cached)")
    else:
        try:
            data = _http_get(use_url)
        except Exception as e:
            print(f"  ✗  {q.category:14}  {q.label}  (download failed: {e})")
            return None
        target.write_bytes(data)
        print(f"  ✓  {q.category:14}  {target.relative_to(output)}  ({len(data):,} bytes)")

    return Fetched(
        category=q.category,
        label=q.label,
        book_id=book_id,
        title=title,
        authors=_author_names(book),
        languages=book.get("languages", []) or [],
        download_count=int(book.get("download_count", 0)),
        subjects=book.get("subjects", []) or [],
        source_url=use_url,
        saved_to=str(target.relative_to(output)),
        format=fmt,
    )


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT,
                        help=f"where to save books (default: {DEFAULT_OUTPUT})")
    parser.add_argument("--categories", default="",
                        help="comma-separated subset of categories to fetch (prose,nonfiction,poetry,...). Empty = all.")
    parser.add_argument("--list", action="store_true",
                        help="list curated queries without fetching")
    parser.add_argument("--refresh", action="store_true",
                        help="re-download even if the file is already present")
    args = parser.parse_args(argv)

    cats = {c.strip() for c in args.categories.split(",") if c.strip()}
    queries = [q for q in CURATED if not cats or q.category in cats]

    if args.list:
        by_cat: Dict[str, List[Query]] = {}
        for q in queries:
            by_cat.setdefault(q.category, []).append(q)
        for cat in sorted(by_cat):
            print(f"\n[{cat}] ({len(by_cat[cat])} books)")
            for q in by_cat[cat]:
                if q.book_id is not None:
                    print(f"  #{q.book_id:<6}  {q.label}  ({q.languages})")
                else:
                    print(f"  search   {q.label}  ({q.languages})")
        return 0

    args.output_dir.mkdir(parents=True, exist_ok=True)
    print(f"Fetching {len(queries)} books → {args.output_dir}\n")

    fetched: List[Fetched] = []
    for q in queries:
        result = fetch_one(q, args.output_dir, args.refresh)
        if result:
            fetched.append(result)

    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps([asdict(f) for f in fetched], indent=2, ensure_ascii=False))
    print(f"\nManifest written: {manifest_path}")
    print(f"Fetched {len(fetched)}/{len(queries)} books across {len({f.category for f in fetched})} categories.")
    if len(fetched) < len(queries):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
