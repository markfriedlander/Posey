import Foundation

// ========== BLOCK 01: PDF LIBRARY IMPORTER (UNITS) - START ==========

/// Imports PDF files into the unit-based content model.
///
/// **What changed in the rebuild:** the importer emits an ordered
/// list of `ContentUnit`s with explicit `pageBreak` units between
/// pages (carrying the page index in `metadata.pageNumber`) and
/// prose / image units for each page's content. Page-aware
/// affordances (TOC page-jump, etc.) derive page positions from
/// these `pageBreak` units instead of the form-feed-separated
/// `displayText` string.
///
/// Phase 2.2 background enhancement (Tier 2 Vision + Tier 3 AFM)
/// mutates the document's UNITS directly: Tier 2 rewrites a corrected
/// page's units via `DatabaseManager.replaceUnitsForPage`; Tier 3 swaps
/// fusion-repair tokens via `replaceTokenInUnits`. The legacy
/// `plain_text` / `display_text` columns were retired (Step 10) — both
/// text forms now derive from `document_units` on demand. The
/// unit-anchored embedding chunker re-runs at end-of-enhancement so the
/// chunk set reflects the corrected units.
///
/// 2026-05-23 — rewritten as part of the architecture rebuild.
struct PDFLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = PDFDocumentImporter()

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func importDocument(from url: URL) throws -> Document {
        try FormatPrecheck.checkPDF(url: url)
        let parsed = try importer.loadDocument(from: url)
        let sourceData = (try? Data(contentsOf: url)) ?? nil
        let contentHash = sourceData.map { ContentHasher.sha256($0) }
        return try persistParsedPDF(parsed, from: url, sourceData: sourceData, contentHash: contentHash)
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "pdf") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        let contentHash = ContentHasher.sha256(rawData)
        let doc = try persistAsUnits(
            parsed: parsed,
            titleFallback: title,
            fileName: fileName,
            fileType: fileType,
            contentHash: contentHash
        )
        try saveImages(parsed.images, for: doc.id)
        PageFlagsStore.write(
            flags: parsed.pageFlags,
            for: doc.id,
            fileName: fileName,
            pageCount: parsed.pageFlags.count
        )
        // 2026-05-27 — setContentBoundaries removed; derived on-demand
        // by DatabaseManager.contentBoundaries(for:).
        _ = PDFSourceStore.save(rawData, for: doc.id)
        enqueueEnhancement(documentID: doc.id, pageFlags: parsed.pageFlags)
        return doc
    }

    /// Async-friendly entry. Same shape as the legacy
    /// `persistParsedDocument(_:from:)` — kept for compatibility
    /// with PoseyApp / LocalAPI callers.
    func persistParsedDocument(_ parsed: ParsedPDFDocument, from url: URL,
                               rowProgress: (@Sendable (Int, Int) -> Void)? = nil) throws -> Document {
        let sourceData = try? Data(contentsOf: url)
        return try persistParsedPDF(
            parsed, from: url, sourceData: sourceData,
            contentHash: sourceData.map { ContentHasher.sha256($0) },
            rowProgress: rowProgress
        )
    }

    func persistParsedDocument(_ parsed: ParsedPDFDocument, from url: URL, sourceData: Data?) throws -> Document {
        try persistParsedPDF(
            parsed, from: url, sourceData: sourceData,
            contentHash: sourceData.map { ContentHasher.sha256($0) }
        )
    }

    private func persistParsedPDF(
        _ parsed: ParsedPDFDocument,
        from url: URL,
        sourceData: Data?,
        contentHash: String?,
        rowProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> Document {
        // Strip duplicate file extensions (e.g. "report.pdf.pdf" → "report.pdf").
        let rawFilename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let withoutExt = (rawFilename as NSString).deletingPathExtension
        let fileName = (withoutExt as NSString).pathExtension.lowercased() == ext ? withoutExt : rawFilename
        let titleFallback = (fileName as NSString).deletingPathExtension

        let doc = try persistAsUnits(
            parsed: parsed,
            titleFallback: titleFallback,
            fileName: fileName,
            fileType: ext,
            contentHash: contentHash,
            rowProgress: rowProgress
        )
        try saveImages(parsed.images, for: doc.id)

        PageFlagsStore.write(
            flags: parsed.pageFlags,
            for: doc.id,
            fileName: fileName,
            pageCount: parsed.pageFlags.count
        )
        // 2026-05-27 — setContentBoundaries removed; derived on-demand
        // by DatabaseManager.contentBoundaries(for:).
        if let sourceData {
            _ = PDFSourceStore.save(sourceData, for: doc.id)
        }
        enqueueEnhancement(documentID: doc.id, pageFlags: parsed.pageFlags)

        return doc
    }

    // MARK: - Unit persistence

    private func persistAsUnits(
        parsed: ParsedPDFDocument,
        titleFallback: String,
        fileName: String,
        fileType: String,
        contentHash: String?,
        rowProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> Document {
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            displayText: parsed.displayText,
            contentHash: contentHash
        )
        let documentID = existingDocument?.id ?? UUID()
        // Bundle 2a — prefer PDF metadata title, else cleaned filename.
        let title = TitleExtractor.resolve(
            contentTitle: parsed.title,
            filename: titleFallback
        )

        // ── Build content units.
        let units: [ContentUnit]
        let tocEntries: [StoredTOCEntry]
        let normalizedTOCEntries = Self.coalesceWrappedTOCEntries(
            parsed.tocEntries.map(Self.normalizeTOCEntry)
        )

        if !parsed.linesByPage.isEmpty {
            // PDF rebuild (2026-06-29): line-based construction + identity heading
            // anchoring. Clean PDFKit-native lines → paragraph + heading units;
            // each known title resolved to its real heading LINE (the weightiest
            // standout appearance — Mark's "pool the appearances, keep the
            // weightiest") → that line becomes a `.heading` unit → the TOC entry
            // anchors to it by UUID. No page numbers, no cross-layer offsets.
            // Strip recurring page furniture (running headers/footers, page-number
            // stamps, banners) BEFORE deriving headings or building units, so the
            // font profile isn't polluted and furniture never becomes a prose unit.
            // General + safe (position+recurrence); see PDFPageFurnitureDetector.
            let furniture = PDFPageFurnitureDetector.detect(in: parsed.linesByPage)
            let cleanLinesByPage = furniture.cleaned
            if !furniture.removed.isEmpty {
                let summary = furniture.removed.prefix(5)
                    .map { "\"\($0.sample.prefix(40))\"×\($0.pages)" }.joined(separator: ", ")
                print("🧹 PDF furniture removed (\(furniture.removed.count) signatures): \(summary)")
            }

            let allLines = cleanLinesByPage.flatMap { $0 }
            // Fence off the front matter (contents page + per-chapter synopses) so a
            // title's prominent front-matter copy can't win over its real body heading
            // — GEB prints every chapter title up front (contents + synopses), and those
            // copies form an in-order chain that would otherwise fool the order-aligner
            // (measured 2026-07-03). We have no line-space body-start: the skip offset
            // lives in the SEPARATE `plainText` extraction, so an exact offset→line map
            // would be fragile cross-ruler math (Position Rule). A fence doesn't need
            // exact — it only EXCLUDES candidates (the heading still anchors by identity),
            // and the front matter is well separated from the first real chapter — so map
            // the skip by FRACTION of the document. skip==0 (papers/novels/no-TOC) → no
            // fence, which is correct: those have no front-matter title cluster.
            var bodyStartIndex = 0
            if parsed.tocSkipUntilOffset > 0, parsed.plainText.count > 0 {
                let frac = min(1.0, Double(parsed.tocSkipUntilOffset) / Double(parsed.plainText.count))
                let totalChars = allLines.reduce(0) { $0 + $1.text.count }
                if totalChars > 0 {
                    let target = Int(frac * Double(totalChars))
                    var acc = 0
                    for (i, l) in allLines.enumerated() {
                        if acc >= target { bodyStartIndex = i; break }
                        acc += l.text.count
                    }
                    // Safety: never fence past the first quarter — a real front matter is
                    // small; a larger skip is likelier wrong than a 25%+ front matter, and
                    // over-fencing would silently drop real early chapters.
                    bodyStartIndex = min(bodyStartIndex, allLines.count / 4)
                }
            }
            // A/B heading maps (Mark, 2026-07-05): the existing built-in resolver
            // vs the style-inference scorer; keep whichever produces the stronger
            // map by `mapQuality`. This comparison IS the reliability gate — when
            // the built-in structure is garbage (e.g. the merged-PDF SAG-AFTRA CBA,
            // whose printed-TOC parse and bookmark tree are both unusable) the
            // scored map wins; when it's already good (GEB, the working docs) the
            // built-in wins and nothing changes.
            let seedTitles = normalizedTOCEntries.map { $0.title }
            let builtinMap = PDFHeadingKeyDeriver.resolveHeadings(
                titles: seedTitles, allLines: allLines, bodyStartIndex: bodyStartIndex)
            let choice = Self.chooseHeadingMap(
                builtin: builtinMap, seedTitles: seedTitles, allLines: allLines)
            let mergedHeadings = Self.mergeResolvedHeadingLines(
                resolved: choice.map,
                allLines: allLines
            )
            let mergedLinesByPage = Self.rebuildPages(
                from: cleanLinesByPage,
                mergedHeadings: mergedHeadings
            )
            let headingLineSet = Set(mergedHeadings.map { $0.line })
            // The navigable TOC source. When the SEEDLESS engine won, the printed
            // TOC/bookmarks were garbage (CBA: filename bookmarks + scrambled
            // multi-column contents) — so the navigator must be REBUILT from the
            // sections the engine actually found, or it stays empty/junk. Each
            // synthesized entry's title is the seedless heading's title, which is
            // exactly what `mergeResolvedHeadingLines` keyed the heading unit on, so
            // it anchors by identity through the same proven machinery below. When
            // the BUILT-IN won (GEB and the healthy docs), keep the printed TOC
            // untouched — nothing changes for them.
            // Body-derived path: the contents entry DISPLAYS the merged heading line
            // (`h.line.text`), which carries the section number for a split heading
            // ("21. Dressing Rooms…") and the whole line for a joined one. This is
            // display only — the entry links to its unit by identity below, so this
            // title can say anything without affecting the link (Mark, 2026-07-05).
            let effectiveTOCEntries: [PDFTOCEntry] = choice.usedSeedless
                ? mergedHeadings.enumerated().map { i, h in
                    PDFTOCEntry(title: h.line.text, plainTextOffset: 0, playOrder: i + 1, level: 1)
                }
                : normalizedTOCEntries
            let levelByTitle = Dictionary(effectiveTOCEntries.map { ($0.title, $0.level) },
                                          uniquingKeysWith: { a, _ in a })
            var levelByLineText: [String: Int] = [:]
            for r in mergedHeadings { levelByLineText[r.line.text] = levelByTitle[r.title] ?? 1 }
            // For the heading UNIT's title styling (titleLength): the body-derived path
            // has no separate printed title, so the whole merged line IS the heading
            // ("21. Dressing Rooms…" renders entirely as a heading). The built-in path
            // keeps its printed title so a "1 Introduction Recurrent models…" line styles
            // only "Introduction" as the heading and the rest as prose.
            let titleByHeadingLine = Dictionary(
                mergedHeadings.map { ($0.line, choice.usedSeedless ? $0.line.text : $0.title) },
                uniquingKeysWith: { a, _ in a })

            // Reconnect stored PDF renders (CC#20) + place extracted figures at
            // their vertical position (CC#22): pass each image's 0-based sheet index
            // AND its figure-top (nil = whole-sheet render placed between pages; set
            // = embedded figure placed among the page's lines). The line stream omits
            // image-only sheets, so without this images are orphaned. Reflowable
            // formats leave pageIndex nil; not applicable here.
            let pdfImages: [(pageIndex: Int, imageID: String, yTop: Double?)] = parsed.images.compactMap { img in
                img.pageIndex.map { (pageIndex: $0, imageID: img.imageID, yTop: img.figureYTop) }
            }
            units = ContentUnitBuilder.unitsFromPDFLines(
                mergedLinesByPage, documentID: documentID,
                images: pdfImages,
                isHeading: { headingLineSet.contains($0) },
                headingLevel: { levelByLineText[$0.text] ?? 1 },
                headingTitle: { titleByHeadingLine[$0] },
                rowProgress: rowProgress)

            // Link each contents entry to its heading unit by IDENTITY on the one
            // ruler — never by matching text. Heading units are emitted in document
            // order, one-to-one with `mergedHeadings` (both position-sorted), so the
            // k-th heading unit IS the k-th resolved heading. Each entry resolves an
            // anchor LINE, then gets that line's unit by identity:
            //   • body-derived path: the entry IS the k-th resolved heading (by order).
            //   • built-in path: the printed entry finds its anchor by its own SOURCE
            //     title (the resolver's title→location contract), never by a display
            //     value; the line→unit step is still pure identity.
            // The displayed contents title (which may carry a section number) is
            // decoupled from the link, so changing it can never break navigation — the
            // failure that a text-match link produced (Mark, 2026-07-05).
            let headingUnits = units.filter { $0.kind == .heading }
            let unitIDByHeadingLine: [PDFTextLine: UUID] =
                headingUnits.count == mergedHeadings.count
                ? Dictionary(zip(mergedHeadings.map { $0.line }, headingUnits.map { $0.id }),
                             uniquingKeysWith: { a, _ in a })
                : [:]   // guard: if the 1:1 alignment ever fails, drop to the fallback
            let anchorLineByTitle = Dictionary(mergedHeadings.map { ($0.title, $0.line) },
                                               uniquingKeysWith: { a, _ in a })
            var claimedUnitIDs = Set<UUID>()
            tocEntries = effectiveTOCEntries.enumerated().compactMap { (i, e) in
                let anchorLine: PDFTextLine? = choice.usedSeedless
                    ? (i < mergedHeadings.count ? mergedHeadings[i].line : nil)
                    : anchorLineByTitle[e.title]
                var unitID: UUID? = nil
                if let line = anchorLine, let id = unitIDByHeadingLine[line],
                   !claimedUnitIDs.contains(id) {
                    unitID = id
                }
                if unitID == nil {
                    // never-fail-silently fallback: nearest UNCLAIMED heading whose
                    // title matches AND section number is compatible; else drop. Keeps
                    // near-identical legal titles (CBA §5.2/§7) from piling onto §4 —
                    // no distinct in-order anchor → the entry is honestly dropped.
                    let eNum = PDFHeadingKeyDeriver.leadingSectionNumber(e.title)
                    unitID = units.first { u in
                        guard u.kind == .heading, !claimedUnitIDs.contains(u.id),
                              PDFHeadingKeyDeriver.titleMatches(title: e.title, text: u.text)
                        else { return false }
                        if let en = eNum, let un = PDFHeadingKeyDeriver.leadingSectionNumber(u.text),
                           en != un { return false }
                        return true
                    }?.id
                }
                guard let uid = unitID else { return nil }
                claimedUnitIDs.insert(uid)
                return StoredTOCEntry(title: Self.normalizeTOCTitle(e.title),
                                      plainTextOffset: e.plainTextOffset,
                                      unitID: uid, playOrder: e.playOrder, level: e.level)
            }
        } else {
            // Legacy displayText path — pure-OCR / image-text docs that yield no
            // clean line stream. Heading promotion + TOC anchoring by offset.
            let baseUnits = ContentUnitBuilder.unitsFromPDFDisplayText(
                parsed.displayText, documentID: documentID)
            // Tolerate duplicate offsets (front-matter / repeated titles); never trap.
            let headingMarkersByOffset: [Int: ContentUnitBuilder.HeadingMarker] = Dictionary(
                normalizedTOCEntries.map {
                    ($0.plainTextOffset, ContentUnitBuilder.HeadingMarker(level: $0.level, title: $0.title))
                },
                uniquingKeysWith: { first, _ in first })
            units = ContentUnitBuilder.applyHeadingMarkers(
                to: baseUnits,
                headingMarkersByOffset: headingMarkersByOffset,
                skipUnitID: ContentUnitBuilder.firstUnit(
                    in: baseUnits, atOrAfterPlainTextOffset: parsed.tocSkipUntilOffset)?.id)
            tocEntries = normalizedTOCEntries.compactMap { e in
                guard let uid = ContentUnitBuilder.firstUnit(
                    in: units, atOrAfterPlainTextOffset: e.plainTextOffset)?.id else { return nil }
                return StoredTOCEntry(title: e.title, plainTextOffset: e.plainTextOffset,
                                      unitID: uid, playOrder: e.playOrder, level: e.level)
            }
        }

        // ── Sentences from prose-bearing units.
        let sentences = SentenceIndexer.sentences(for: units)

        // ── Smart-skip: map the plainText skip offset to a unit (best-effort).
        let skipOffset = parsed.tocSkipUntilOffset
        let skipUnitID = ContentUnitBuilder.firstUnit(in: units, atOrAfterPlainTextOffset: skipOffset)?.id
        let skipSource = skipOffset > 0 ? "heuristic" : ""

        let parsedDoc = ParsedDocument(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            units: units,
            sentences: sentences,
            toc: tocEntries,
            skipUnitID: skipUnitID,
            skipSource: skipSource,
            playbackSkipUntilOffset: skipOffset,
            contentEndOffset: 0,
            contentEndUnitID: nil,
            contentHash: contentHash,
            editionLabel: nil
        )
        try databaseManager.persistParsedDocument(parsedDoc)

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: documentID))
        }

        let now = Date()
        let document = Document(
            id: documentID,
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            characterCount: parsed.plainText.count,
            playbackSkipUntilOffset: skipOffset,
            skipSource: skipSource,
            contentHash: contentHash
        )

        // PDF embedding indexing is still deferred to end-of-Tier-3
        // by PDFEnhancementService so embeddings are built against
        // the corrected text rather than Tier 1's first pass.
        // Nothing to enqueue here.

        return document
    }

    /// A/B the two heading maps and return the stronger one (Mark, 2026-07-05).
    /// Built-in = `PDFHeadingKeyDeriver.resolveHeadings`; scored = the
    /// `PDFHeadingScorer` style-inference engine. `mapQuality` (coverage × reading
    /// order × confidence) picks the winner — the reliability gate falls out of the
    /// comparison, so no hand-built "is the built-in trustworthy?" heuristic is
    /// needed. Logs both scores so the decision is visible on the phone.
    static func chooseHeadingMap(builtin: [(title: String, line: PDFTextLine)],
                                 seedTitles: [String],
                                 allLines: [PDFTextLine]) -> (map: [(title: String, line: PDFTextLine)], usedSeedless: Bool) {
        // STEP 1 — CONDITIONAL GATE (Mark, 2026-07-05). Before paying for the
        // seedless engine, check whether the built-in TOC is ALREADY trustworthy on
        // font-independent evidence: did most printed-TOC titles anchor to real body
        // lines (placement), and do those anchors run in reading order (order)? A
        // genuine TOC (GEB: 45 chapters in order) clears this easily; a garbage
        // merged-PDF TOC (CBA: filename bookmarks) does not. When it's clearly
        // healthy we RETURN the built-in and never run the seedless detector —
        // protecting good docs from its cost and its endnote/citation noise.
        //
        // The bar is deliberately HIGH (near-complete placement + perfect order): the
        // only real risk is SKIPPING seedless on a doc that needed it, so we err
        // toward running it. Even a borderline doc that slips through still gets the
        // 1.3× A/B safety margin below, so a mis-set threshold costs speed, not
        // correctness. Numbers are logged so the decision is measurable, not guessed.
        //
        // Threshold measured on the phone (2026-07-05): GEB placedRatio 0.92 (45/49,
        // a genuinely complete TOC) vs CBA 0.60 (24/40 — only the SCHEDULE labels
        // place; the whole General Provisions §-list is ABSENT from the printed TOC).
        // A partial-but-in-order TOC (CBA) must NOT count as healthy, so the bar sits
        // at 0.80 — above CBA, comfortably below GEB. placement+order can't detect an
        // INCOMPLETE TOC on its own, so anything under the bar falls through to the
        // A/B gate, which is where CBA's real sections get recovered.
        let health = PDFHeadingScorer.builtinHealth(
            map: builtin, seedCount: seedTitles.count, allLines: allLines)
        if health.placed >= 4, health.placedRatio >= 0.80, health.orderRatio >= 0.90 {
            print("[HeadingAB] builtin HEALTHY placed=\(health.placed)/\(seedTitles.count) placedRatio=\(String(format: "%.2f", health.placedRatio)) orderRatio=\(String(format: "%.2f", health.orderRatio)) -> builtin (seedless SKIPPED)")
            return (builtin, false)
        }

        let profile = PDFHeadingScorer.deriveProfile(seedTitles: seedTitles, allLines: allLines)
        let builtinScored = builtin.map {
            (title: $0.title, line: $0.line,
             score: PDFHeadingScorer.resemblance($0.line, profile: profile))
        }
        let qBuiltin = PDFHeadingScorer.mapQuality(builtinScored, allLines: allLines)

        // Map B — the SEEDLESS detector builds its own map from the pages (no
        // reliance on the built-in title list). Keep only strong candidates; a real
        // section heading scores high, prose-that-starts-with-a-number scores low
        // (measured on CBA: real sections ≈0.83, body sentences ≤0.62).
        let seedlessStrong = PDFHeadingScorer.detectHeadingsFromPages(allLines: allLines)
            .filter { $0.score >= 0.65 }
        let seedlessMapForQ = seedlessStrong.map { (title: $0.line.text, line: $0.line, score: $0.score) }
        let qSeedless = PDFHeadingScorer.mapQuality(seedlessMapForQ, allLines: allLines)

        // SAFETY MARGIN: only let the seedless map override the built-in when it is
        // CLEARLY stronger (≥1.3×). This is the reliability gate — it fires when the
        // built-in structure is garbage (CBA: built-in ~17 vs seedless in the
        // hundreds) but never displaces an already-good built-in map (GEB).
        let winner: String
        let result: [(title: String, line: PDFTextLine)]
        if qSeedless > qBuiltin * 1.3, seedlessStrong.count >= 3 {
            winner = "SEEDLESS"; result = seedlessStrong.map { (title: $0.line.text, line: $0.line) }
        } else {
            winner = "builtin"; result = builtin
        }
        print("[HeadingAB] builtin q=\(String(format: "%.1f", qBuiltin)) n=\(builtin.count) health(placed=\(health.placed)/\(seedTitles.count) order=\(String(format: "%.2f", health.orderRatio)))  vs  seedless q=\(String(format: "%.1f", qSeedless)) n=\(seedlessStrong.count)  ->  \(winner)")
        return (result, winner == "SEEDLESS")
    }

    struct MergedResolvedHeading {
        let title: String
        let line: PDFTextLine
        let consumedLines: [PDFTextLine]
    }

    private static let headingStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "before", "between", "but",
        "by", "for", "from", "in", "into", "is", "it", "of", "on", "or", "the",
        "to", "under", "which", "with"
    ]

    static func mergeResolvedHeadingLines(
        resolved: [(title: String, line: PDFTextLine)],
        allLines: [PDFTextLine]
    ) -> [MergedResolvedHeading] {
        guard !resolved.isEmpty, !allLines.isEmpty else { return [] }

        let indexByLine = Dictionary(uniqueKeysWithValues: allLines.enumerated().map { ($1, $0) })
        let resolvedWithIndex = resolved.compactMap { item -> (title: String, line: PDFTextLine, index: Int)? in
            guard let index = indexByLine[item.line] else { return nil }
            return (item.title, item.line, index)
        }.sorted { $0.index < $1.index }

        var merged: [MergedResolvedHeading] = []
        var floorIndex = 0

        for (offset, item) in resolvedWithIndex.enumerated() {
            let nextIndex = offset + 1 < resolvedWithIndex.count ? resolvedWithIndex[offset + 1].index : allLines.count
            let titleWords = Set(headingMatchWords(item.title))
            var start = item.index
            var end = item.index

            while start > floorIndex {
                let candidate = allLines[start - 1]
                let current = allLines[start]
                guard headingLinesAreAdjacent(candidate, current) else { break }
                guard headingNeighborBelongsToTitle(
                    candidate,
                    relativeTo: current,
                    currentMergedLines: Array(allLines[start...end]),
                    title: item.title,
                    titleWords: titleWords,
                    direction: .backward
                ) else { break }
                start -= 1
            }

            while end + 1 < nextIndex {
                let current = allLines[end]
                let candidate = allLines[end + 1]
                guard headingLinesAreAdjacent(current, candidate) else { break }
                guard headingNeighborBelongsToTitle(
                    candidate,
                    relativeTo: current,
                    currentMergedLines: Array(allLines[start...end]),
                    title: item.title,
                    titleWords: titleWords,
                    direction: .forward
                ) else { break }
                end += 1
            }

            let consumed = Array(allLines[start...end])
            let mergedText = normalizeTOCTitle(consumed.map(\.text).joined(separator: " "))
            let first = consumed.first ?? item.line
            let last = consumed.last ?? item.line
            let mergedLine = PDFTextLine(
                text: mergedText,
                fontSize: consumed.map(\.fontSize).max() ?? first.fontSize,
                isBold: consumed.contains { $0.isBold },
                isAllCaps: consumed.allSatisfy { $0.isAllCaps },
                indentX: first.indentX,
                midX: consumed.map(\.midX).reduce(0, +) / Double(consumed.count),
                yTop: first.yTop,
                yBottom: last.yBottom,
                gapAbove: first.gapAbove,
                pageIndex: first.pageIndex
            )
            merged.append(MergedResolvedHeading(title: item.title, line: mergedLine, consumedLines: consumed))
            floorIndex = end + 1
        }

        return merged
    }

    static func rebuildPages(
        from linesByPage: [[PDFTextLine]],
        mergedHeadings: [MergedResolvedHeading]
    ) -> [[PDFTextLine]] {
        guard !mergedHeadings.isEmpty else { return linesByPage }

        let mergedByFirstLine = Dictionary(uniqueKeysWithValues: mergedHeadings.compactMap { heading in
            heading.consumedLines.first.map { ($0, heading) }
        })
        let consumedNonStarts = Set(mergedHeadings.flatMap { Array($0.consumedLines.dropFirst()) })

        return linesByPage.map { page in
            var rebuilt: [PDFTextLine] = []
            for line in page {
                if let merged = mergedByFirstLine[line] {
                    rebuilt.append(merged.line)
                } else if !consumedNonStarts.contains(line) {
                    rebuilt.append(line)
                }
            }
            return rebuilt
        }
    }

    private enum HeadingMergeDirection {
        case backward
        case forward
    }

    private static func headingNeighborBelongsToTitle(
        _ line: PDFTextLine,
        relativeTo reference: PDFTextLine,
        currentMergedLines: [PDFTextLine],
        title: String,
        titleWords: Set<String>,
        direction: HeadingMergeDirection
    ) -> Bool {
        let words = Set(headingMatchWords(line.text))
        let informativeWords = Set(headingWords(line.text).filter { !headingStopWords.contains($0) })
        let purityDenominator = informativeWords.isEmpty ? words.count : informativeWords.count
        let overlap = titleWords.intersection(words).count
        let pureShortTitleLine = overlap >= 2
            && line.text.count <= 90
            && words.count <= 6
            && Double(overlap) / Double(max(purityDenominator, 1)) >= 0.75
        let canAdvanceFromReference = headingLinesShareStyle(reference, line)
            || isHeadingLabelLine(reference.text)
            || PDFHeadingKeyDeriver.isNumericHeadingLabelLine(reference.text)
        if direction == .forward,
           (isHeadingLabelLine(reference.text) || PDFHeadingKeyDeriver.isNumericHeadingLabelLine(reference.text)),
           pureShortTitleLine,
           looksLikeChapterTitleFragment(line.text) {
            return true
        }
        if overlap >= 2, line.text.count <= 120, words.count <= max(10, titleWords.count + 2) {
            if direction == .forward,
               !(line.isAllCaps || line.isBold || (pureShortTitleLine && canAdvanceFromReference)) {
                return false
            }
            return true
        }
        if direction == .forward,
           headingLinesShareStyle(reference, line),
           combinedHeadingProgressesTitle(
            existingLines: currentMergedLines,
            candidate: line,
            title: title
           ) {
            return true
        }
        if direction == .forward,
           headingLinesShareStyle(reference, line),
           looksLikeHeadingContinuationFragment(reference.text),
           looksLikeHeadingContinuationFragment(line.text) {
            return true
        }
        guard direction == .backward else { return false }
        if headingLinesShareStyle(reference, line),
           looksLikeHeadingContinuationFragment(line.text),
           looksLikeHeadingContinuationFragment(reference.text) {
            return true
        }
        return isHeadingLabelLine(line.text) || PDFHeadingKeyDeriver.isNumericHeadingLabelLine(line.text)
    }

    private static func combinedHeadingProgressesTitle(
        existingLines: [PDFTextLine],
        candidate: PDFTextLine,
        title: String
    ) -> Bool {
        guard !existingLines.isEmpty else { return false }

        let existingText = normalizeTOCTitle(existingLines.map(\.text).joined(separator: " "))
        let combinedText = normalizeTOCTitle((existingLines.map(\.text) + [candidate.text]).joined(separator: " "))
        let existingTokens = headingMatchWords(existingText)
        let combinedTokens = headingMatchWords(combinedText)
        let candidateTokens = headingMatchWords(candidate.text)

        guard !existingTokens.isEmpty, !combinedTokens.isEmpty, !candidateTokens.isEmpty else { return false }
        guard combinedTokens.count > existingTokens.count else { return false }
        guard candidate.text.count <= 90, candidateTokens.count <= 6 else { return false }

        for variant in headingTitleWordVariants(title) {
            let existingPrefixCount = orderedTitlePrefixCount(
                candidateTokens: existingTokens,
                titleTokens: variant
            )
            let combinedPrefixCount = orderedTitlePrefixCount(
                candidateTokens: combinedTokens,
                titleTokens: variant
            )
            if combinedPrefixCount > existingPrefixCount {
                return true
            }
        }

        return false
    }

    private static func headingLinesAreAdjacent(_ upper: PDFTextLine, _ lower: PDFTextLine) -> Bool {
        guard upper.pageIndex == lower.pageIndex else { return false }
        let sameRow = abs(upper.yTop - lower.yTop) <= 4 && abs(upper.yBottom - lower.yBottom) <= 4
        if sameRow { return true }
        let gap = upper.yBottom - lower.yTop
        return gap <= 32 && gap >= -6
    }

    private static func headingWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func headingMatchWords(_ text: String) -> [String] {
        let base = headingWords(text)
        let filtered = base.filter { !headingStopWords.contains($0) }
        return filtered.count >= 3 ? filtered : base
    }

    private static func headingLinesShareStyle(_ lhs: PDFTextLine, _ rhs: PDFTextLine) -> Bool {
        abs(lhs.fontSize - rhs.fontSize) <= 1.5
            && lhs.isBold == rhs.isBold
            && lhs.isAllCaps == rhs.isAllCaps
    }

    private static func looksLikeHeadingContinuationFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return false }
        guard !trimmed.hasSuffix("."),
              !trimmed.hasSuffix("!"),
              !trimmed.hasSuffix("?"),
              !trimmed.hasSuffix(":"),
              !trimmed.hasSuffix(";")
        else { return false }
        guard !startsWithHeadingMarker(trimmed) else { return false }
        return headingWords(trimmed).count >= 4
            || hasTrailingContinuationCue(trimmed)
            || looksLikeShortTerminalHeadingFragment(trimmed)
    }

    static func coalesceWrappedTOCEntries(_ entries: [PDFTOCEntry]) -> [PDFTOCEntry] {
        guard entries.count > 1 else { return entries }

        var coalesced: [PDFTOCEntry] = []
        for entry in entries {
            if let previous = coalesced.last, shouldMergeWrappedTOCEntry(previous: previous, current: entry) {
                coalesced[coalesced.count - 1] = PDFTOCEntry(
                    title: normalizeTOCTitle(previous.title + " " + entry.title),
                    plainTextOffset: previous.plainTextOffset,
                    playOrder: previous.playOrder,
                    level: previous.level
                )
            } else {
                coalesced.append(entry)
            }
        }

        return coalesced
    }

    private static func shouldMergeWrappedTOCEntry(previous: PDFTOCEntry, current: PDFTOCEntry) -> Bool {
        guard previous.level == current.level else { return false }
        guard current.playOrder == previous.playOrder + 1 else { return false }
        guard startsWithHeadingMarker(previous.title) else { return false }
        guard !startsWithHeadingMarker(current.title) else { return false }
        guard abs(current.plainTextOffset - previous.plainTextOffset) <= 600 else { return false }
        guard looksLikeWrappedHeadingPrefix(previous.title) else { return false }
        return looksLikeHeadingContinuationFragment(current.title)
    }

    private static func isHeadingLabelLine(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"(?i)^(chapter|part|section|appendix|article|book)\s+[ivxlcdm\d]{1,8}\b[.:]?$"#,
                   options: .regularExpression) != nil
    }

    static func normalizeTOCEntry(_ entry: PDFTOCEntry) -> PDFTOCEntry {
        PDFTOCEntry(
            title: normalizeTOCTitle(entry.title),
            plainTextOffset: entry.plainTextOffset,
            playOrder: entry.playOrder,
            level: entry.level
        )
    }

    static func normalizeTOCTitle(_ title: String) -> String {
        let trimmed = deduplicatedHeadingMarkerPrefix(
            in: title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let embeddedRange = embeddedSectionMarkerRange(in: trimmed) else { return trimmed }
        return String(trimmed[embeddedRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func startsWithHeadingMarker(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"(?i)^(?:(?:\d{1,3}(?:\.\d{1,3}){0,3}\.?)|(chapter|part|section|appendix|article|book)\s+[ivxlcdm\d]{1,8}\.?)\s+\S"#,
            options: .regularExpression
        ) != nil
    }

    private static func hasTrailingContinuationCue(_ title: String) -> Bool {
        guard let lastWord = headingWords(title).last else { return false }
        return [
            "of", "the", "and", "for", "to", "in", "on", "with",
            "from", "after", "before", "between", "under", "over"
        ].contains(lastWord)
    }

    private static func looksLikeShortTerminalHeadingFragment(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = headingWords(trimmed)
        guard !words.isEmpty, words.count <= 4 else { return false }
        if trimmed.range(
            of: #"^(?i:(january|february|march|april|may|june|july|august|september|october|november|december))\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if trimmed.range(of: #"\b\d{4,5}\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeChapterTitleFragment(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = headingWords(trimmed)
        guard !trimmed.isEmpty, trimmed.count <= 90, words.count >= 2, words.count <= 6 else { return false }
        guard let firstLetter = trimmed.first(where: { $0.isLetter }), firstLetter.isUppercase else { return false }
        guard !trimmed.hasSuffix("."), !trimmed.hasSuffix("!"), !trimmed.hasSuffix("?"), !trimmed.hasSuffix(";") else {
            return false
        }
        return true
    }

    private static func looksLikeWrappedHeadingPrefix(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasSuffix("."),
              !trimmed.hasSuffix("!"),
              !trimmed.hasSuffix("?"),
              !trimmed.hasSuffix(":"),
              !trimmed.hasSuffix(";")
        else { return false }

        let words = headingWords(trimmed)
        guard !words.isEmpty, words.count <= 14 else { return false }
        if hasTrailingContinuationCue(trimmed) {
            return true
        }

        guard let lastWord = words.last else { return false }
        if lastWord.count <= 3 {
            return true
        }

        return words.count <= 8
    }

    private static func embeddedSectionMarkerRange(in title: String) -> Range<String.Index>? {
        guard let range = title.range(
            of: #"\b\d{1,3}(?:\.\d{1,3}){0,3}\.?\s+[A-Z]"#,
            options: .regularExpression
        ) else { return nil }

        let prefix = title[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.count >= 12 else { return nil }
        guard prefix.rangeOfCharacter(from: .lowercaseLetters) != nil else { return nil }
        return range
    }

    private static func deduplicatedHeadingMarkerPrefix(in title: String) -> String {
        title.replacingOccurrences(
            of: #"^(?i:[ivxlcdm]{1,8}\s+)((?:chapter|part|section|appendix|article|book)\s+[ivxlcdm\d]{1,8}\b.*)$"#,
            with: "$1",
            options: .regularExpression
        )
    }

    private static func headingTitleWordVariants(_ title: String) -> [[String]] {
        var variants: [[String]] = []

        let full = headingMatchWords(title)
        if !full.isEmpty { variants.append(full) }

        let stripped = title.replacingOccurrences(
            of: #"^(?i:(chapter|part|section|appendix|article|book)\s+[ivxlcdm\d]{1,8}\s*[:.]?\s*)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty {
            let tail = headingMatchWords(stripped)
            if tail.count >= 2, !variants.contains(tail) {
                variants.append(tail)
            }
        }

        return variants
    }

    private static func orderedTitlePrefixCount(candidateTokens: [String], titleTokens: [String]) -> Int {
        guard !candidateTokens.isEmpty, !titleTokens.isEmpty else { return 0 }
        var matched = 0
        for (lhs, rhs) in zip(candidateTokens, titleTokens) {
            if normalizedHeadingToken(lhs) != normalizedHeadingToken(rhs) {
                break
            }
            matched += 1
        }
        return matched
    }

    private static func normalizedHeadingToken(_ token: String) -> String {
        token.localizedLowercase
            .replacingOccurrences(of: "l", with: "1")
            .replacingOccurrences(of: "i", with: "1")
    }

    /// 2026-05-22 Phase 2.2 Step 4 — bridge to the background
    /// `PDFEnhancementService`. Marks the doc enhancement-pending and
    /// hands it to the service queue; Tier 2/3 mutate the units directly
    /// (see the type-level doc above).
    private func enqueueEnhancement(documentID: UUID, pageFlags: [PDFPageFlags]) {
        do {
            try databaseManager.updateEnhancementState(
                documentID: documentID,
                status: "pending",
                error: nil
            )
        } catch {
            dbgLog("PDFLibraryImporter: failed to mark enhancement pending for %@: %@",
                   documentID.uuidString, String(describing: error))
        }
        Task {
            await PDFEnhancementService.shared.enqueue(documentID)
        }
    }

    private func saveImages(_ images: [PageImageRecord], for documentID: UUID) throws {
        try databaseManager.deleteImages(for: documentID)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: documentID, data: image.data)
        }
    }
}

// ========== BLOCK 01: PDF LIBRARY IMPORTER (UNITS) - END ==========
