#!/usr/bin/env python3
"""
verify_images.py — Posey image-storage verification tool
=========================================================
Fetches stored images from the device via GET_IMAGE, renders the same
PDF pages on macOS using PDFKit via a tiny Swift helper, and compares
both to confirm stored images are correct, non-blank, and right-sized.

USAGE
-----
  python3 tools/verify_images.py <pdf-path> [document-id]

  If document-id is omitted, the tool looks up the document by filename.

REQUIRES
--------
  - Posey running with the API enabled (same config as posey_test.py)
  - The PDF file accessible on this Mac (for reference rendering)
  - swift available in PATH (ships with Xcode command-line tools)

EXIT CODES
----------
  0  — all images pass
  1  — one or more images failed verification or could not be fetched
"""

import os
import sys
import json
import base64
import http.client
import re
import subprocess
import tempfile

# ─── Config (shared with posey_test.py) ────────────────────────────────────

_SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
_CONFIG_FILE = os.path.join(_SCRIPT_DIR, ".posey_api_config.json")

def _load_config() -> dict | None:
    if os.path.exists(_CONFIG_FILE):
        try:
            with open(_CONFIG_FILE) as f:
                return json.load(f)
        except Exception as e:
            print(f"ERROR: Could not read config: {e}")
    return None

_cfg = _load_config()

def _http(method: str, path: str, body: bytes | None = None,
          extra_headers: dict | None = None, timeout: int = 60) -> tuple[int, dict | str]:
    if not _cfg:
        print("No config. Run: python3 tools/posey_test.py setup <ip> <port> <token>")
        sys.exit(1)
    conn = http.client.HTTPConnection(_cfg["host"], _cfg["port"], timeout=timeout)
    hdrs = {"Authorization": f"Bearer {_cfg['token']}"}
    if extra_headers:
        hdrs.update(extra_headers)
    if body is not None:
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

# ─── Swift PDF renderer ────────────────────────────────────────────────────

_SWIFT_RENDERER = r"""
import Foundation
import PDFKit
import AppKit

// Usage: swift render_page.swift <pdf_path> <page_number_1based> <output_png_path>
// Renders the page at 2x scale (matching Posey's renderPageToPNG).

let args = CommandLine.arguments
guard args.count == 4,
      let pageNum = Int(args[2]), pageNum >= 1 else {
    fputs("Usage: render_page.swift <pdf> <page> <out.png>\n", stderr)
    exit(1)
}

let pdfURL  = URL(fileURLWithPath: args[1])
let outPath = args[3]

guard let doc = PDFDocument(url: pdfURL) else {
    fputs("ERROR: Could not open PDF\n", stderr)
    exit(2)
}

guard let page = doc.page(at: pageNum - 1) else {
    fputs("ERROR: Page \(pageNum) not found (doc has \(doc.pageCount) pages)\n", stderr)
    exit(3)
}

let scale: CGFloat = 2.0
let bounds = page.bounds(for: .mediaBox)
let size   = CGSize(width: bounds.width * scale, height: bounds.height * scale)
let image  = page.thumbnail(of: size, for: .mediaBox)

guard let tiff = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiff),
      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fputs("ERROR: Could not encode PNG\n", stderr)
    exit(4)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("OK \(Int(size.width))x\(Int(size.height)) \(pngData.count)")
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(5)
}
"""

def render_pdf_page(pdf_path: str, page_number: int, out_path: str) -> dict | None:
    """
    Render `page_number` (1-based) of `pdf_path` to PNG at 2× scale using
    the same PDFPage.thumbnail call Posey uses. Returns dict with keys
    `width`, `height`, `byte_count`, or None on failure.
    """
    swift_src = os.path.join(tempfile.gettempdir(), "posey_render_page.swift")
    with open(swift_src, "w") as f:
        f.write(_SWIFT_RENDERER)

    try:
        result = subprocess.run(
            ["swift", swift_src, pdf_path, str(page_number), out_path],
            capture_output=True, text=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT rendering page {page_number}")
        return None

    if result.returncode != 0:
        print(f"  Swift renderer failed (exit {result.returncode}): {result.stderr.strip()}")
        return None

    # Output line: "OK <width>x<height> <byte_count>"
    m = re.match(r"OK (\d+)x(\d+) (\d+)", result.stdout.strip())
    if not m:
        print(f"  Unexpected renderer output: {result.stdout.strip()}")
        return None

    return {"width": int(m.group(1)), "height": int(m.group(2)), "byte_count": int(m.group(3))}

# ─── Image comparison ──────────────────────────────────────────────────────

def _is_blank_png(png_bytes: bytes, threshold: float = 0.98) -> bool:
    """
    Returns True if >threshold fraction of pixels are white (or near-white).
    Only checks the first 4096 bytes of pixel data for speed.
    Works on raw PNG bytes — parses IDAT via a tiny uncompressed heuristic:
    uses zlib to decompress the first IDAT chunk.
    Falls back to False (assume non-blank) if parsing fails.
    """
    import struct, zlib

    if len(png_bytes) < 8:
        return False

    # Locate and decompress first IDAT chunk.
    pos = 8  # skip PNG signature
    idat_data = b""
    while pos + 12 <= len(png_bytes):
        length = struct.unpack(">I", png_bytes[pos:pos+4])[0]
        chunk_type = png_bytes[pos+4:pos+8]
        data = png_bytes[pos+8:pos+8+length]
        pos += 12 + length
        if chunk_type == b"IDAT":
            idat_data += data
            break  # first chunk is enough

    if not idat_data:
        return False

    try:
        raw = zlib.decompress(idat_data)
    except Exception:
        return False

    # Count bytes close to 255 (white). PNG pixel data has a filter byte per row.
    sample = raw[:4096]
    white  = sum(1 for b in sample if b >= 240)
    return white / max(len(sample), 1) >= threshold

def compare_images(stored_png: bytes, ref_png_path: str) -> dict:
    """
    Compare stored PNG against reference. Returns a report dict:
      passed    — bool
      checks    — list of {name, result, detail}
    """
    checks = []

    # 1. Non-trivial size
    size_ok = len(stored_png) > 5_000
    checks.append({"name": "stored_non_trivial_size",
                   "result": "PASS" if size_ok else "FAIL",
                   "detail": f"{len(stored_png)} bytes"})

    # 2. Valid PNG header
    png_sig = b"\x89PNG\r\n\x1a\n"
    sig_ok = stored_png[:8] == png_sig
    checks.append({"name": "stored_valid_png_header",
                   "result": "PASS" if sig_ok else "FAIL",
                   "detail": stored_png[:8].hex()})

    # 3. Not blank
    blank = _is_blank_png(stored_png)
    checks.append({"name": "stored_not_blank",
                   "result": "FAIL" if blank else "PASS",
                   "detail": "all-white" if blank else "has content"})

    # 4. Reference rendered successfully
    if not os.path.exists(ref_png_path):
        checks.append({"name": "reference_render", "result": "FAIL",
                       "detail": "reference file missing"})
        return {"passed": False, "checks": checks}

    with open(ref_png_path, "rb") as f:
        ref_png = f.read()

    ref_ok = len(ref_png) > 5_000
    checks.append({"name": "reference_non_trivial_size",
                   "result": "PASS" if ref_ok else "FAIL",
                   "detail": f"{len(ref_png)} bytes"})

    ref_blank = _is_blank_png(ref_png)
    checks.append({"name": "reference_not_blank",
                   "result": "FAIL" if ref_blank else "PASS",
                   "detail": "all-white" if ref_blank else "has content"})

    # 5. Dimension match via PNG IHDR (bytes 16-24)
    import struct
    def _png_dims(data: bytes) -> tuple[int, int] | None:
        if len(data) < 24: return None
        try:
            w = struct.unpack(">I", data[16:20])[0]
            h = struct.unpack(">I", data[20:24])[0]
            return w, h
        except Exception:
            return None

    stored_dims = _png_dims(stored_png)
    ref_dims    = _png_dims(ref_png)
    dim_ok = stored_dims is not None and stored_dims == ref_dims
    checks.append({"name": "dimensions_match",
                   "result": "PASS" if dim_ok else "FAIL",
                   "detail": f"stored={stored_dims} ref={ref_dims}"})

    # 6. Size ratio within 2× (same content at same scale should be close)
    if len(ref_png) > 0:
        ratio = len(stored_png) / len(ref_png)
        ratio_ok = 0.5 <= ratio <= 2.0
        checks.append({"name": "size_ratio_reasonable",
                       "result": "PASS" if ratio_ok else "WARN",
                       "detail": f"ratio={ratio:.2f}"})

    passed = all(c["result"] == "PASS" for c in checks)
    return {"passed": passed, "checks": checks}

# ─── Main verification flow ────────────────────────────────────────────────

def verify(pdf_path: str, doc_id: str | None = None) -> int:
    """
    Returns 0 if all images pass, 1 if any fail.
    """
    if not os.path.exists(pdf_path):
        print(f"ERROR: PDF not found: {pdf_path}")
        return 1

    pdf_name = os.path.basename(pdf_path)
    print(f"\nVerifying images for: {pdf_name}")
    print("=" * 60)

    # Find document
    if doc_id is None:
        docs_result = _command("LIST_DOCUMENTS")
        docs = docs_result if isinstance(docs_result, list) else docs_result.get("documents", [])
        # Attempt fuzzy match on title or filename
        base = os.path.splitext(pdf_name)[0].lower()
        matched = [d for d in docs if base in d.get("title", "").lower()]
        if not matched:
            print(f"ERROR: No document matching '{base}'. Import it first, then pass its ID.")
            print("Imported documents:")
            for d in docs:
                print(f"  {d['id']}  {d['title']}  [{d['fileType']}]")
            return 1
        doc_id = matched[0]["id"]
        print(f"  Found document: {matched[0]['title']} ({doc_id})")

    # Get displayText to extract visual-page markers
    text_result = _command(f"GET_TEXT:{doc_id}")
    if "error" in text_result:
        print(f"ERROR: {text_result}")
        return 1

    display_text = text_result.get("displayText", "")
    # Extract markers: [[POSEY_VISUAL_PAGE:<page>:<uuid>]]
    marker_re = re.compile(r'\[\[POSEY_VISUAL_PAGE:(\d+):([^\]]+)\]\]')
    markers = marker_re.findall(display_text)

    if not markers:
        print("  No visual-page markers found in this document.")
        return 0

    print(f"  Found {len(markers)} visual-page marker(s).")
    print()

    all_passed = True
    tmpdir = tempfile.mkdtemp(prefix="posey_verify_")

    try:
        for page_str, image_id in markers:
            page_num = int(page_str)
            print(f"  Page {page_num}  imageID={image_id[:8]}...")

            # Fetch stored image
            img_result = _command(f"GET_IMAGE:{image_id}")
            if "error" in img_result:
                print(f"    FAIL — GET_IMAGE error: {img_result['error']}")
                all_passed = False
                continue

            b64 = img_result.get("base64", "")
            if not b64:
                print(f"    FAIL — empty base64 in response")
                all_passed = False
                continue

            stored_png = base64.b64decode(b64)
            stored_byte_count = img_result.get("byteCount", len(stored_png))

            # Render reference PNG from the local PDF
            ref_path = os.path.join(tmpdir, f"ref_page_{page_num}.png")
            render_info = render_pdf_page(pdf_path, page_num, ref_path)
            if render_info is None:
                print(f"    WARN — Could not render reference page {page_num}; skipping comparison")
                # Still check the stored image on its own
                size_ok = stored_byte_count > 5_000
                sig_ok  = stored_png[:8] == b"\x89PNG\r\n\x1a\n"
                blank   = _is_blank_png(stored_png)
                status  = "PASS" if (size_ok and sig_ok and not blank) else "FAIL"
                all_passed = all_passed and (status == "PASS")
                print(f"    {status}  (standalone)  size={stored_byte_count}  sig={'ok' if sig_ok else 'BAD'}  blank={'yes' if blank else 'no'}")
                continue

            report = compare_images(stored_png, ref_path)
            status_str = "PASS" if report["passed"] else "FAIL"
            if not report["passed"]:
                all_passed = False

            print(f"    {status_str}  stored={stored_byte_count}B  ref={render_info['byte_count']}B  {render_info['width']}x{render_info['height']}")
            for chk in report["checks"]:
                icon = "✓" if chk["result"] == "PASS" else ("⚠" if chk["result"] == "WARN" else "✗")
                print(f"      {icon}  {chk['name']}: {chk['detail']}")
            print()
    finally:
        # Clean up temp renders
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("=" * 60)
    print(f"Result: {'ALL PASS' if all_passed else 'SOME FAILED'}")
    return 0 if all_passed else 1


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    pdf_path = args[0]
    doc_id   = args[1] if len(args) > 1 else None
    sys.exit(verify(pdf_path, doc_id))


if __name__ == "__main__":
    main()
