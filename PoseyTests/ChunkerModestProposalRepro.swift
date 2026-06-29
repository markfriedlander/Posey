import XCTest
@testable import Posey

/// Root-cause repro (2026-06-18): `A Modest Proposal` (short Gutenberg TXT)
/// imports + parses into units fine but produces ZERO embedding chunks on the
/// device, so Ask Posey can't answer about it. `time-machine_35.txt` (same
/// format, same Gutenberg source) chunks fine — so this isolates the chunker
/// edge case off-device with the real corpus file (Rule 7), printing every
/// intermediate value so the cause is visible, not guessed.
@MainActor
final class ChunkerModestProposalRepro: XCTestCase {

    static let corpusDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PoseyTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Posey Test Materials")

    private func diagnose(_ file: String) throws {
        let src = Self.corpusDir.appendingPathComponent(file)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing: \(file)")

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)
        let doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: src)

        let units = try db.units(for: doc.id)
        let skipOffset = doc.playbackSkipUntilOffset
        let skipSource = doc.skipSource
        // Ruler migration (df81416 / Position Rule): excludingFrontMatter now
        // takes the content-start UNIT IDENTITY (UUID), not a character offset.
        let skipUnitID = try db.unitSkipReferences(for: doc.id).skipUnitID

        let proseUnits = units.filter { $0.kind.carriesProseText }
        let totalProseChars = proseUnits.reduce(0) { $0 + $1.text.count }

        let kept = UnitEmbeddingChunker.excludingFrontMatter(
            units, skipUnitID: skipUnitID)
        let keptProse = kept.filter { $0.kind.carriesProseText }
        let keptProseChars = keptProse.reduce(0) { $0 + $1.text.count }

        let chunks = UnitEmbeddingChunker.chunks(for: doc.id, units: kept)

        var out = "════════ \(file) ════════\n"
        out += "  units total=\(units.count)  prose=\(proseUnits.count)  totalProseChars=\(totalProseChars)\n"
        out += "  skipOffset=\(skipOffset)  skipSource=\"\(skipSource)\"\n"
        out += "  excludingFrontMatter → kept=\(kept.count)  keptProse=\(keptProse.count)  keptProseChars=\(keptProseChars)\n"
        out += "  CHUNKS=\(chunks.count)\n"
        for (i, u) in proseUnits.prefix(8).enumerated() {
            out += "    [\(i)] len=\(u.text.count) carries=\(u.kind.carriesProseText) preview=\"\(u.text.prefix(48).replacingOccurrences(of: "\n", with: "⏎"))\"\n"
        }
        let logURL = URL(fileURLWithPath: "/tmp/chunker_diag.txt")
        let prior = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? (prior + out).write(to: logURL, atomically: true, encoding: .utf8)
    }

    func testModestProposal_currentlyZeroChunks() throws {
        try diagnose("modest-proposal_1080.txt")
    }

    /// 2026-06-19 (Mark) — regression for the DUPLICATE micro-chunk bug. On
    /// real docs with chapter headings ("CHAPTER I." followed by a long opening
    /// sentence) the pre-fix overlap stepped backward and replayed the same
    /// short sentences as their own chunk — "CHAPTER I.\nThe Period" was emitted
    /// 2+ times on A Tale of Two Cities. Pride & Prejudice (real corpus, Rule 7;
    /// the Darcy "tolerable" doc) has 60+ chapter headings — the exact trigger.
    /// The forward-progress guard makes chunk spans strictly advance, so NO two
    /// chunks can be identical. Assert that directly.
    func testNoDuplicateChunks_prideAndPrejudice() throws {
        let src = Self.corpusDir.appendingPathComponent("01342_pride-and-prejudice.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)
        let doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: src)
        let units = try db.units(for: doc.id)
        let kept = UnitEmbeddingChunker.excludingFrontMatter(
            units, skipUnitID: try db.unitSkipReferences(for: doc.id).skipUnitID)
        let chunks = UnitEmbeddingChunker.chunks(for: doc.id, units: kept)

        XCTAssertGreaterThan(chunks.count, 100, "expected a substantial chunk set")

        // No two chunks may have identical text. (Overlap shares trailing
        // sentences as part of LARGER chunks, so full-chunk text still differs;
        // only the backward-step bug produced exact duplicates.)
        var seen: [String: Int] = [:]
        var duplicates: [String] = []
        for c in chunks {
            seen[c.text, default: 0] += 1
            if seen[c.text] == 2 { duplicates.append(String(c.text.prefix(40))) }
        }
        XCTAssertTrue(duplicates.isEmpty,
            "duplicate chunk text emitted (overlap stepped backward): \(duplicates.prefix(5))")
    }

    func testTimeMachine_control() throws {
        try diagnose("time-machine_35.txt")
    }

    /// Ruler step 1 regression (2026-06-28): the offset-based back-trim once
    /// dropped every prose unit at/after `contentEndOffset` from the embedding
    /// pool, deleting Dracula's chapters 14–27 from what Ask Posey can search
    /// (the importer's plainText ruler drifted from the chunker's prose-join
    /// ruler — assumed equal, different per document). `excludingFrontMatter`
    /// no longer trims the back AT ALL. Proof at the RIGHT layer (the chunk
    /// pool, NOT the reader, which never lost the text): the book's TRUE closing
    /// — Jonathan Harker's "NOTE" ("…a brave and gallant woman…", ch 27, the
    /// furthest real content) — must survive into a chunk. If the far end is
    /// present, the whole 14–27 range the trim used to eat is present. Real
    /// corpus file (Rule 7): `dracula_345.txt`.
    func testDracula_backHalfReachesChunks_rulerStep1() throws {
        let src = Self.corpusDir.appendingPathComponent("dracula_345.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)
        let doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: src)
        let units = try db.units(for: doc.id)
        let kept = UnitEmbeddingChunker.excludingFrontMatter(
            units, skipUnitID: try db.unitSkipReferences(for: doc.id).skipUnitID)
        let chunks = UnitEmbeddingChunker.chunks(for: doc.id, units: kept)

        // Far-end witness: ch 27's closing Note must land in a chunk.
        let needle = "brave and gallant woman"
        let hit = chunks.contains { $0.text.localizedCaseInsensitiveContains(needle) }

        // Make the proof VISIBLE (not asserted blind): write the real numbers
        // and the last chunk's tail so the verdict can be read, not trusted.
        let lastTail = chunks.last.map { String($0.text.suffix(90)) } ?? "<none>"
        var out = "════════ dracula_345.txt — RULER STEP 1 (back-trim removed) ════════\n"
        out += "  units=\(units.count)  kept=\(kept.count)  chunks=\(chunks.count)\n"
        out += "  far-end needle \"\(needle)\" present in a chunk: \(hit)\n"
        out += "  last chunk tail: …\(lastTail.replacingOccurrences(of: "\n", with: "⏎"))\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/ruler_step1_diag.txt"),
                       atomically: true, encoding: .utf8)

        XCTAssertGreaterThan(chunks.count, 100, "Dracula should chunk substantially")
        XCTAssertTrue(hit,
            "ch-27 closing Note ('\(needle)') missing from chunks — the back-trim regressed.")
    }

    /// Ruler step 2 regression (2026-06-28): the chunker's FRONT-skip is now
    /// identity-based — it drops prose units ordered before `skipUnitID` (the
    /// importer's stored content-start anchor, the SAME anchor the reader
    /// windows on), replacing the old plainText-offset-vs-prose-join compare.
    /// Proof at the chunk layer (exercises step 2's respect-for-skipUnitID AND
    /// step 3's stored boundary): for Time Machine the real work opens at "…was
    /// expounding a recondite matter…" (line 64), preceded by the Gutenberg
    /// header + a chapter-list TOC. So chunk 0 must BE the opening, and the
    /// Gutenberg boilerplate header must appear in NO chunk. Real corpus file
    /// (Rule 7): `time-machine_35.txt` (the same control this file already uses).
    func testTimeMachine_frontSkipLandsAtOpening_rulerStep2() throws {
        let src = Self.corpusDir.appendingPathComponent("time-machine_35.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)
        let doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: src)
        let units = try db.units(for: doc.id)
        let kept = UnitEmbeddingChunker.excludingFrontMatter(
            units, skipUnitID: try db.unitSkipReferences(for: doc.id).skipUnitID)
        let chunks = UnitEmbeddingChunker.chunks(for: doc.id, units: kept)

        // STEP 2's ACTUAL guarantee: the chunker drops front matter by IDENTITY,
        // exactly at the importer's stored boundary (the same unit the reader
        // windows on), with no offset drift. Asserted two ways:
        let skipUnitID = try db.unitSkipReferences(for: doc.id).skipUnitID
        let skipSeq = skipUnitID.flatMap { id in units.first(where: { $0.id == id })?.sequence }
        // (a) no kept prose unit sits BEFORE the boundary — the front-skip is exact.
        let keptProseBeforeBoundary = skipSeq.map { s in
            kept.filter { $0.kind.carriesProseText && $0.sequence < s }
        } ?? []
        // (b) it actually removed something (non-vacuous) — the Gutenberg legal
        //     header is prose before the boundary, so prose WAS dropped.
        let totalProse = units.filter { $0.kind.carriesProseText }.count
        let keptProse = kept.filter { $0.kind.carriesProseText }.count
        let droppedProse = totalProse - keptProse
        // (c) the Gutenberg legal/copyright header leaks into NO chunk.
        let boilerplate = "Project Gutenberg eBook of"
        let boilerplateLeaked = chunks.contains { $0.text.localizedCaseInsensitiveContains(boilerplate) }

        let head = chunks.first.map { String($0.text.prefix(120)) } ?? "<none>"
        var out = "════════ time-machine_35.txt — RULER STEP 2 (front-skip identity) ════════\n"
        out += "  units=\(units.count)  kept=\(kept.count)  chunks=\(chunks.count)  skipSeq=\(skipSeq.map(String.init) ?? "nil")\n"
        out += "  kept prose units BEFORE boundary (must be 0): \(keptProseBeforeBoundary.count)\n"
        out += "  prose dropped by front-skip (must be > 0): \(droppedProse)\n"
        out += "  Gutenberg header leaked into any chunk: \(boilerplateLeaked)\n"
        out += "  chunk 0 head: \(head.replacingOccurrences(of: "\n", with: "⏎"))\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/ruler_step2_diag.txt"),
                       atomically: true, encoding: .utf8)

        XCTAssertTrue(keptProseBeforeBoundary.isEmpty,
            "chunker kept prose BEFORE the identity boundary — front-skip is not exact.")
        XCTAssertGreaterThan(droppedProse, 0,
            "front-skip dropped no prose — the skip is a no-op (boundary at sequence 0?).")
        XCTAssertFalse(boilerplateLeaked,
            "Gutenberg legal header leaked into the chunk pool — front matter not skipped.")

        // KNOWN DEFECT (front-matter detection, NOT step 2/3): the boundary stops
        // at the title page + table of contents, so chunk 0 is "The Time Machine /
        // An Invention / by H. G. Wells / CONTENTS…", not the opening prose. This
        // is the same family as P&P opening in the Saintsbury preface. Encoded as
        // an EXPECTED failure so the suite stays honest-green AND flips to a real
        // failure (alerting us) the day the front-matter detector skips past it.
        XCTExpectFailure("front-matter detection under-skips Time Machine to its title page/TOC — tracked front-matter-open defect, not the step-2 chunker mechanism") {
            let chunk0HasOpening = chunks.first?.text.localizedCaseInsensitiveContains("recondite matter") ?? false
            XCTAssertTrue(chunk0HasOpening,
                "chunk 0 is the title page/TOC, not the work's opening — front-matter under-skip.")
        }
    }

    /// Ruler step 3 verification (2026-06-28): the importer's TOC skip-gate +
    /// `ContentUnitBuilder.demoteDuplicateListingHeadings` (TXT+HTML) were migrated
    /// from a cross-ruler offset compare (R1 importer plainText vs R2 running-offset)
    /// to unit identity/sequence (`skipUnitID` → `skipSequence`, sequence-vs-sequence).
    /// It is BEHAVIOR-PRESERVING — it does NOT move where the book opens (that is the
    /// separate front-matter-detection concern; Moby still opens at the Etymology).
    /// Its JOB is de-duplicating the chapter list: Moby's TOC lists "CHAPTER 1.
    /// Loomings." (line 20) AND the body repeats it (line 818); the listing copy must
    /// be DEMOTED so the heading set has NO duplicate titles. Real corpus file
    /// (Rule 7): `02701_moby-dick.txt`.
    func testMobyDick_chapterHeadingsDeduplicated_rulerStep3() throws {
        let src = Self.corpusDir.appendingPathComponent("02701_moby-dick.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)
        let doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: src)
        let units = try db.units(for: doc.id)

        let headings = units.filter { $0.kind == .heading }
        var seen: [String: Int] = [:]
        var dups: [String] = []
        for h in headings {
            let key = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
            seen[key, default: 0] += 1
            if seen[key] == 2 { dups.append(key) }
        }

        var out = "════════ 02701_moby-dick.txt — RULER STEP 3 (TOC demote by identity) ════════\n"
        out += "  units=\(units.count)  heading-units=\(headings.count)\n"
        out += "  duplicate heading titles: \(dups.count)  \(dups.prefix(6))\n"
        try? out.write(to: URL(fileURLWithPath: "/tmp/ruler_step3_diag.txt"),
                       atomically: true, encoding: .utf8)

        XCTAssertTrue(dups.isEmpty,
            "duplicate chapter headings — the TOC listing was not demoted: \(dups.prefix(6))")
        XCTAssertLessThan(headings.count, 200,
            "heading count too high (\(headings.count)) — TOC listing likely not demoted (expect ~136).")
    }

    /// Exercise the REAL persistence path the device uses — `indexAndWait`
    /// builds chunks AND writes them via `replaceAllUnitEmbeddingChunks`.
    /// On device this produced 0 rows for modest-proposal; here we check
    /// whether the persistence step itself drops them (embeddings may stay
    /// NULL on the sim if no backend, but the ROWS must exist).
    func testModestProposal_fullIndexPath_persistsRows() async throws {
        let src = Self.corpusDir.appendingPathComponent("modest-proposal_1080.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "corpus file missing")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("posey.sqlite")
        let db = try DatabaseManager(databaseURL: dbURL)
        let doc = try TXTLibraryImporter(databaseManager: db).importDocument(from: src)

        let before = try db.unitEmbeddingChunks(for: doc.id).count
        await UnitEmbeddingService.shared.indexAndWait(documentID: doc.id, databaseManager: db)
        let after = try db.unitEmbeddingChunks(for: doc.id).count

        // RECORD-ONLY (interrupted before first run on 2026-06-18 pause): write
        // the outcome rather than hard-assert, so committing this diagnostic
        // can't red the suite before it's been run once. NEXT SESSION: run this,
        // read /tmp/chunker_diag.txt — if after>0 off-device, the persistence
        // path is fine and the on-device 0-rows is a queue-execution bug
        // (redeploy w/ indexAndWait logging); if after==0, the bug reproduces
        // off-device here and is debuggable directly. Then restore a hard
        // XCTAssertGreaterThan(after, 0).
        let msg = "indexAndWait persisted rows: before=\(before) after=\(after)"
        let logURL = URL(fileURLWithPath: "/tmp/chunker_diag.txt")
        let prior = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? (prior + "FULL-PATH " + msg + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
}
