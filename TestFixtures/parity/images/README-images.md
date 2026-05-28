# Image-Bearing Test Fixtures

Built 2026-05-12 during the pre-submission image-support stress sweep. These files exercise the inline-image rendering path across all 4 image-bearing formats — DOCX, HTML, EPUB, PDF — including edge cases (broken image src, consecutive images, varying aspect ratios, real photographic data vs synthetic uniform-color blocks).

## Files

### Synthetic-image fixtures (uniform-color PNGs)
- `image-stress.docx` — 5 synthetic PNGs across 6 sections. Edge cases: small icon (32×32), medium figure, large block, consecutive images (Section 4), aspect-ratio test (Section 5 wide + tall reused).
- `image-stress.html` — 5 synthetic data-URI images + 1 deliberately broken `<img src="nonexistent://...">` for crash-safety verification. The importer must skip the broken src and continue parsing the rest of the doc.
- `small.png`, `medium.png`, `large.png`, `wide.png`, `tall.png` — source images used by the .docx/.html builds. Tiny (97 to 1684 bytes), uniform colors (red/green/blue/yellow/magenta).

### Real-image fixtures (photographic JPEGs)
- `real-image-stress.docx` — 5 real photographic JPEGs from picsum.photos (8KB → 354KB, dimensions 200×100 → 2000×1200). Exercises JPEG decoder, EXIF metadata handling, real photographic gradients, and memory pressure at 354KB single-image.
- `real-image-stress.html` — same 5 JPEGs as base64 data URIs. Tests the data-URI decode path under realistic photo content.

### Illustrated EPUB
- `illustrated.epub` — Project Gutenberg's illustrated edition (originally PG ID 19033, ~71K chars, 55 figures). Real chapter-mid Tenniel illustrations (not just a cover), so this catches regressions on the "inline figure at the exact text reference point" rendering path.

## What these fixtures verify

| Verification | Fixture |
|---|---|
| DOCX visualPlaceholder generation | image-stress.docx |
| DOCX inline-image rendering | image-stress.docx + real-image-stress.docx |
| DOCX consecutive-image handling | image-stress.docx (Section 4) |
| DOCX large-image memory handling | real-image-stress.docx (Section 4, 354KB JPEG) |
| HTML visualPlaceholder generation | image-stress.html |
| HTML broken-src crash safety | image-stress.html (Section 5) |
| HTML data-URI decode | image-stress.html (synthetic) + real-image-stress.html (real photos) |
| EPUB chapter-mid figure rendering | illustrated.epub |
| EPUB image extraction at scale | illustrated.epub (55 images) |

PDF image rendering uses the existing `Posey Test Materials/` content (Measure What Matters, Cryptography for Dummies, etc.) — those PDFs are too large to bundle in TestFixtures and are external test material.

## How to use

Manual: import any of these via the Library "Import File" button. Inspect with the `LIST_IMAGES:<docID>` antenna verb to confirm extraction counts. Use `LIST_DISPLAY_BLOCKS_MATCHING:.*` to find visualPlaceholder offsets, then `READER_GOTO:<docID>:<offset>` + `SCREENSHOT` to confirm inline rendering.

Automated: future qa_battery extension should import each of these, run `LIST_IMAGES`, assert image counts match expectations (5, 5, 55 respectively), and confirm no importer crashes on the broken-src HTML.
