import XCTest
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
