#!/usr/bin/env python3
"""
verify_images.py — Posey image-storage verification tool
=========================================================
Fetches stored images from the device via GET_IMAGE, renders the same
PDF pages on macOS using PDFKit via a tiny Swift helper, then does a
real pixel-level comparison to confirm stored images contain the correct
visual content — not just that they are the right size or non-blank.

Pixel comparison:
  A second Swift helper draws both PNGs into identical RGBA bitmaps and
  computes mean absolute error (MAE) per channel across all pixels.
  MAE < 15.0 (out of 255) passes — this allows for minor rendering
  differences between iOS and macOS CoreGraphics while catching images
  that are wrong, corrupted, or from the wrong page.

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
  0  — all images pass pixel comparison
  1  — one or more images failed or could not be compared
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
# Renders one PDF page to PNG using the same PDFPage.thumbnail call Posey uses.

_SWIFT_RENDERER = r"""
import Foundation
import PDFKit
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let pageNum = Int(args[2]), pageNum >= 1 else {
    fputs("Usage: render_page.swift <pdf> <page> <out.png>\n", stderr); exit(1)
}
guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    fputs("ERROR: Could not open PDF\n", stderr); exit(2)
}
guard let page = doc.page(at: pageNum - 1) else {
    fputs("ERROR: Page \(pageNum) not found (doc has \(doc.pageCount) pages)\n", stderr); exit(3)
}
let scale: CGFloat = 2.0
let bounds = page.bounds(for: .mediaBox)
let size   = CGSize(width: bounds.width * scale, height: bounds.height * scale)
let image  = page.thumbnail(of: size, for: .mediaBox)
guard let tiff = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiff),
      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fputs("ERROR: Could not encode PNG\n", stderr); exit(4)
}
do {
    try pngData.write(to: URL(fileURLWithPath: args[3]))
    print("OK \(Int(size.width))x\(Int(size.height)) \(pngData.count)")
} catch { fputs("ERROR: \(error)\n", stderr); exit(5) }
"""

# ─── Swift pixel comparator ────────────────────────────────────────────────
# Loads two PNG files into identical-sized RGBA bitmaps via CoreGraphics and
# computes mean absolute error per channel. Output: "MAE <value> <w>x<h>"
# MAE is averaged across all pixels and all 4 RGBA channels (0.0 – 255.0).

_SWIFT_PIXEL_COMPARE = r"""
import Foundation
import AppKit
import CoreGraphics

func loadRGBA(path: String, targetW: Int, targetH: Int) -> [UInt8]? {
    guard let img = NSImage(contentsOfFile: path),
          let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }
    var pixels = [UInt8](repeating: 0, count: targetW * targetH * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &pixels,
                        width: targetW, height: targetH,
                        bitsPerComponent: 8, bytesPerRow: targetW * 4,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(cgImg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
    return pixels
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: pixel_compare.swift <img_a.png> <img_b.png>\n", stderr); exit(1)
}

// Determine target size from image A.
guard let imgA = NSImage(contentsOfFile: args[1]) else {
    fputs("ERROR: Cannot open \(args[1])\n", stderr); exit(2)
}
guard let imgB = NSImage(contentsOfFile: args[2]) else {
    fputs("ERROR: Cannot open \(args[2])\n", stderr); exit(3)
}

// Use image A's pixel dimensions as the canonical size; scale B to match.
let wA = Int(imgA.size.width)
let hA = Int(imgA.size.height)
guard wA > 0 && hA > 0 else {
    fputs("ERROR: Zero-size image A\n", stderr); exit(4)
}

guard let pixA = loadRGBA(path: args[1], targetW: wA, targetH: hA),
      let pixB = loadRGBA(path: args[2], targetW: wA, targetH: hA) else {
    fputs("ERROR: Could not decode pixel data\n", stderr); exit(5)
}

var totalDiff: Int64 = 0
for i in 0 ..< pixA.count {
    totalDiff += Int64(abs(Int(pixA[i]) - Int(pixB[i])))
}
let mae = Double(totalDiff) / Double(pixA.count)
print(String(format: "MAE %.4f %dx%d", mae, wA, hA))
"""

# ─── Runner helpers ────────────────────────────────────────────────────────

def _write_swift(src: str, name: str) -> str:
    path = os.path.join(tempfile.gettempdir(), name)
    with open(path, "w") as f:
        f.write(src)
    return path

def render_pdf_page(pdf_path: str, page_number: int, out_path: str) -> dict | None:
    script = _write_swift(_SWIFT_RENDERER, "posey_render_page.swift")
    try:
        r = subprocess.run(["swift", script, pdf_path, str(page_number), out_path],
                           capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print(f"    TIMEOUT rendering page {page_number}")
        return None
    if r.returncode != 0:
        print(f"    Swift renderer error (exit {r.returncode}): {r.stderr.strip()}")
        return None
    m = re.match(r"OK (\d+)x(\d+) (\d+)", r.stdout.strip())
    if not m:
        print(f"    Unexpected renderer output: {r.stdout.strip()}")
        return None
    return {"width": int(m.group(1)), "height": int(m.group(2)), "byte_count": int(m.group(3))}

# MAE threshold: allow minor rendering differences between iOS and macOS
# CoreGraphics (sub-pixel anti-aliasing, colour profile, gamma). A threshold
# of 15.0/255 ≈ 6% is generous enough for those but tight enough to catch
# a wrong page, a solid colour fill, or corrupted data.
_MAE_PASS_THRESHOLD = 15.0

def pixel_compare(stored_png_path: str, ref_png_path: str) -> dict | None:
    """
    Runs the Swift pixel comparator on two PNG files.
    Returns {"mae": float, "width": int, "height": int} or None on failure.
    """
    script = _write_swift(_SWIFT_PIXEL_COMPARE, "posey_pixel_compare.swift")
    try:
        r = subprocess.run(["swift", script, stored_png_path, ref_png_path],
                           capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print("    TIMEOUT running pixel comparator")
        return None
    if r.returncode != 0:
        print(f"    Pixel comparator error (exit {r.returncode}): {r.stderr.strip()}")
        return None
    m = re.match(r"MAE ([\d.]+) (\d+)x(\d+)", r.stdout.strip())
    if not m:
        print(f"    Unexpected comparator output: {r.stdout.strip()}")
        return None
    return {"mae": float(m.group(1)), "width": int(m.group(2)), "height": int(m.group(3))}

# ─── Main verification flow ────────────────────────────────────────────────

def verify(pdf_path: str, doc_id: str | None = None) -> int:
    if not os.path.exists(pdf_path):
        print(f"ERROR: PDF not found: {pdf_path}")
        return 1

    pdf_name = os.path.basename(pdf_path)
    print(f"\nVerifying images for: {pdf_name}")
    print("=" * 60)

    # Find document
    if doc_id is None:
        docs_result = _command("LIST_DOCUMENTS")
        raw = docs_result if isinstance(docs_result, list) else docs_result.get("raw", [])
        docs = raw if isinstance(raw, list) else []
        base = os.path.splitext(pdf_name)[0].lower()
        matched = [d for d in docs if base in d.get("title", "").lower()]
        if not matched:
            print(f"ERROR: No document matching '{base}'.")
            for d in docs:
                print(f"  {d['id']}  {d['title']}  [{d['fileType']}]")
            return 1
        doc_id = matched[0]["id"]
        print(f"  Found document: {matched[0]['title']} ({doc_id})")

    # Extract visual-page markers from displayText
    text_result = _command(f"GET_TEXT:{doc_id}")
    if "error" in text_result:
        print(f"ERROR: {text_result}")
        return 1
    display_text = text_result.get("displayText", "")
    markers = re.findall(r'\[\[POSEY_VISUAL_PAGE:(\d+):([^\]]+)\]\]', display_text)

    if not markers:
        print("  No visual-page markers found.")
        return 0

    print(f"  Found {len(markers)} visual-page marker(s).")
    print(f"  Pass threshold: MAE < {_MAE_PASS_THRESHOLD:.1f}/255\n")

    all_passed = True
    tmpdir = tempfile.mkdtemp(prefix="posey_verify_")

    try:
        for page_str, image_id in markers:
            page_num = int(page_str)
            print(f"  Page {page_num}  imageID={image_id[:8]}...")

            # 1. Fetch stored image from device
            img_result = _command(f"GET_IMAGE:{image_id}")
            if "error" in img_result:
                print(f"    FAIL — GET_IMAGE: {img_result['error']}")
                all_passed = False
                continue

            b64 = img_result.get("base64", "")
            if not b64:
                print(f"    FAIL — empty base64")
                all_passed = False
                continue

            stored_png = base64.b64decode(b64)

            # Validate PNG signature before writing
            if stored_png[:8] != b"\x89PNG\r\n\x1a\n":
                print(f"    FAIL — not a valid PNG (header: {stored_png[:8].hex()})")
                all_passed = False
                continue

            stored_path = os.path.join(tmpdir, f"stored_{page_num}.png")
            with open(stored_path, "wb") as f:
                f.write(stored_png)

            # 2. Render reference from the local PDF
            ref_path = os.path.join(tmpdir, f"ref_{page_num}.png")
            render_info = render_pdf_page(pdf_path, page_num, ref_path)
            if render_info is None:
                print(f"    FAIL — reference render failed; cannot compare")
                all_passed = False
                continue

            # 3. Pixel-level comparison
            cmp = pixel_compare(stored_path, ref_path)
            if cmp is None:
                print(f"    FAIL — pixel comparison did not complete")
                all_passed = False
                continue

            mae   = cmp["mae"]
            passed = mae < _MAE_PASS_THRESHOLD
            label  = "PASS" if passed else "FAIL"
            if not passed:
                all_passed = False

            print(f"    {label}  MAE={mae:.2f}/255  {cmp['width']}x{cmp['height']}  "
                  f"stored={len(stored_png)}B  ref={render_info['byte_count']}B")

    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

    print()
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
