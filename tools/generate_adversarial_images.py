#!/usr/bin/env python3
"""generate_adversarial_images.py — B9b adversarial image-corpus generator.

Builds synthetic image-bearing documents that exercise the importer
edge cases real-world content rarely hits cleanly:

- **1px images**: importers may special-case zero-pixel content or
  divide-by-zero on aspect ratio.
- **Fully transparent images**: PNG with alpha=0 across the canvas;
  visual rendering may skip them or fall back to placeholder.
- **Images embedded inside DOCX tables**: `<w:tbl>` wrapping a
  `<w:drawing>` — different parse path than top-level inline image.
- **Multiple consecutive images with no text between**: stresses the
  display-block runner that pairs images with surrounding text.
- **Image with transparent background**: PNG with alpha channel +
  visible foreground; tests the alpha-composite rendering path.
- **Image larger than common screen dimensions**: e.g. 4096×4096
  — tests the in-memory decode + downscaling path.

Output: `TestFixtures/parity/images-adversarial/` directory with one
file per case. Wired into `tools/verify_image_corpus.py --adversarial`
which imports each and asserts the importer doesn't crash.

Requires Pillow (`pip3 install --user --break-system-packages Pillow`).
"""

import base64
import io
import os
import sys
import struct
import zipfile
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow not installed. Run `pip3 install --user --break-system-packages Pillow`", file=sys.stderr)
    sys.exit(1)

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "TestFixtures" / "parity" / "images-adversarial"
OUT.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Image primitives — each returns PNG bytes.
# ---------------------------------------------------------------------------

def png_1px_solid(color=(0, 200, 0, 255)) -> bytes:
    img = Image.new("RGBA", (1, 1), color)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def png_fully_transparent(w=64, h=64) -> bytes:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def png_transparent_bg_with_fg(w=128, h=128) -> bytes:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    # Draw a centered solid square
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    d.rectangle([w // 4, h // 4, 3 * w // 4, 3 * h // 4],
                fill=(220, 80, 80, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def png_huge(w=2048, h=2048) -> bytes:
    img = Image.new("RGB", (w, h), (200, 200, 220))
    # Diagonal stripe so it's not pure-color (which Posey's importer
    # might special-case as "blank").
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    for i in range(0, w, 40):
        d.line([(i, 0), (i + h, h)], fill=(120, 120, 160), width=2)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# ---------------------------------------------------------------------------
# HTML adversarial: easiest to construct — five edge cases in one file.
# ---------------------------------------------------------------------------

def build_html_adversarial():
    images = {
        "1px-green":           png_1px_solid((0, 200, 0, 255)),
        "1px-red-transparent": png_1px_solid((200, 0, 0, 0)),
        "fully-transparent":   png_fully_transparent(96, 96),
        "transparent-bg-fg":   png_transparent_bg_with_fg(128, 128),
        "huge":                png_huge(2048, 2048),
    }
    parts = ["<!DOCTYPE html><html><head><meta charset='utf-8'>"
             "<title>image-adversarial</title></head><body>",
             "<h1>Adversarial image cases</h1>",
             "<p>Each section below is an edge case for the importer.</p>"]
    for name, data in images.items():
        b64 = base64.b64encode(data).decode("ascii")
        parts.append(f"<h2>{name}</h2>")
        parts.append(f'<p>Description: this is the {name} image case.</p>')
        parts.append(f'<img src="data:image/png;base64,{b64}" alt="{name}">')
    # Section: multiple consecutive images, no text between
    parts.append("<h2>consecutive-images</h2>")
    parts.append("<p>Three consecutive PNGs with no prose between:</p>")
    for color in [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)]:
        # Small unique uniform image so each is a distinct data URI
        img = Image.new("RGBA", (48, 48), color)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        b64 = base64.b64encode(buf.getvalue()).decode("ascii")
        parts.append(f'<img src="data:image/png;base64,{b64}" alt="rgb">')
    parts.append("</body></html>")
    out_path = OUT / "adversarial.html"
    out_path.write_text("\n".join(parts))
    return out_path


# ---------------------------------------------------------------------------
# DOCX adversarial: pure-Python ZIP + XML so we don't need python-docx.
# Builds a minimal valid .docx with images in a table cell + consecutive
# images.
# ---------------------------------------------------------------------------

DOCX_CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>"""

DOCX_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""

DOCX_DOC_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rImg1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/img1.png"/>
  <Relationship Id="rImg2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/img2.png"/>
  <Relationship Id="rImg3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/img3.png"/>
</Relationships>"""


def docx_drawing_xml(rid: str, name: str, cx: int = 914400, cy: int = 914400) -> str:
    """Return the `<w:drawing>` XML block that embeds image `rid`.
    Sizes are in EMUs (914400 = 1 inch)."""
    return f"""<w:drawing>
<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
  <wp:extent cx="{cx}" cy="{cy}"/>
  <wp:docPr id="1" name="{name}"/>
  <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
    <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
      <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <pic:nvPicPr>
          <pic:cNvPr id="1" name="{name}"/>
          <pic:cNvPicPr/>
        </pic:nvPicPr>
        <pic:blipFill>
          <a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="{rid}"/>
          <a:stretch><a:fillRect/></a:stretch>
        </pic:blipFill>
        <pic:spPr>
          <a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>
          <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        </pic:spPr>
      </pic:pic>
    </a:graphicData>
  </a:graphic>
</wp:inline>
</w:drawing>"""


def build_docx_adversarial():
    """Single .docx with: image-inside-table-cell, three consecutive
    images at top level, and 1px / transparent image edge cases."""
    paragraphs = []
    paragraphs.append('<w:p><w:r><w:t>Adversarial DOCX image cases.</w:t></w:r></w:p>')

    # Table containing an image in a cell
    paragraphs.append("""<w:tbl>
<w:tblPr><w:tblStyle w:val="TableGrid"/></w:tblPr>
<w:tr><w:tc>
  <w:p><w:r><w:t>Table cell with image:</w:t></w:r></w:p>
</w:tc><w:tc>
  <w:p><w:r>""" + docx_drawing_xml("rImg1", "tableImg") + """</w:r></w:p>
</w:tc></w:tr>
</w:tbl>""")

    paragraphs.append('<w:p><w:r><w:t>Three consecutive images:</w:t></w:r></w:p>')
    # Three drawings in three successive paragraphs, no text between
    for rid, name in [("rImg2", "consec1"), ("rImg3", "consec2"), ("rImg1", "consec3reused")]:
        paragraphs.append(f'<w:p><w:r>{docx_drawing_xml(rid, name)}</w:r></w:p>')

    paragraphs.append('<w:p><w:r><w:t>End of adversarial section.</w:t></w:r></w:p>')

    document_xml = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
{''.join(paragraphs)}
<w:sectPr/>
</w:body>
</w:document>"""

    out_path = OUT / "adversarial.docx"
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", DOCX_CONTENT_TYPES)
        zf.writestr("_rels/.rels", DOCX_RELS)
        zf.writestr("word/_rels/document.xml.rels", DOCX_DOC_RELS)
        zf.writestr("word/document.xml", document_xml)
        zf.writestr("word/media/img1.png", png_1px_solid((255, 100, 100, 255)))
        zf.writestr("word/media/img2.png", png_fully_transparent(64, 64))
        zf.writestr("word/media/img3.png", png_transparent_bg_with_fg(128, 128))
    return out_path


# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

def main():
    html_path = build_html_adversarial()
    print(f"wrote {html_path}")
    docx_path = build_docx_adversarial()
    print(f"wrote {docx_path}")
    print(f"\nadversarial corpus ready at {OUT}")


if __name__ == "__main__":
    main()
