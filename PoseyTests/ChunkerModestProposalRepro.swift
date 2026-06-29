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
