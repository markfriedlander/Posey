import XCTest
import PDFKit
@testable import Posey

/// **THE REIMPORT GATE (2026-06-29).** Before the corpus is reimported and
/// embedded, prove each format's importer produces SOUND table-of-contents
/// structure on a REAL document (Rule 7). A bad importer baked into the
/// embeddings = tuning on a contaminated corpus = the trap that stuck us before
/// (you can't tell a bad retrieval result from bad data vs bad tuning).
///
/// Health is measured by IDENTITY — the ruler — not character offsets:
///   • dangling           : a TOC entry whose `unitID` resolves to NO unit (must be 0)
///   • nonHeadingInBody    : a BODY entry (at/after the skip boundary) pointing at a
///                           non-heading unit — an offset→identity drift (must be 0)
///   • nonHeadingInFront   : a FRONT-matter entry on a prose unit (legit, e.g. a
///                           title page <h1> → title-page prose; the reader's
///                           `visibleTOCEntries` hides it) — reported, not failed
///   • textMismatch        : heading text ≠ entry title (reported; soft — some
///                           importers carry a cleaned title)
///
/// Prints a per-format health table to `/tmp/gate_*.txt` so reality is VISIBLE,
/// not guessed (Rule 5). The four well-behaved formats assert clean; the two PDFs
/// are MEASURE-ONLY — book-PDF TOC structure (GEB) is the known-broken deep-dive,
/// so failing an assertion there would just restate what we already know.
@MainActor
final class ImporterGateTests: XCTestCase {

    static let corpusDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PoseyTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Posey Test Materials")

    private func freshDB() throws -> DatabaseManager {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        return try DatabaseManager(databaseURL: dbURL)
    }

    /// Analyze + record TOC identity-health for one imported doc. Writes a diag
    /// line to `/tmp/gate_<format>.txt`. Asserts dangling==0 + nonHeadingInBody==0
    /// when `assertClean` (the formats we expect sound).
    @discardableResult
    private func assess(_ db: DatabaseManager, _ doc: Document,
                        format: String, file: String, assertClean: Bool) throws -> String {
        let units = try db.units(for: doc.id)
        let sentences = (try? db.sentences(for: doc.id)) ?? []
        let toc = try db.tocEntries(for: doc.id)
        let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let refs = try db.unitSkipReferences(for: doc.id)
        let skipSeq = refs.skipUnitID.flatMap { id in units.first(where: { $0.id == id })?.sequence }

        var dangling = 0, nhFront = 0, nhBody = 0, mismatch = 0
        var offenders: [String] = []
        for e in toc {
            guard let u = byID[e.unitID] else {
                dangling += 1; offenders.append("DANGLING '\(e.title.prefix(44))'"); continue
            }
            if u.kind != .heading {
                let inBody = (skipSeq.map { u.sequence >= $0 } ?? true)
                if inBody { nhBody += 1 } else { nhFront += 1 }
                offenders.append("NONHEAD[\(inBody ? "body" : "front")] '\(e.title.prefix(40))' -> \(u.kind) text='\(u.text.prefix(24))'")
            }
            if u.kind == .heading,
               u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                != e.title.trimmingCharacters(in: .whitespacesAndNewlines) {
                mismatch += 1
            }
        }
        var out = "════════ [\(format)] \(file) ════════\n"
        out += "  toc=\(toc.count)  units=\(units.count)  sentences=\(sentences.count)\n"
        out += "  dangling=\(dangling)  nonHeadingInBody=\(nhBody)  nonHeadingInFront=\(nhFront)  textMismatch=\(mismatch)\n"
        for o in offenders.prefix(8) { out += "  • \(o)\n" }
        try? out.write(to: URL(fileURLWithPath: "/tmp/gate_\(format).txt"), atomically: true, encoding: .utf8)
        print(out)

        if assertClean {
            XCTAssertEqual(dangling, 0, "[\(format)] \(file): TOC entry resolves to no unit — \(offenders.prefix(3))")
            XCTAssertEqual(nhBody, 0, "[\(format)] \(file): BODY TOC entry not a heading (offset→identity drift) — \(offenders.prefix(3))")
        }
        return out
    }

    private func src(_ name: String) throws -> URL {
        let u = Self.corpusDir.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path), "corpus file missing: \(name)")
        return u
    }

    /// PDF rebuild (2026-06-29) — DEBUG the CBA TOC anchoring. For each stored
    /// TOC entry, show what its unitID resolved to (kind + sequence + text) and
    /// whether it's sentence-bearing (visible in the navigator). Reveals why the
    /// near-duplicate long legal titles (§4/§7/§8) mis-anchor and which sections
    /// are hidden. Points at the real CBA on disk (skips if absent).
    func testDive_CBA_anchoring() throws {
        let path = "/Users/markfriedlander/Desktop/Posey-backup-before-history-rewrite-20260519-222856/Posey Test Materials/2005 Codified Basic Agreement - Theatrical Motion Pictures.pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "CBA not on disk")
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: URL(fileURLWithPath: path))
        let units = try db.units(for: doc.id)
        let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sentenceUnitIDs = Set((try? db.sentences(for: doc.id))?.map { $0.unitID } ?? [])
        let toc = try db.tocEntries(for: doc.id)
        var out = "════ CBA anchoring — \(toc.count) entries, \(units.count) units ════\n"
        for e in toc.prefix(40) {
            let u = byID[e.unitID]
            let vis = sentenceUnitIDs.contains(e.unitID) ? "VIS" : "hid"
            let kind = u.map { "\($0.kind)" } ?? "NIL"
            let seq = u.map { String($0.sequence) } ?? "-"
            let utext = u?.text.prefix(30) ?? "—"
            out += String(format: "  [%@] %-26@ → seq%@ %@ '%@'\n",
                          vis, e.title.prefix(26).description, seq, kind, utext.description)
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/cba_anchoring.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    // ── Well-behaved formats: assert clean ──────────────────────────────────

    func testGate_MD_pandocManual() throws {
        let db = try freshDB()
        let doc = try MarkdownLibraryImporter(databaseManager: db).importDocument(from: try src("md_pandoc-manual_book-length.md"))
        try assess(db, doc, format: "MD", file: "md_pandoc-manual_book-length.md", assertClean: true)
    }

    func testGate_RTF_styledHeadings() throws {
        let db = try freshDB()
        let doc = try RTFLibraryImporter(databaseManager: db).importDocument(from: try src("rtf_styled-headings.rtf"))
        try assess(db, doc, format: "RTF", file: "rtf_styled-headings.rtf", assertClean: true)
    }

    func testGate_DOCX_headingStyles() throws {
        let db = try freshDB()
        let doc = try DOCXLibraryImporter(databaseManager: db).importDocument(from: try src("docx_heading-styles.docx"))
        try assess(db, doc, format: "DOCX", file: "docx_heading-styles.docx", assertClean: true)
    }

    func testGate_EPUB_sherlock() async throws {
        let db = try freshDB()
        let doc = try await EPUBLibraryImporter(databaseManager: db).importDocument(from: try src("01661_adventures-of-sherlock-holmes.epub"))
        try assess(db, doc, format: "EPUB", file: "01661_adventures-of-sherlock-holmes.epub", assertClean: true)
    }

    // ── FEASIBILITY PROBE (answer "CAN it be done?" before designing HOW).
    //    The rebuild needs to chop PDFs at real seams on the EXISTING unit-identity
    //    ruler. That requires structural signal from PDFKit: (a) an embedded
    //    outline (titles + page destinations), (b) font-size info to tell a
    //    heading from body, (c) position info to tell paragraph breaks. Probe what
    //    PDFKit actually exposes — if the signal isn't there, the approach is dead. ──

    private func probeFeasibility(_ file: String, samplePages: [Int]) throws -> String {
        let url = try src(file)
        guard let doc = PDFDocument(url: url) else { return "  \(file): UNREADABLE\n" }
        var out = "════════ [FEASIBILITY] \(file) — pages=\(doc.pageCount) ════════\n"
        // (a) Embedded outline.
        if let root = doc.outlineRoot, root.numberOfChildren > 0 {
            var n = 0, withDest = 0
            func walk(_ node: PDFOutline) {
                for i in 0..<node.numberOfChildren {
                    guard let c = node.child(at: i) else { continue }
                    n += 1
                    if let p = c.destination?.page, doc.index(for: p) != NSNotFound { withDest += 1 }
                    walk(c)
                }
            }
            walk(root)
            out += "  OUTLINE: yes — \(n) entries, \(withDest) with a resolvable page destination\n"
        } else {
            out += "  OUTLINE: NONE (this PDF has no embedded outline)\n"
        }
        // (b)+(c) Font sizes + line positions on sample pages.
        for pageIdx in samplePages where pageIdx < doc.pageCount {
            guard let page = doc.page(at: pageIdx) else { continue }
            let attr = page.attributedString
            var sizes: [Double: Int] = [:]   // font point size → run char count
            attr?.enumerateAttribute(.font, in: NSRange(location: 0, length: attr?.length ?? 0)) { val, range, _ in
                if let f = val as? NSObject, f.responds(to: NSSelectorFromString("pointSize")) {
                    let sz = (f.value(forKey: "pointSize") as? Double).map { ($0 * 10).rounded() / 10 } ?? -1
                    sizes[sz, default: 0] += range.length
                }
            }
            let sizeSummary = sizes.sorted { $0.key > $1.key }.prefix(6)
                .map { "\($0.key)pt×\($0.value)" }.joined(separator: " ")
            // Line Y positions from character bounds → vertical gaps.
            let nchars = page.numberOfCharacters
            var lastY = -1.0, gaps = 0, lines = 0
            for i in stride(from: 0, to: min(nchars, 4000), by: 25) {
                let b = page.characterBounds(at: i)
                let y = Double(b.origin.y.rounded())
                if abs(y - lastY) > 1 { lines += 1; if lastY >= 0 && abs(y - lastY) > Double(b.height) * 1.6 { gaps += 1 }; lastY = y }
            }
            out += "  page \(pageIdx): fonts[\(sizes.count) distinct sizes: \(sizeSummary)]  sampledLines=\(lines) bigVerticalGaps=\(gaps)\n"
        }
        return out
    }

    /// Confirm the font-size signal is REAL: dump the actual text of large-font
    /// runs on GEB (no outline → font is our heading source). If the big-font
    /// text IS chapter/section headings, font-based detection is feasible for the
    /// no-outline case. (Corroborates the size HISTOGRAM with the size→text mapping.)
    func testFeasibility_GEB_largeFontText() throws {
        let url = try src("GEBen.pdf")
        guard let doc = PDFDocument(url: url) else { return XCTFail("unreadable") }
        var out = "════════ [FEASIBILITY] GEB — text at large fonts (heading source w/o outline) ════════\n"
        for pageIdx in [38, 39, 40, 41, 60, 80] where pageIdx < doc.pageCount {
            guard let page = doc.page(at: pageIdx), let attr = page.attributedString else { continue }
            var runs: [(Double, String)] = []
            attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { val, range, _ in
                guard let f = val as? NSObject, f.responds(to: NSSelectorFromString("pointSize")),
                      let sz = f.value(forKey: "pointSize") as? Double, sz >= 13.5 else { return }
                let t = (attr.string as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { runs.append((sz, t)) }
            }
            if !runs.isEmpty {
                out += "  page \(pageIdx):\n"
                for (sz, t) in runs.prefix(6) { out += "     \(sz)pt  '\(t.prefix(50))'\n" }
            }
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/geb_fonts.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// Validate Mark's idea: read a chapter title, search the WHOLE body for it,
    /// and check that the real heading occurrence is findable + distinguishable
    /// from the contents-page and index occurrences. Lists every occurrence of a
    /// few GEB titles (offset + snippet) so we can SEE whether judgment (which one
    /// is the heading) is recoverable. Pairs with the font signal (the heading
    /// occurrence is the big-font one).
    func testValidate_titleSearchFindsHeading() throws {
        let url = try src("GEBen.pdf")
        let parsed = try PDFDocumentImporter().loadDocument(from: url)
        let ns = parsed.displayText as NSString
        let titles = ["The MU-puzzle", "Figure and Ground", "Recursive Structures", "Brains and Thoughts"]
        var out = "════════ [VALIDATE Mark's idea] GEB — every occurrence of each chapter title ════════\n"
        for title in titles {
            out += "  '\(title)':\n"
            var searchFrom = 0
            var count = 0
            while searchFrom < ns.length, count < 8 {
                let r = ns.range(of: title, options: .caseInsensitive,
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                if r.location == NSNotFound { break }
                count += 1
                let ctxStart = max(0, r.location - 16)
                let ctxLen = min(60, ns.length - ctxStart)
                let ctx = ns.substring(with: NSRange(location: ctxStart, length: ctxLen))
                    .replacingOccurrences(of: "\n", with: "⏎")
                out += "     @\(r.location)  …\(ctx)…\n"
                searchFrom = r.location + r.length
            }
            out += "     (\(count) occurrence\(count == 1 ? "" : "s"))\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/title_search.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    func testFeasibility_PDF_structureSignals() throws {
        var out = ""
        out += try probeFeasibility("attention-is-all-you-need_arxiv.pdf", samplePages: [2, 5])
        out += try probeFeasibility("GEBen.pdf", samplePages: [40, 100])
        out += try probeFeasibility("Cryptography for Dummies.pdf", samplePages: [30, 60])
        out += try probeFeasibility("scanned-toc-test.pdf", samplePages: [0, 1])
        try? out.write(to: URL(fileURLWithPath: "/tmp/pdf_feasibility.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    // ── PDF DEEP-DIVE diagnostics: dump the parser's TOC offsets + the actual
    //    displayText sitting at each, to SEE why import-time entries collapse
    //    onto shared prose units (Rule 5: look at the artifact, don't guess). ──

    private func dumpPDFOffsets(_ file: String, tag: String) throws {
        let url = try src(file)
        let parsed = try PDFDocumentImporter().loadDocument(from: url)
        let text = parsed.displayText
        let nsText = text as NSString
        var out = "════════ [PDF DEEP-DIVE] \(file) ════════\n"
        out += "  displayText.count=\(text.count)  tocEntries=\(parsed.tocEntries.count)  tocSkipUntilOffset=\(parsed.tocSkipUntilOffset)\n"
        out += "  ── each entry: playOrder | level | plainTextOffset | title  →  text AT that offset ──\n"
        for e in parsed.tocEntries.prefix(30) {
            let off = max(0, min(e.plainTextOffset, nsText.length - 1))
            let snipLen = min(48, nsText.length - off)
            let snip = snipLen > 0 ? nsText.substring(with: NSRange(location: off, length: snipLen)) : ""
            let clean = snip.replacingOccurrences(of: "\n", with: "⏎")
            out += "  #\(e.playOrder) L\(e.level) @\(e.plainTextOffset)  '\(e.title.prefix(34))'  →  '\(clean)'\n"
        }
        // Distinct-offset check: how many entries share an offset?
        let offsets = parsed.tocEntries.map { $0.plainTextOffset }
        let distinct = Set(offsets).count
        out += "  offsets: \(offsets.count) entries, \(distinct) DISTINCT (collapsed=\(offsets.count - distinct))\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/pdfdive_\(tag).txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    func testDive_PDF_attention_offsets() throws {
        try dumpPDFOffsets("attention-is-all-you-need_arxiv.pdf", tag: "attention")
    }

    /// Pin the off-by-one: is it constant (a harmless +1) or GROWING cross-ruler
    /// drift (a real time-bomb that craters fine-grained units)? Hypothesis: the
    /// outline resolver computes offsets in `joined` space (pages joined with
    /// "\n\n", 2 chars) but the reader's units come from `displayText` (pages
    /// joined with a single form-feed). So the stored offset drifts +1 per page
    /// boundary. Measure drift = storedOffset − trueDisplayTextPosition per entry;
    /// if it climbs with page number, the rulers diverge and it MUST be fixed
    /// before chopping into small units. Method 2 corroborating the code read.
    func testDive_PDF_attention_offsetDriftGrows() throws {
        let url = try src("attention-is-all-you-need_arxiv.pdf")
        let parsed = try PDFDocumentImporter().loadDocument(from: url)
        let disp = parsed.displayText as NSString
        // Count form-feeds before a given displayText offset = page index there.
        func pageAt(_ off: Int) -> Int {
            let sub = disp.substring(to: min(off, disp.length))
            return sub.components(separatedBy: "\u{000C}").count - 1
        }
        var out = "════════ [OFF-BY-ONE] attention — stored offset vs true position in displayText ════════\n"
        var prevDrift: Int? = nil
        for e in parsed.tocEntries {
            // True position: exact (case-insensitive) match of the title in displayText.
            let r = disp.range(of: e.title, options: .caseInsensitive)
            if r.location == NSNotFound {
                out += "  #\(e.playOrder) '\(e.title.prefix(26))' stored=@\(e.plainTextOffset)  (title not found verbatim)\n"
                continue
            }
            let drift = e.plainTextOffset - r.location
            let delta = prevDrift.map { drift - $0 }
            prevDrift = drift
            out += "  #\(e.playOrder) '\(e.title.prefix(26))' stored=@\(e.plainTextOffset) true=@\(r.location) page≈\(pageAt(r.location)) DRIFT=\(drift)\(delta.map { "  (Δ\($0))" } ?? "")\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/pdf_drift.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// Pin the EXACT failure stage: import Attention via the FULL PDFLibraryImporter,
    /// then dump (a) every imported unit — index, kind, computed plainText offset,
    /// first chars — and (b) each TOC entry → which unit index its stored unitID
    /// resolves to, and that unit's offset. If every entry resolves to unit 0,
    /// the units aren't split at headings. If entries resolve to DISTINCT later
    /// units but the reader still lands at 0, the bug is downstream (jump/resolve).
    func testDive_PDF_attention_unitMapping() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("attention-is-all-you-need_arxiv.pdf"))
        let units = try db.units(for: doc.id)
        let toc = try db.tocEntries(for: doc.id)
        // Compute each unit's plainText offset the way the resolver does.
        var offsetByIndex: [Int] = []
        var cum = 0
        for u in units {
            offsetByIndex.append(cum)
            if u.kind.carriesProseText { cum += u.text.count + 2 }
        }
        let indexByID = Dictionary(units.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })

        var out = "════════ [PDF UNIT-MAP] attention — units=\(units.count) toc=\(toc.count) ════════\n"
        out += "── UNITS (index | kind | offset | firstChars) ──\n"
        for (i, u) in units.enumerated() {
            out += "  [\(i)] \(u.kind) @\(offsetByIndex[i]) lvl=\(u.metadata.headingLevel.map(String.init) ?? "-") '\(u.text.prefix(40).replacingOccurrences(of: "\n", with: "⏎"))'\n"
        }
        out += "── TOC → resolved unit ──\n"
        for e in toc {
            let idx = indexByID[e.unitID]
            let uoff = idx.map { offsetByIndex[$0] } ?? -1
            out += "  '\(e.title.prefix(30))' @\(e.plainTextOffset)  →  unit[\(idx.map(String.init) ?? "MISSING")] @\(uoff)\n"
        }
        let resolvedIdxs = toc.compactMap { indexByID[$0.unitID] }
        out += "── TOC resolves to \(Set(resolvedIdxs).count) DISTINCT units (of \(toc.count) entries; \(toc.count - resolvedIdxs.count) MISSING) ──\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/pdf_unitmap.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    func testDive_PDF_geb_offsets() throws {
        try dumpPDFOffsets("GEBen.pdf", tag: "geb")
    }

    /// Generalize across the PDF family (Rule 10): a scanned-TOC fixture and a
    /// second real book-PDF — confirm the known failure modes recur and surface
    /// any NEW mode before we design the rebuild.
    func testDive_PDF_scannedToc_offsets() throws {
        try dumpPDFOffsets("scanned-toc-test.pdf", tag: "scanned")
    }
    func testDive_PDF_measure_offsets() throws {
        try dumpPDFOffsets("Measure What Matters - John Doerr.pdf", tag: "measure")
    }
    func testDive_PDF_crypto_offsets() throws {
        try dumpPDFOffsets("Cryptography for Dummies.pdf", tag: "crypto")
    }

    /// PDF rebuild Piece A+B (2026-06-29) — full NEW pipeline on a real book:
    /// clean lines → resolve heading lines (per-title weightiest) → build units.
    /// Confirms chapters become `.heading` units (the thing the play-head can land
    /// on). Cryptography: 14pt-bold chapter headings against 8.5 body.
    func testDive_PDF_unitsFromLines() throws {
        let titles = ["A Primer on Crypto Basics", "Major League Algorithms",
                      "Deciding What You Really Need", "Locks and Keys"]
        guard let doc = PDFDocument(url: try src("Cryptography for Dummies.pdf")) else {
            XCTFail("open"); return
        }
        var linesByPage: [[PDFTextLine]] = []
        for p in 0..<min(doc.pageCount, 130) {
            if let page = doc.page(at: p) {
                let ls = PDFLineExtractor.lines(from: page, pageIndex: p)
                if !ls.isEmpty { linesByPage.append(ls) }
            }
        }
        let headingSet = PDFHeadingKeyDeriver.headingLines(titles: titles, allLines: linesByPage.flatMap { $0 })
        let units = ContentUnitBuilder.unitsFromPDFLines(
            linesByPage, documentID: UUID(),
            isHeading: { headingSet.contains($0) })

        let headingUnits = units.filter { $0.kind == .heading }
        var out = "════ Crypto — new pipeline ════\n"
        out += "  pages=\(linesByPage.count)  units=\(units.count)  heading-units=\(headingUnits.count)  resolved-heading-lines=\(headingSet.count)\n"
        for h in headingUnits.prefix(12) { out += "  [H] \(h.text.prefix(48))\n" }
        // sample: the units right around the first chapter heading
        if let idx = units.firstIndex(where: { $0.kind == .heading && $0.text.contains("Primer") }) {
            out += "  — around 'Primer' heading —\n"
            for u in units[max(0,idx-1)...min(units.count-1, idx+2)] {
                out += "    \(u.kind) | \(u.text.prefix(50))\n"
            }
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/units_from_lines.txt"), atomically: true, encoding: .utf8)
        print(out)
        XCTAssertGreaterThanOrEqual(headingUnits.count, 3, "expected the resolved chapter headings to become .heading units")
        XCTAssertTrue(headingUnits.contains { $0.text.contains("Primer on Crypto") },
                      "'A Primer on Crypto Basics' should be a heading unit")
    }

    /// PDF rebuild (2026-06-29) — RECONCILE probe vs app. My macOS probe saw
    /// Crypto p15 "Chapter 1: A Primer…" at f14 BOLD, but the in-app deriver says
    /// "not located". Dump what the APP's `PDFLineExtractor` actually produces on
    /// the failing pages, so I debug reality, not a guess (Rule 5 + corroborate).
    func testDive_PDF_extractorReality() throws {
        var out = ""
        // Crypto p15 — the chapter-1 page; do we see the f14 bold heading?
        if let doc = PDFDocument(url: try src("Cryptography for Dummies.pdf")), let p = doc.page(at: 15) {
            out += "════ Crypto p15 — ALL app-extracted lines ════\n"
            for l in PDFLineExtractor.lines(from: p, pageIndex: 15) {
                out += String(format: "  f%.1f%@%@ x%.0f | %@\n", l.fontSize, l.isBold ? "B" : " ",
                              l.isAllCaps ? "C" : " ", l.indentX, l.text.prefix(64).description)
            }
        }
        // GEB — across the first 130 sheets, every BIG-font line (≥14pt): are the
        // real chapter headings (like "The MU-puzzle") actually extracted?
        if let doc = PDFDocument(url: try src("GEBen.pdf")) {
            out += "\n════ GEB — all lines ≥14pt in sheets 0–130 ════\n"
            for pg in 0..<min(doc.pageCount, 130) {
                guard let page = doc.page(at: pg) else { continue }
                for l in PDFLineExtractor.lines(from: page, pageIndex: pg) where l.fontSize >= 14 {
                    out += String(format: "  p%d f%.1f%@ | %@\n", pg, l.fontSize, l.isBold ? "B" : " ",
                                  l.text.prefix(50).description)
                }
            }
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/extractor_reality.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// PDF rebuild (2026-06-29, MARK'S METHOD) — derive each book's heading "key"
    /// by CONSENSUS across its own chapters. For several known titles, gather
    /// every appearance in the text, keep the WEIGHTIEST (most prominent), and if
    /// independent chapters' weightiest appearances AGREE on a signature, that's
    /// the key. Different key per book, same tool. Measure-only print (Rule 5);
    /// asserts a key is derived for the books with a clear typographic signal.
    func testDive_PDF_headingKeySignals() throws {
        // REAL chapter titles (not front matter), as a reader sees them in the body.
        struct Book { let file: String; let titles: [String]; let cap: Int; let expectKey: Bool }
        let books: [Book] = [
            Book(file: "attention-is-all-you-need_arxiv.pdf",
                 titles: ["Scaled Dot-Product Attention", "Multi-Head Attention",
                          "Position-wise Feed-Forward Networks", "Why Self-Attention", "Training"],
                 cap: 15, expectKey: false),
            Book(file: "Cryptography for Dummies.pdf",
                 titles: ["A Primer on Crypto Basics", "Major League Algorithms",
                          "Deciding What You Really Need", "Locks and Keys"],
                 cap: 130, expectKey: true),
            Book(file: "Measure What Matters - John Doerr.pdf",
                 titles: ["Google, Meet OKRs", "The Father of OKRs", "Operation Crush",
                          "Focus: The Remind Story", "Commit: The Nuna Story"],
                 cap: 130, expectKey: true),
            Book(file: "GEBen.pdf",
                 titles: ["The MU-puzzle", "Sonata for Unaccompanied Achilles",
                          "Figure and Ground", "Contracrostipunctus", "Two-Part Invention"],
                 cap: 130, expectKey: true),
        ]
        var out = ""
        for b in books {
            let url = try src(b.file)
            guard let doc = PDFDocument(url: url) else { continue }
            let titles = b.titles
            // all reconstructed lines up to the page cap (covers front matter + early chapters).
            var allLines: [PDFTextLine] = []
            for p in 0..<min(doc.pageCount, b.cap) {
                if let page = doc.page(at: p) { allLines += PDFLineExtractor.lines(from: page, pageIndex: p) }
            }
            out += "════ \(b.file) — \(titles.count) titles, \(allLines.count) lines (≤\(b.cap)pp) ════\n"
            let key = PDFHeadingKeyDeriver.derive(titles: titles, allLines: allLines)
            // show the per-title weightiest appearance (transparency).
            let body = PDFHeadingKeyDeriver.bodyFontSize(of: allLines)
            for t in titles.prefix(5) {
                let top = PDFHeadingKeyDeriver.appearances(of: t, in: allLines, bodyFont: body)
                    .max { $0.score < $1.score }
                if let top {
                    out += String(format: "  '%@' → weightiest f%.1f%@%@ score%.1f | %@\n",
                                  t.prefix(26).description, top.line.fontSize,
                                  top.line.isBold ? " BOLD" : "", top.line.isAllCaps ? " CAPS" : "",
                                  top.score, top.line.text.prefix(40).description)
                } else { out += "  '\(t.prefix(26))' → (not located)\n" }
            }
            if let key {
                out += String(format: "  ★ KEY: font %.1f%@%@ (body %.1f) — %d/%d chapters agree\n\n",
                              key.fontSize, key.isBold ? " BOLD" : "", key.isAllCaps ? " CAPS" : "",
                              key.bodyFontSize, key.votes, key.sampled)
            } else {
                out += "  ★ KEY: none derived (no consensus)\n\n"
            }
            if b.expectKey { XCTAssertNotNil(key, "[\(b.file)] expected a derivable heading key") }
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/heading_key_signals.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// PDF rebuild Piece 1 corroboration (2026-06-29) — the PAGE ruler.
    /// Hypothesis (from code-read + standalone PDFKit probe): `pageBreak.pageNumber`
    /// is the form-feed-segment ORDINAL (blank pages dropped, text+image pages
    /// doubled, hyphen-merge can drop a separator), NOT the TRUE PDFKit page index
    /// that the outline's chapter destinations use. If so, the two rulers diverge
    /// on docs with blank/image pages, and anchoring a chapter by page mis-maps.
    /// Measure-only: prints the proof so it's VISIBLE (Rule 5), asserts nothing.
    func testDive_PDF_pageRulerAlignment() throws {
        for file in ["attention-is-all-you-need_arxiv.pdf",
                     "Measure What Matters - John Doerr.pdf",
                     "Cryptography for Dummies.pdf"] {
            let url = try src(file)
            // TRUE page facts straight from PDFKit.
            guard let raw = PDFDocument(url: url) else { continue }
            let truePageCount = raw.pageCount
            var outlineDests: [(String, Int)] = []
            func walk(_ n: PDFOutline) {
                for k in 0..<n.numberOfChildren {
                    guard let c = n.child(at: k) else { continue }
                    if let l = c.label, !l.isEmpty, let d = c.destination, let p = d.page {
                        outlineDests.append((l, raw.index(for: p)))
                    }
                    walk(c)
                }
            }
            if let root = raw.outlineRoot { walk(root) }

            // What the IMPORTER produced.
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: url)
            let units = try db.units(for: doc.id)
            let breaks = units.filter { $0.kind == .pageBreak }
            let breakPages = breaks.compactMap { $0.metadata.pageNumber }.sorted()
            let maxBreakPage = breakPages.last ?? -1
            // Does every outline destination page have a matching pageBreak?
            let breakPageSet = Set(breakPages)
            let destsWithoutBreak = outlineDests.filter { !breakPageSet.contains($0.1) }

            var out = "════════ [pageRuler] \(file) ════════\n"
            out += "  TRUE PDFKit pages: \(truePageCount)   pageBreak units: \(breaks.count)   max pageBreak.pageNumber: \(maxBreakPage)\n"
            out += "  → pageBreak count \(breaks.count == truePageCount ? "==" : "!=") truePageCount, maxBreakPage \(maxBreakPage == truePageCount - 1 ? "==" : "!=") truePageCount-1\n"
            out += "  outline dests: \(outlineDests.count)   dests with NO matching pageBreak (would dangle/mis-anchor): \(destsWithoutBreak.count)\n"
            for d in destsWithoutBreak.prefix(8) { out += "    • '\(d.0.prefix(34))' → true page \(d.1) (no pageBreak with that number)\n" }
            try? out.write(to: URL(fileURLWithPath: "/tmp/pageruler_\(file.prefix(6)).txt"), atomically: true, encoding: .utf8)
            print(out)
        }
    }

    /// Corroborate the GEB wrong-offset hypothesis by a SECOND method (no single
    /// observations): for each TOC title, compare where it RESOLVED to where it
    /// FIRST appears in the text (unconstrained). The monotonic forward-only
    /// resolver (PDFTextStructureDetector.buildEntries) predicts that once the
    /// cursor leaps into the back-of-book index, later titles resolve FAR LATER
    /// than their first (body) occurrence — a measurable cascade.
    func testDive_PDF_geb_firstOccurrenceVsResolved() throws {
        let url = try src("GEBen.pdf")
        let parsed = try PDFDocumentImporter().loadDocument(from: url)
        let text = parsed.displayText
        let ns = text as NSString
        var out = "════════ [GEB cascade] firstOccurrence vs resolved (text.count=\(text.count)) ════════\n"
        var cascaded = 0
        for e in parsed.tocEntries {
            // First unconstrained occurrence of the bare title.
            let bare = e.title.split(separator: " ", maxSplits: 1).last.map(String.init) ?? e.title
            let firstFull = ns.range(of: e.title, options: .caseInsensitive)
            let firstBare = ns.range(of: bare, options: .caseInsensitive)
            let first = firstFull.location != NSNotFound ? firstFull.location
                      : (firstBare.location != NSNotFound ? firstBare.location : -1)
            let gap = first >= 0 ? e.plainTextOffset - first : 0
            // "cascaded" = resolved much later than where it first appears.
            if first >= 0 && gap > 5000 { cascaded += 1 }
            out += "  #\(e.playOrder) '\(e.title.prefix(30))'  resolved=@\(e.plainTextOffset)  firstSeen=@\(first)  gap=\(gap)\(gap > 5000 ? "  ⟵CASCADE" : "")\n"
        }
        out += "── \(cascaded) of \(parsed.tocEntries.count) entries resolved >5000 chars AFTER their first appearance ──\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/geb_cascade.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// **Observe the SUSPECTED orphan-on-rewrite deterministically, off-device**
    /// (no models, no antenna). Simulate Tier 2 by calling the exact function it
    /// uses — `DatabaseManager.replaceUnitsForPage` — on a page a TOC entry
    /// anchors to, then check whether that entry's stored `unitID` survives. If it
    /// doesn't, the contents link is orphaned and the reader's identity filter
    /// (`sentencesByUnit[unitID] != nil`) would drop it / `jumpToTOCEntry` would
    /// no-op. This is method 2 corroborating the code read (replaceUnitsForPage
    /// DELETEs old units + mints new ids).
    func testDive_PDF_tier2RewriteOrphansTOCEntry() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("attention-is-all-you-need_arxiv.pdf"))
        let unitsBefore = try db.units(for: doc.id)
        let toc = try db.tocEntries(for: doc.id)
        let idsBefore = Set(unitsBefore.map { $0.id })
        // Pick a TOC entry whose anchor unit resolves to a real unit, and find the
        // page it lives on (nearest preceding pageBreak's pageNumber).
        let byIndex = Dictionary(unitsBefore.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        guard let entry = toc.first(where: { idsBefore.contains($0.unitID) }),
              let uIdx = byIndex[entry.unitID] else {
            return XCTFail("no TOC entry resolves to a unit pre-rewrite")
        }
        var pageNumber: Int? = nil
        for i in stride(from: uIdx, through: 0, by: -1) {
            if unitsBefore[i].kind == .pageBreak { pageNumber = unitsBefore[i].metadata.pageNumber; break }
        }
        guard let page = pageNumber else { return XCTFail("could not find page for entry") }

        // Simulate Tier 2 rewriting that page with corrected text.
        _ = try db.replaceUnitsForPage(
            documentID: doc.id, pageNumber: page,
            newPageText: "Corrected paragraph one.\n\nCorrected paragraph two.",
            sourceTier: "tier2")

        let unitsAfter = try db.units(for: doc.id)
        let idsAfter = Set(unitsAfter.map { $0.id })
        let survived = idsAfter.contains(entry.unitID)

        var out = "════════ [ORPHAN TEST] Attention — Tier-2 rewrite of page \(page) ════════\n"
        out += "  TOC entry '\(entry.title.prefix(30))' unitID=\(entry.unitID.uuidString.prefix(8))\n"
        out += "  unitID present BEFORE rewrite: \(idsBefore.contains(entry.unitID))\n"
        out += "  unitID present AFTER  rewrite: \(survived)\n"
        out += "  units \(unitsBefore.count)→\(unitsAfter.count)\n"
        out += survived
            ? "  RESULT: entry SURVIVED (no orphan on this page)\n"
            : "  RESULT: entry ORPHANED — its anchor unit was deleted+replaced; re-find is NOT applied to TOC → link dead\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/pdf_orphan.txt"), atomically: true, encoding: .utf8)
        print(out)

        // The point of the test is to OBSERVE the behavior, recorded above. The
        // orphan is the predicted outcome; assert it so a future fix that adds
        // re-find-for-TOC will flip this red→green and prove it.
        XCTAssertFalse(survived,
            "EXPECTED orphan: Tier-2 page rewrite deletes the anchor unit and the TOC entry's unitID is not re-found. If this FAILS (entry survived), the orphan mechanism does not bite this case — update the diagnosis.")
    }

    // ── PDFs: MEASURE-ONLY (book-PDF structure is the known deep-dive) ───────

    func testGate_PDF_attention_bornDigital() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("attention-is-all-you-need_arxiv.pdf"))
        try assess(db, doc, format: "PDF-attention", file: "attention-is-all-you-need_arxiv.pdf", assertClean: false)
    }

    func testGate_PDF_geb_knownBroken() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("GEBen.pdf"))
        try assess(db, doc, format: "PDF-geb", file: "GEBen.pdf", assertClean: false)
    }
}
