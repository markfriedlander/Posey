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

    /// PDF rebuild Piece "watermark" (2026-06-29) — Mark: "we have a watermark
    /// remover now." We do (`PDFWatermarkStripper`, built for Crypto's ChmMagic
    /// banner), but the NEW line path doesn't call it. Before wiring it in, SEE how
    /// the banner appears in the clean `PDFLineExtractor` line stream (one line? two?
    /// where?) and whether the EXISTING stripper catches it PER LINE. Rule 5: look
    /// at the real artifact before coding the fix.
    func testDive_PDF_cryptoWatermarkLines() throws {
        let url = try src("Cryptography for Dummies.pdf")
        guard let doc = PDFDocument(url: url) else { return XCTFail("crypto unreadable") }
        var out = "════ Crypto watermark in the clean line stream — pages=\(doc.pageCount) ════\n"
        for pageIdx in [10, 20, 40] {
            guard pageIdx < doc.pageCount, let page = doc.page(at: pageIdx) else { continue }
            let lines = PDFLineExtractor.lines(from: page, pageIndex: pageIdx)
            out += "\n── page \(pageIdx): \(lines.count) lines ──\n"
            for (i, l) in lines.prefix(6).enumerated() {
                let strippedLine = PDFWatermarkStripper.strip(l.text)
                let caught = strippedLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !l.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                out += String(format: "  L%02d f%4.1f%@ y%5.0f | %@%@\n",
                              i, l.fontSize, l.isBold ? "B" : " ", l.yTop,
                              caught ? "‹PER-LINE-STRIP-CLEARS› " : "",
                              l.text.prefix(72).description)
            }
        }
        // Also: does strip() catch the banner when the page's lines are JOINED?
        if let page = doc.page(at: 20) {
            let lines = PDFLineExtractor.lines(from: page, pageIndex: 20)
            let joined = lines.map { $0.text }.joined(separator: "\n")
            let strippedJoined = PDFWatermarkStripper.strip(joined)
            out += "\n── page 20 JOINED strip delta: \(joined.count) → \(strippedJoined.count) chars "
            out += (strippedJoined.count < joined.count ? "(banner removed ✓)" : "(NO match ✗)") + "\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/crypto_watermark.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// PDF rebuild — END-TO-END proof the watermark is gone from IMPORTED UNITS
    /// after wiring the existing `PDFWatermarkStripper` into `PDFLineExtractor`.
    /// Before the fix: the ChmMagic banner imported as a prose unit on ~every page.
    /// After: zero units carry it. Real doc (Rule 7), full importer path.
    func testGate_PDF_cryptoWatermarkStripped() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("Cryptography for Dummies.pdf"))
        let units = try db.units(for: doc.id)
        let offenders = units.filter {
            let t = $0.text.lowercased()
            return t.contains("bisenter") || t.contains("chmmagic")
        }
        let sample = offenders.prefix(3).map { "seq\($0.sequence) '\($0.text.prefix(60))'" }.joined(separator: " | ")
        XCTAssertEqual(offenders.count, 0,
                       "ChmMagic watermark still in \(offenders.count) units: \(sample)")
        print("✓ Crypto: \(units.count) units, 0 carry the ChmMagic banner")
    }

    /// Watermark stripping — GENERALIZED (Rule 10) + no false positives.
    /// CC#15 only proved Crypto; Mark: one file is not done. Recon 2026-06-30
    /// across the WHOLE PDF corpus (PDFKit probe): only "Cryptography for
    /// Dummies" carries a converter banner (ChmMagic, 340/341 pages); every
    /// other PDF is brand-free. So the real generalization is two-sided:
    ///   (a) NO FALSE POSITIVE — the brand-narrow stripper must never eat real
    ///       prose from the many clean docs (content identical, modulo the
    ///       stripper's intentional whitespace collapse);
    ///   (b) POSITIVE — the watermarked doc comes out with zero banner survivors.
    /// Faithful pure-function test on PDFKit page text; the per-LINE import path
    /// is covered by testGate_PDF_cryptoWatermarkStripped above.
    func testGate_PDF_watermarkStripGeneralizesNoFalsePositive() throws {
        // Compare CONTENT, not whitespace: collapse runs + trim on both sides.
        func contentOnly(_ s: String) -> String {
            s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // (a) clean docs lose NO content (sample first 40 text pages → big books stay fast)
        let cleanDocs = [
            "attention-is-all-you-need_arxiv.pdf",
            "Measure What Matters - John Doerr.pdf",
            "GEBen.pdf",
            "before the model part1 expanded.pdf",
            "IRS-Publication-17.pdf",
        ]
        for file in cleanDocs {
            let pdf = PDFDocument(url: try src(file))
            XCTAssertNotNil(pdf, "unreadable: \(file)")
            var pagesChecked = 0
            for i in 0..<min(pdf?.pageCount ?? 0, 40) {
                guard let raw = pdf?.page(at: i)?.string, !raw.isEmpty else { continue }
                pagesChecked += 1
                XCTAssertEqual(contentOnly(PDFWatermarkStripper.strip(raw)), contentOnly(raw),
                               "\(file) p\(i): watermark stripper REMOVED real content (false positive)")
            }
            XCTAssertGreaterThan(pagesChecked, 0, "\(file): no text pages sampled")
        }

        // (b) the watermarked doc: banner present before, zero survivors after
        let crypto = PDFDocument(url: try src("Cryptography for Dummies.pdf"))
        XCTAssertNotNil(crypto)
        var bannerPagesBefore = 0, survivedAfter = 0
        for i in 0..<min(crypto?.pageCount ?? 0, 60) {
            guard let raw = crypto?.page(at: i)?.string, !raw.isEmpty else { continue }
            let low = raw.lowercased()
            if low.contains("chmmagic") || low.contains("bisenter") { bannerPagesBefore += 1 }
            let after = PDFWatermarkStripper.strip(raw).lowercased()
            if after.contains("chmmagic") || after.contains("bisenter") { survivedAfter += 1 }
        }
        XCTAssertGreaterThan(bannerPagesBefore, 10, "expected ChmMagic banner on many Crypto pages (recon: 340/341)")
        XCTAssertEqual(survivedAfter, 0, "ChmMagic banner SURVIVED stripping on \(survivedAfter) Crypto pages")
        print("✓ watermark generalize: \(cleanDocs.count) clean docs content-preserved; Crypto banner \(bannerPagesBefore)→0")
    }

    /// Page FURNITURE removal — GENERAL (Mark, 2026-06-30): a watermark stripper,
    /// not a "ChmMagic stripper". Recurring running headers / footers / stamps /
    /// page numbers must be gone from the reader + RAG text — found by position +
    /// recurrence + a fixed numeric anchor (no hardcoded strings) — WITHOUT eating
    /// body content, and PRESERVING a title's one legit instance (keep-first).
    /// Verified off-device across 8 real PDFs: ANTIFA header / OCR-garbled DOCID
    /// stamp (every spelling, via the constant-number anchor) / browser-print junk
    /// cleaned; GEB·Doerr·Crypto untouched (0%); body lines containing a recurring
    /// year preserved. This is the in-suite FULL-importer oracle on fast docs.
    func testGate_PDF_pageFurnitureRemoved() throws {
        // (1) Declassification stamp "DOCID: 3803783" — gone in ALL its OCR
        //     spellings (DOClD / DocrD / OOClO …) via the constant-number anchor.
        do {
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("Learning_from_the_Enemy.pdf"))
            let units = try db.units(for: doc.id)
            let offenders = units.filter { $0.text.contains("3803783") }
            XCTAssertEqual(offenders.count, 0,
                           "DOCID stamp survived in \(offenders.count) units: \(offenders.prefix(2).map { $0.text.prefix(30) })")
            XCTAssertGreaterThan(units.count, 0, "no units imported")
        }
        // (2) Web-archive furniture: under iOS extraction the Wayback-Machine URL
        //     header recurs on EVERY page (89–114 chars but ≤5 words — the case the
        //     old char cap let through; the PHONE caught it 2026-06-30). It must be
        //     removed. The doc title appears only a couple times (NOT a per-page
        //     header) → it survives. NOTE: the simulator uses the SAME iOS PDF engine
        //     as the phone, so this asserts the REAL on-device furniture — not the
        //     macOS extraction, which produced different (and misleading) text.
        do {
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("The Internet Steps to the Beat.pdf"))
            let units = try db.units(for: doc.id)
            let wayback = units.filter { $0.text.contains("web.archive.org") }
            let titleUnits = units.filter { $0.text.contains("The Internet Steps to the Beat") }
            XCTAssertLessThanOrEqual(wayback.count, 1,
                                     "Wayback-Machine URL running header survived in \(wayback.count) units (should be removed)")
            XCTAssertGreaterThanOrEqual(titleUnits.count, 1, "doc title should survive (not furniture)")
        }
        // (3) NO REGRESSION on a clean doc — real body survives furniture removal.
        do {
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("attention-is-all-you-need_arxiv.pdf"))
            let units = try db.units(for: doc.id)
            let joined = units.map { $0.text }.joined(separator: " ").lowercased()
            XCTAssertTrue(joined.contains("scaled dot-product") || joined.contains("multi-head attention"),
                          "clean-doc body content missing → furniture removal ate prose")
        }
        // (4) Antifa handbook — a WORD-PHRASE running header ("ANTIFA" on ~47 pages).
        //     keep-first leaves the title's one legit instance; the rest are removed.
        //     (Accepted residual: the inconsistently-extracted "MARK BRAY" footer is
        //     deliberately left — see PDFPageFurnitureDetector.) Confirmed on the
        //     PHONE's iOS engine (ANTIFA 47→1), asserted here on the same engine.
        do {
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("Antifa, The Anti-Fascist Handbook.pdf"))
            let units = try db.units(for: doc.id)
            let antifaHeader = units.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "ANTIFA" }
            let body = units.map { $0.text }.joined(separator: " ").lowercased()
            XCTAssertLessThanOrEqual(antifaHeader.count, 3,
                                     "ANTIFA running header not removed: \(antifaHeader.count) standalone units (raw ~47)")
            XCTAssertTrue(body.contains("anti-fascis") || body.contains("durruti") || body.contains("mark bray"),
                          "Antifa body content missing → furniture removal ate prose")
        }
        // (5) NO OVER-STRIP on a big clean book — GEB has no document-wide recurring
        //     furniture; its real content (dialogue characters, the MU-puzzle) must
        //     all survive. Guards the conservative threshold from eating real text.
        do {
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("GEBen.pdf"))
            let units = try db.units(for: doc.id)
            let body = units.map { $0.text }.joined(separator: " ").lowercased()
            XCTAssertTrue(body.contains("achilles") || body.contains("tortoise") || body.contains("mu-puzzle"),
                          "GEB body content missing → furniture removal over-stripped a clean doc")
        }
        print("✓ furniture: DOCID + Wayback + ANTIFA headers removed; Attention/GEB clean-doc body intact")
    }

    // ── Cross-page paragraph stitching ───────────────────────────────────────

    /// Build a synthetic PDF line. Right edge is `2*midX - indentX`; full-width
    /// lines hug the right margin (midX≈306 for a 72…540 text box), short/ending
    /// lines fall short (small midX).
    private func ln(_ text: String, page: Int, indentX: Double = 72, midX: Double,
                    gapAbove: Double = 14) -> PDFTextLine {
        PDFTextLine(text: text, fontSize: 12, isBold: false, isAllCaps: false,
                    indentX: indentX, midX: midX, yTop: 0, yBottom: 0,
                    gapAbove: gapAbove, pageIndex: page)
    }

    /// PDF rebuild — DETERMINISTIC proof of cross-page stitching (Mark's
    /// requirement: a paragraph spanning a page boundary is ONE unit). Synthetic
    /// fixture justified (Rule 7): I need a KNOWN straddle to assert the exact unit
    /// shape; the real-doc no-regression check is the companion test below.
    func testStitch_PDF_crossPageParagraph() throws {
        // Page 0 ends mid-sentence, full-width, no terminal punctuation.
        let pageA = [
            ln("The cipher described above is one of the oldest known to scholars", page: 0, midX: 306),
            ln("and it continues to be discussed by historians who note that it", page: 0, midX: 306) // full-width, ends "it"
        ]
        // Page 1 first line continues (flush-left, lowercase), then a NEW paragraph.
        // Enough normal-leading lines that the median gap is the LEADING (~14), not
        // the paragraph gap — otherwise the threshold is too high to split.
        let pageB = [
            ln("was used widely in the classical world for military dispatches and", page: 1, midX: 306, gapAbove: 0),
            ln("other sensitive communications sent across very great distances by", page: 1, midX: 306, gapAbove: 14),
            ln("couriers who had memorized the secret keys they carried with them.", page: 1, midX: 200, gapAbove: 14), // short → sentence end
            ln("A wholly separate paragraph now begins on this page entirely.", page: 1, indentX: 108, midX: 306, gapAbove: 44) // indented + big gap
        ]
        let units = ContentUnitBuilder.unitsFromPDFLines([pageA, pageB], documentID: UUID(),
                                                         isHeading: { _ in false })
        let prose = units.filter { $0.kind == .prose }
        let breaks = units.filter { $0.kind == .pageBreak }

        // Exactly TWO paragraphs: the stitched straddler + the second one.
        XCTAssertEqual(prose.count, 2, "expected 2 prose units (1 stitched straddler + 1), got \(prose.count): \(prose.map { $0.text.prefix(30) })")
        // The straddling paragraph is ONE unit carrying text from BOTH pages.
        XCTAssertTrue(prose[0].text.contains("continues to be discussed") && prose[0].text.contains("was used widely"),
                      "straddling paragraph should span both pages in one unit: '\(prose[0].text)'")
        XCTAssertTrue(prose[1].text.contains("wholly separate paragraph"), "second paragraph kept distinct")
        // Both page-break markers survive (page map intact) and page 1's break is
        // DEFERRED to just after the straddling paragraph.
        XCTAssertEqual(Set(breaks.compactMap { $0.metadata.pageNumber }), [0, 1], "both pages marked")
        let break1 = breaks.first { $0.metadata.pageNumber == 1 }!
        XCTAssertGreaterThan(break1.sequence, prose[0].sequence, "page-1 break deferred to after the straddling paragraph")
        print("✓ stitch: 2 prose units, straddler spans pages, page-1 break deferred after it")
    }

    /// PDF rebuild — NON-stitch control: when page 0 ends a sentence (terminal '.'),
    /// the paragraphs stay SEPARATE and the page break is NOT deferred. Guards
    /// against over-stitching (merging genuinely separate paragraphs).
    func testStitch_PDF_noStitchWhenSentenceEnds() throws {
        let pageA = [
            ln("The first paragraph is complete and ends cleanly right here.", page: 0, midX: 306) // ends with '.'
        ]
        let pageB = [
            ln("The second paragraph starts fresh on the next page entirely.", page: 1, midX: 306, gapAbove: 0)
        ]
        let units = ContentUnitBuilder.unitsFromPDFLines([pageA, pageB], documentID: UUID(),
                                                         isHeading: { _ in false })
        let prose = units.filter { $0.kind == .prose }
        XCTAssertEqual(prose.count, 2, "sentence-terminated boundary must NOT stitch")
        // page-1 break comes BEFORE the second paragraph (clean boundary).
        let break1 = units.first { $0.kind == .pageBreak && $0.metadata.pageNumber == 1 }!
        let secondPara = prose[1]
        XCTAssertLessThan(break1.sequence, secondPara.sequence, "clean boundary: break precedes page-1 content")
        print("✓ no-stitch: terminal sentence keeps paragraphs separate, break not deferred")
    }

    /// PDF rebuild — REAL-DOC no-regression: stitching must not lose page-break
    /// markers (page map) or break chapter anchoring. Import the real Transformer
    /// paper; assert every text-bearing page still has a break unit and TOC entries
    /// still resolve (dangling==0). Companion to the deterministic logic test.
    func testStitch_PDF_attentionNoRegression() throws {
        let db = try freshDB()
        let url = try src("attention-is-all-you-need_arxiv.pdf")
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: url)
        let units = try db.units(for: doc.id)
        let breakUnits = units.filter { $0.kind == .pageBreak }
        let proseUnits = units.filter { $0.kind == .prose }

        // Count pages that actually yield text lines (the importer only appends
        // non-empty pages), and require one break unit per such page.
        var textPages = 0
        if let pdf = PDFDocument(url: url) {
            for i in 0..<pdf.pageCount {
                if let p = pdf.page(at: i), !PDFLineExtractor.lines(from: p, pageIndex: i).isEmpty { textPages += 1 }
            }
        }
        XCTAssertEqual(breakUnits.count, textPages,
                       "every text-bearing page keeps a break unit (page map intact): \(breakUnits.count) vs \(textPages)")

        // Chapter anchoring not regressed: no TOC entry dangles.
        let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let toc = try db.tocEntries(for: doc.id)
        let dangling = toc.filter { byID[$0.unitID] == nil }.count
        XCTAssertEqual(dangling, 0, "stitching must not orphan TOC entries")
        print("✓ attention no-regression: \(breakUnits.count) breaks == \(textPages) text pages, \(proseUnits.count) prose units, \(toc.count) TOC entries, 0 dangling")
    }

    // ── Academic numbered-section headings ───────────────────────────────────

    /// PDF rebuild — the Transformer paper's section headings ("3.1 Encoder and
    /// Decoder Stacks") are body-font, so the style-inference engine missed them
    /// (10 nonHeadingInBody after the line rebuild). With numbered-section
    /// acceptance in `resolveHeadings`, each KNOWN outline title that resolves to a
    /// numbered body line becomes a heading unit. Assert TOC body entries now
    /// resolve to real heading units; print any stragglers.
    func testNumbering_PDF_attentionNumberedSections() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("attention-is-all-you-need_arxiv.pdf"))
        let units = try db.units(for: doc.id)
        let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let refs = try db.unitSkipReferences(for: doc.id)
        let skipSeq = refs.skipUnitID.flatMap { id in units.first(where: { $0.id == id })?.sequence }
        let toc = try db.tocEntries(for: doc.id)

        var nhBody = 0
        var offenders: [String] = []
        for e in toc {
            guard let u = byID[e.unitID] else { continue }   // dangling covered elsewhere
            if u.kind != .heading {
                let inBody = (skipSeq.map { u.sequence >= $0 } ?? true)
                if inBody { nhBody += 1; offenders.append("'\(e.title.prefix(34))' → \(u.kind) '\(u.text.prefix(28))'") }
            }
        }
        print("Attention: toc=\(toc.count), nonHeadingInBody=\(nhBody)")
        offenders.prefix(12).forEach { print("   ✗ \($0)") }
        XCTAssertEqual(nhBody, 0, "numbered sections should all resolve to heading units; \(nhBody) stragglers: \(offenders.prefix(6))")
    }

    /// PDF rebuild — Rule 10 (generalize): the numbered-section acceptance must not
    /// REGRESS the word-titled books. GEB + Crypto headings already stand out by
    /// font and their titles aren't numbered, so nonHeadingInBody must stay at its
    /// post-rebuild baseline (GEB 0). Promotion is monotonic — this confirms it.
    func testNumbering_PDF_wordTitledBooksNoRegression() throws {
        func nhBody(_ file: String) throws -> (toc: Int, nh: Int) {
            let db = try freshDB()
            let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src(file))
            let units = try db.units(for: doc.id)
            let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let refs = try db.unitSkipReferences(for: doc.id)
            let skipSeq = refs.skipUnitID.flatMap { id in units.first(where: { $0.id == id })?.sequence }
            let toc = try db.tocEntries(for: doc.id)
            var nh = 0
            for e in toc {
                guard let u = byID[e.unitID], u.kind != .heading else { continue }
                if (skipSeq.map { u.sequence >= $0 } ?? true) { nh += 1 }
            }
            return (toc.count, nh)
        }
        let geb = try nhBody("GEBen.pdf")
        let crypto = try nhBody("Cryptography for Dummies.pdf")
        print("GEB: toc=\(geb.toc) nonHeadingInBody=\(geb.nh) | Crypto: toc=\(crypto.toc) nonHeadingInBody=\(crypto.nh)")
        XCTAssertEqual(geb.nh, 0, "GEB nonHeadingInBody regressed from its post-rebuild baseline of 0")
    }

    /// PDF rebuild — SEE GEB dialogue turn structure before coding the split
    /// (Rule 5/7). GEB's Socratic dialogues are Achilles/Tortoise/Crab/... turns.
    /// Question: after the line rebuild, is each turn its OWN prose unit (gaps
    /// already split them) or are several turns glued into one blob? Dump prose
    /// units near a dialogue heading + count speaker labels per unit.
    func testDive_PDF_gebDialogueTurns() throws {
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: try src("GEBen.pdf"))
        let units = try db.units(for: doc.id)
        // Speaker label at the START of a turn, e.g. "Achilles:" / "Tortoise:".
        let speakerRE = try NSRegularExpression(pattern: #"\b(Achilles|Tortoise|Crab|Anteater|Author|Sloth|Genie|Babbage|Turing|Zeno)\s*:"#)
        func speakerCount(_ s: String) -> Int {
            speakerRE.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
        }
        // Find a dialogue chapter heading.
        let dialogTitles = ["Contracrostipunctus", "Two-Part Invention", "Three-Part Invention",
                            "Sonata for Unaccompanied Achilles", "Little Harmonic Labyrinth", "Crab Canon"]
        var out = "════ GEB dialogue turns — \(units.count) units ════\n"
        var blobUnits = 0, multiSpeakerExamples: [String] = []
        for u in units where u.kind == .prose {
            let n = speakerCount(u.text)
            if n >= 2 { blobUnits += 1
                if multiSpeakerExamples.count < 4 { multiSpeakerExamples.append("(\(n) speakers) \(u.text.prefix(110))") }
            }
        }
        out += "prose units containing >=2 speaker labels (BLOBS): \(blobUnits)\n"
        for ex in multiSpeakerExamples { out += "   • \(ex)\n" }
        // Sample the units right after a known dialogue heading.
        if let idx = units.firstIndex(where: { u in u.kind == .heading && dialogTitles.contains(where: { u.text.contains($0) }) }) {
            out += "— units after dialogue heading '\(units[idx].text.prefix(40))' —\n"
            for u in units[idx...min(units.count-1, idx+6)] {
                out += "   [\(u.kind)] (\(speakerCount(u.text)) spk) \(u.text.prefix(90))\n"
            }
        } else {
            out += "(no dialogue heading found among \(dialogTitles))\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/geb_dialogue.txt"), atomically: true, encoding: .utf8)
        print(out)
    }

    /// PDF rebuild — Crypto page-break distribution (Mark: "page lengths look
    /// extremely irregular, not sure it's cutting correctly"). Confirm one
    /// pageBreak unit per PDF page (no pages lost/merged by stitching) and measure
    /// the text length between consecutive breaks vs PDFKit's raw per-page sizes —
    /// to separate "source is genuinely irregular" from "stitching amplified it".
    func testDive_PDF_cryptoPageBreaks() throws {
        let db = try freshDB()
        let url = try src("Cryptography for Dummies.pdf")
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: url)
        let units = try db.units(for: doc.id)
        let breaks = units.filter { $0.kind == .pageBreak }
        // text chars between consecutive pageBreak units (the reader "page" length)
        var perPage: [Int] = []
        var acc = 0
        var started = false
        for u in units {
            if u.kind == .pageBreak { if started { perPage.append(acc) }; acc = 0; started = true }
            else { acc += u.text.count }
        }
        if started { perPage.append(acc) }
        let sorted = perPage.sorted()
        func pct(_ p: Double) -> Int { sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(Double(sorted.count)*p))] }
        let pdfPages = PDFDocument(url: url)?.pageCount ?? -1
        let emptyPages = perPage.filter { $0 < 50 }.count
        let report = """
        CRYPTO page breaks: \(breaks.count) break units, PDF pageCount=\(pdfPages)
          per-page text chars: min=\(sorted.first ?? 0) p10=\(pct(0.1)) median=\(pct(0.5)) p90=\(pct(0.9)) max=\(sorted.last ?? 0)
          near-empty 'pages' (<50 chars, incl deferred-break clusters): \(emptyPages) of \(perPage.count)
        """
        try? report.write(to: URL(fileURLWithPath: "/tmp/crypto_pb.txt"), atomically: true, encoding: .utf8)
        print(report)
        // Sanity: one break per text-bearing page (not wildly off).
        XCTAssertGreaterThan(breaks.count, pdfPages / 2, "should have a break unit for most pages")
    }

    /// PDF rebuild — NO-TEXT-DROPPED proof + sparse-page census (Mark, 2026-06-30:
    /// "the paragraph glue is leaving a very small amount of text on some pages …
    /// text is not being dropped, just paragraphs shifted"). This isolates the
    /// unit-builder/stitching STEP: its INPUT is the furniture-cleaned clean line
    /// stream (`PDFPageFurnitureDetector` over `PDFLineExtractor` lines) and its
    /// OUTPUT is the prose+heading units. If the whitespace-stripped concatenation
    /// of every unit's text EQUALS that of every clean input line, stitching only
    /// REARRANGED text — it dropped none. Then census the near-empty reader "pages"
    /// (chars between consecutive pageBreak units) and PRINT the sparse page numbers
    /// so the exact pages can be rendered and looked at (Rule 5, corroboration #2).
    func testStitch_PDF_cryptoNoTextDroppedAndSparsePageCensus() throws {
        let url = try src("Cryptography for Dummies.pdf")

        // Reconstruct the EXACT input the unit builder sees.
        let parsed = try PDFDocumentImporter().loadDocument(from: url)
        let cleaned = PDFPageFurnitureDetector.detect(in: parsed.linesByPage).cleaned
        // Compare LETTER content: ignore whitespace (space-join) AND line-break
        // hyphens (`-` / `¬`), which the builder intentionally removes when it
        // rejoins a wrapped word ("ac-"+"tion"→"action"). The invariant is
        // "no letters lost", which survives both space-join and hyphen-rejoin.
        func strip(_ s: String) -> String {
            s.filter { !$0.isWhitespace && $0 != "-" && $0 != "\u{00AC}" }
        }
        let inputText = strip(cleaned.flatMap { $0 }.map { $0.text }.joined())

        // Import for real and gather the built units.
        let db = try freshDB()
        let doc = try PDFLibraryImporter(databaseManager: db).importDocument(from: url)
        let units = try db.units(for: doc.id)
        let proseHeading = units.filter { $0.kind == .prose || $0.kind == .heading }
        let outputText = strip(proseHeading.map { $0.text }.joined())

        // Line-break hyphen artifact: "<letter>- <lowercase>" (a wrapped word that
        // wasn't rejoined). A real spaced dash ("word - word") has a space BEFORE
        // the hyphen and won't match. After the rejoin fix this should be 0.
        let hyphenArtifactRE = try NSRegularExpression(pattern: #"[A-Za-z]- [a-z]"#)
        var hyphenArtifacts = 0
        for u in proseHeading {
            hyphenArtifacts += hyphenArtifactRE.numberOfMatches(
                in: u.text, range: NSRange(u.text.startIndex..., in: u.text))
        }

        // Census sparse reader "pages": chars between consecutive pageBreak units.
        var perPage: [(page: Int?, chars: Int)] = []
        var acc = 0
        var curPage: Int? = nil
        var started = false
        for u in units {
            if u.kind == .pageBreak {
                if started { perPage.append((curPage, acc)) }
                acc = 0; curPage = u.metadata.pageNumber; started = true
            } else if u.kind == .prose || u.kind == .heading {
                acc += u.text.count
            }
        }
        if started { perPage.append((curPage, acc)) }
        let sparse = perPage.filter { $0.chars < 50 }

        let report = """
        CRYPTO no-drop + sparse census + hyphen rejoin:
          input letters (ws+hyphen-stripped)    = \(inputText.count)
          output letters (ws+hyphen-stripped)   = \(outputText.count)
          same letter content (no drop)         = \(inputText == outputText)
          reader 'pages' total                  = \(perPage.count)
          near-empty (<50 chars)                = \(sparse.count)
          near-empty page numbers               = \(sparse.compactMap { $0.page }.prefix(40))
          line-break hyphen artifacts ("ac- t") = \(hyphenArtifacts)
        """
        try? report.write(to: URL(fileURLWithPath: "/tmp/crypto_nodrop.txt"),
                          atomically: true, encoding: .utf8)
        print(report)

        // The core proof Mark asked for: the builder rearranges/rejoins, never drops.
        XCTAssertEqual(inputText, outputText,
                       "no letters dropped or added (Δ=\(outputText.count - inputText.count))")
        // The rejoin fix worked: no wrapped-word hyphen artifacts survive.
        XCTAssertEqual(hyphenArtifacts, 0,
                       "line-break hyphens must be rejoined ('ac- tion'→'action'); \(hyphenArtifacts) left")
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
