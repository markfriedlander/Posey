import Foundation

// ========== BLOCK 01: RTF IMAGE EXTRACTOR - START ==========

/// Extracts embedded images from an RTF's `\pict` groups.
///
/// **Why this exists (2026-06-08 foundation-parity pass).** Every other
/// image-bearing format (DOCX/HTML/EPUB/PDF) extracts embedded images into the
/// side-store and renders them; RTF dropped them — `NSAttributedString` (the
/// RTF text path) does NOT surface `\pict` data as a `NSTextAttachment` on
/// iOS, and the raw tokenizer used for heading detection skips `\pict`
/// entirely. This walks the raw RTF, decodes each `\pict` blip, and reports it
/// together with the rendered text that immediately precedes it — a "needle"
/// the importer uses to place a `[[POSEY_VISUAL_PAGE:…]]` marker at the right
/// spot in the cleanly-extracted plainText (the same needle-match technique
/// the importer already uses to anchor headings).
///
/// Supported blips: `\pngblip` (PNG) and `\jpegblip` (JPEG) — the two raster
/// formats `UIImage` can render. Vector blips (`\wmetafile`/`\emfblip`) and
/// `\dibitmap` are skipped (no UIImage decode without extra work; the reader
/// shows a placeholder, matching how SVG is handled in HTML).
enum RTFImageExtractor {

    struct ExtractedImage {
        /// Tail of the rendered text immediately preceding this `\pict`
        /// (up to `needleLength` chars), used to anchor the image marker in
        /// the normalized plainText. Empty when the image leads the document.
        let precedingTextTail: String
        let record: PageImageRecord
    }

    /// Max chars of preceding context captured as the placement needle.
    static let needleLength = 60

    /// Walk the RTF and return every decodable embedded image in document
    /// order, each with its preceding-text needle.
    static func extract(from data: Data) -> [ExtractedImage] {
        // RTF is ASCII with high bytes via \'XX / \uN; ISO-Latin1 is a
        // bijection with the raw bytes so indices stay reliable (same
        // decoding the raw tokenizer uses).
        guard let raw = String(data: data, encoding: .isoLatin1) else { return [] }
        let chars = Array(raw)
        let n = chars.count

        var out: [ExtractedImage] = []
        var rendered = ""          // best-effort rendered text so far (for needles)
        var groupDepth = 0
        var i = 0

        @inline(__always) func renderAppend(_ s: String) {
            rendered += s
            if rendered.count > needleLength * 4 {
                rendered = String(rendered.suffix(needleLength * 2))
            }
        }

        while i < n {
            let c = chars[i]
            if c == "{" { groupDepth += 1; i += 1; continue }
            if c == "}" { groupDepth -= 1; i += 1; continue }
            if c == "\\" {
                i += 1
                if i >= n { break }
                let nc = chars[i]
                if nc == "\\" || nc == "{" || nc == "}" { renderAppend(String(nc)); i += 1; continue }
                if nc == "'" {
                    if i + 2 < n, let v = UInt8(String(chars[(i + 1)...(i + 2)]), radix: 16),
                       let s = String(bytes: [v], encoding: .windowsCP1252) {
                        renderAppend(s); i += 3
                    } else { i += 1 }
                    continue
                }
                if nc.isLetter {
                    var wEnd = i
                    while wEnd < n && chars[wEnd].isLetter { wEnd += 1 }
                    let word = String(chars[i..<wEnd])
                    var pEnd = wEnd
                    if pEnd < n && (chars[pEnd] == "-" || chars[pEnd].isNumber) {
                        if chars[pEnd] == "-" { pEnd += 1 }
                        while pEnd < n && chars[pEnd].isNumber { pEnd += 1 }
                    }
                    if pEnd < n && chars[pEnd] == " " { pEnd += 1 }

                    if word == "pict" {
                        // Capture the needle BEFORE consuming the picture.
                        let needle = String(rendered.suffix(needleLength))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let (image, next) = parsePict(chars, start: pEnd, groupDepth: groupDepth)
                        if let image { out.append(ExtractedImage(precedingTextTail: needle, record: image)) }
                        i = next
                        continue
                    }
                    if word == "par" || word == "sect" || word == "line" { renderAppend("\n") }
                    if word == "tab" { renderAppend("\t") }
                    i = pEnd
                    continue
                }
                // Other escaped control symbol — skip it.
                i += 1
                continue
            }
            renderAppend(String(c))
            i += 1
        }
        return out
    }

    /// Parse a `\pict` group body starting at `start` (just after the `pict`
    /// control word, inside the pict group at `groupDepth`). Returns the
    /// decoded image (nil for unsupported blips / decode failure) and the
    /// index just past the closing `}` of the pict group.
    private static func parsePict(_ chars: [Character], start: Int, groupDepth: Int)
        -> (image: PageImageRecord?, next: Int) {
        let n = chars.count
        var i = start
        var blip: String? = nil          // "png" | "jpg"
        var hex = ""
        var depth = groupDepth           // we're inside the pict group already
        var sawData = false

        while i < n {
            let c = chars[i]
            if c == "{" { depth += 1; i += 1; continue }
            if c == "}" {
                depth -= 1
                i += 1
                if depth < groupDepth { break }  // closed the pict group
                continue
            }
            if c == "\\" {
                i += 1
                if i >= n { break }
                if chars[i].isLetter {
                    var wEnd = i
                    while wEnd < n && chars[wEnd].isLetter { wEnd += 1 }
                    let word = String(chars[i..<wEnd])
                    var pEnd = wEnd
                    if pEnd < n && (chars[pEnd] == "-" || chars[pEnd].isNumber) {
                        if chars[pEnd] == "-" { pEnd += 1 }
                        while pEnd < n && chars[pEnd].isNumber { pEnd += 1 }
                    }
                    if pEnd < n && chars[pEnd] == " " { pEnd += 1 }
                    switch word {
                    case "pngblip": blip = "png"
                    case "jpegblip": blip = "jpg"
                    case "wmetafile", "emfblip", "dibitmap", "pmmetafile", "macpict":
                        blip = blip ?? "unsupported"
                    default: break   // \picw, \pich, \picscalex, \bin handled as no-op here
                    }
                    i = pEnd
                    continue
                }
                i += 1   // escaped symbol inside pict — ignore
                continue
            }
            // Hex data: collect hex digits (whitespace/newlines interleaved).
            if c.isHexDigit { hex.append(c); sawData = true }
            i += 1
        }

        guard let blip, blip == "png" || blip == "jpg", sawData else { return (nil, i) }
        guard let bytes = hexDecode(hex), bytes.count > 16 else { return (nil, i) }
        return (PageImageRecord(imageID: UUID().uuidString, data: bytes), i)
    }

    /// Decode an even-length hex string to bytes. Tolerates an odd trailing
    /// nibble by dropping it. Returns nil if effectively empty.
    private static func hexDecode(_ hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count >= 2 else { return nil }
        var data = Data(capacity: digits.count / 2)
        func val(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        var idx = 0
        while idx + 1 < digits.count {
            guard let hi = val(digits[idx]), let lo = val(digits[idx + 1]) else { return nil }
            data.append((hi << 4) | lo)
            idx += 2
        }
        return data.isEmpty ? nil : data
    }
}

// ========== BLOCK 01: RTF IMAGE EXTRACTOR - END ==========
