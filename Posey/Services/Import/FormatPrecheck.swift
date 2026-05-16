import Foundation

// ========== BLOCK 01: ERRORS - START ==========
/// Errors thrown by the format prechecks. The user-facing strings are
/// in Posey's voice — friendly, plain, no internal terminology, no
/// hints about magic bytes. Each one tells the user what Posey
/// detected and what to do next.
public enum FormatPrecheckError: LocalizedError, Sendable {
    /// File is empty (0 bytes).
    case empty(declaredType: String)
    /// File is too small to be a valid document of the declared type.
    case tooSmall(declaredType: String)
    /// File's bytes look like a different known format than its
    /// extension declared (e.g. `.epub` whose bytes are `%PDF-`).
    /// `detectedType` is something users will recognize ("a PDF",
    /// "a Word file", "a ZIP archive", "an image", etc.).
    case wrongFormat(declaredType: String, detectedType: String)
    /// File doesn't look like the declared type and we can't pin down
    /// what it actually is. The catch-all rejection — saves us from
    /// dragging unknown binary content into SQLite.
    case unrecognized(declaredType: String)

    public var errorDescription: String? {
        switch self {
        case .empty(let t):
            return "That \(t.uppercased()) file is empty — there's nothing for Posey to read."
        case .tooSmall(let t):
            return "That file is too small to be a real \(t.uppercased()) document. Try re-saving and importing again."
        case .wrongFormat(let declared, let detected):
            return "That file is named like a \(declared.uppercased()) but looks like \(detected). Rename it or save it as a \(declared.uppercased()) and try again."
        case .unrecognized(let t):
            return "Posey couldn't read that file as \(t.uppercased()) — the contents don't look right. It may be damaged, encrypted, or a different format."
        }
    }
}
// ========== BLOCK 01: ERRORS - END ==========


// ========== BLOCK 02: PRECHECK - START ==========
/// Magic-byte / shape gate for every importer. Each format's precheck
/// runs BEFORE the importer touches the bytes, so a misnamed file is
/// rejected at the door with nothing written to SQLite. Reads only
/// the first 4096 bytes — magic signatures live in the first few
/// bytes of every format Posey supports.
///
/// **Design intent.** This is not a strict format validator. It's
/// a "does this look like the right kind of file" gate that catches
/// the most common user mistake: dragging in a file with the wrong
/// extension. Real parser failures are handled downstream by each
/// importer in its own error path.
public enum FormatPrecheck {

    /// Reads up to `maxBytes` from `url` once. Tiny by intent —
    /// magic-byte detection doesn't need the whole file.
    private static func head(of url: URL, maxBytes: Int = 4096) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return fh.readData(ofLength: maxBytes)
    }

    /// True when the bytes start with the given signature.
    private static func hasPrefix(_ data: Data, _ sig: [UInt8]) -> Bool {
        guard data.count >= sig.count else { return false }
        for (i, byte) in sig.enumerated() where data[data.startIndex + i] != byte {
            return false
        }
        return true
    }

    // MARK: - Known signatures
    private static let sigPDF:  [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D] // %PDF-
    private static let sigZIP:  [UInt8] = [0x50, 0x4B, 0x03, 0x04]       // PK\x03\x04
    private static let sigZIP2: [UInt8] = [0x50, 0x4B, 0x05, 0x06]       // empty archive
    private static let sigRTF:  [UInt8] = [0x7B, 0x5C, 0x72, 0x74, 0x66] // {\rtf
    private static let sigPNG:  [UInt8] = [0x89, 0x50, 0x4E, 0x47]       // \x89PNG
    private static let sigJPEG: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let sigGIF:  [UInt8] = [0x47, 0x49, 0x46, 0x38]       // GIF8

    /// Best-guess label for what a file's bytes actually look like.
    /// Used to enrich `.wrongFormat` errors so the user sees "looks
    /// like a PDF" instead of just "wrong format".
    private static func detect(_ data: Data) -> String {
        if hasPrefix(data, sigPDF)  { return "a PDF" }
        if hasPrefix(data, sigRTF)  { return "an RTF file" }
        if hasPrefix(data, sigPNG)  { return "a PNG image" }
        if hasPrefix(data, sigJPEG) { return "a JPEG image" }
        if hasPrefix(data, sigGIF)  { return "a GIF image" }
        if hasPrefix(data, sigZIP) || hasPrefix(data, sigZIP2) {
            return "a ZIP archive (maybe a DOCX or EPUB)"
        }
        return "something else"
    }

    /// True if the first 4KB look like decodable text — same heuristic
    /// the TXT importer applies. Used for TXT/MD/HTML where there is
    /// no magic byte to gate on; binary content here would crawl
    /// through Latin-1 fallback decoding as garbage.
    private static func looksLikeText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        if data.contains(0x00) { return false }   // NUL → binary
        var nonPrintable = 0
        var total = 0
        for byte in data.prefix(4096) {
            total += 1
            if byte == 0x09 || byte == 0x0A || byte == 0x0D { continue }
            if byte < 0x20 { nonPrintable += 1; continue }
            if byte == 0x7F { nonPrintable += 1 }
        }
        return total == 0 ? true : (Double(nonPrintable) / Double(total)) < 0.15
    }

    // MARK: - Per-format gates

    public static func checkPDF(url: URL) throws {
        let data = try head(of: url)
        if data.isEmpty { throw FormatPrecheckError.empty(declaredType: "pdf") }
        if data.count < 5 { throw FormatPrecheckError.tooSmall(declaredType: "pdf") }
        guard hasPrefix(data, sigPDF) else {
            throw FormatPrecheckError.wrongFormat(declaredType: "pdf",
                                                  detectedType: detect(data))
        }
    }

    public static func checkRTF(url: URL) throws {
        let data = try head(of: url)
        if data.isEmpty { throw FormatPrecheckError.empty(declaredType: "rtf") }
        if data.count < 5 { throw FormatPrecheckError.tooSmall(declaredType: "rtf") }
        guard hasPrefix(data, sigRTF) else {
            throw FormatPrecheckError.wrongFormat(declaredType: "rtf",
                                                  detectedType: detect(data))
        }
    }

    public static func checkDOCX(url: URL) throws {
        let data = try head(of: url)
        if data.isEmpty { throw FormatPrecheckError.empty(declaredType: "docx") }
        if data.count < 4 { throw FormatPrecheckError.tooSmall(declaredType: "docx") }
        // DOCX must be a ZIP. Internal manifest checks happen in the
        // parser; if the bytes aren't even ZIP-shaped, reject early.
        guard hasPrefix(data, sigZIP) || hasPrefix(data, sigZIP2) else {
            throw FormatPrecheckError.wrongFormat(declaredType: "docx",
                                                  detectedType: detect(data))
        }
    }

    public static func checkEPUB(url: URL) throws {
        let data = try head(of: url)
        if data.isEmpty { throw FormatPrecheckError.empty(declaredType: "epub") }
        if data.count < 4 { throw FormatPrecheckError.tooSmall(declaredType: "epub") }
        // EPUB must be a ZIP too. The mimetype file check happens in
        // the parser.
        guard hasPrefix(data, sigZIP) || hasPrefix(data, sigZIP2) else {
            throw FormatPrecheckError.wrongFormat(declaredType: "epub",
                                                  detectedType: detect(data))
        }
    }

    /// Text-shaped formats (TXT / MD / HTML) share a single gate:
    /// reject anything with NUL bytes or > 15% non-printable controls
    /// in the first 4KB. Catches PDF/PNG/ZIP/etc misnamed as text.
    public static func checkTextLike(url: URL, declaredType: String) throws {
        let data = try head(of: url)
        if data.isEmpty { throw FormatPrecheckError.empty(declaredType: declaredType) }
        // Magic-byte fast path — if a known binary signature is at
        // the head, name the actual format in the error.
        if hasPrefix(data, sigPDF) || hasPrefix(data, sigZIP) ||
            hasPrefix(data, sigZIP2) || hasPrefix(data, sigPNG) ||
            hasPrefix(data, sigJPEG) || hasPrefix(data, sigGIF) {
            throw FormatPrecheckError.wrongFormat(declaredType: declaredType,
                                                  detectedType: detect(data))
        }
        guard looksLikeText(data) else {
            throw FormatPrecheckError.unrecognized(declaredType: declaredType)
        }
    }
}
// ========== BLOCK 02: PRECHECK - END ==========
