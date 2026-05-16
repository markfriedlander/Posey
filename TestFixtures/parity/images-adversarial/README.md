# Adversarial Image Fixtures (B9b)

Built 2026-05-16 by `tools/generate_adversarial_images.py`. Each file
exercises an importer edge case that real-world content rarely hits
cleanly. Wired into `tools/verify_image_corpus.py --adversarial` so
future commits get caught if any of these crash the importer.

## Files

- **`adversarial.html`** — six edge cases in one HTML doc:
  - 1px solid PNG (divide-by-zero / zero-area guard)
  - 1px transparent PNG (alpha=0 single pixel)
  - 64×64 fully transparent PNG (alpha=0 entire canvas)
  - 128×128 transparent-bg with solid foreground square
  - 2048×2048 huge PNG (memory + downscale path)
  - Three consecutive small unique PNGs with no prose between
    (consecutive-images grouping)
- **`adversarial.docx`** — three image cases inside one valid .docx:
  - Image inside a `<w:tbl>` cell (table-embedded path)
  - Three consecutive images at top level
  - Reuses the 1px / transparent / transparent-bg PNGs above

## Regeneration

```
python3 tools/generate_adversarial_images.py
```

The generator only depends on Pillow; no python-docx / lxml. The DOCX
is built as raw ZIP + minimal valid OOXML so the build path is
transparent.

## Pass criteria

Each fixture must import without crashing. Image counts vary, so the
regression treats `must_not_crash=True` rather than asserting exact
counts. Crashes show as either an `import threw:` error or a `success: false`
error response from the importer's API.
