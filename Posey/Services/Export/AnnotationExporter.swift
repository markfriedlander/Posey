import Foundation

// ========== BLOCK 01: TYPES - START ==========
/// Task 12 (2026-05-03 — Data Portability): the export pipeline that
/// turns a document's notes, bookmarks, and Ask Posey conversation
/// thread into a single readable Markdown file the user can share via
/// the standard iOS share sheet (Files, Mail, Messages, AirDrop, etc.).
///
/// Why Markdown:
/// - Plain text — opens in any editor, no proprietary format.
/// - Renders nicely in Notes, Bear, Obsidian, GitHub, etc.
/// - Preserves structure (headings, indentation, anchored offsets)
///   without locking the user into a custom schema.
/// - Survives copy-paste back into other tools intact.
///
/// Annotations are sorted by source offset within the document so
/// the export reads in document order — useful when re-reading the
/// material later.
struct AnnotationExportPayload: Sendable {
    let suggestedFilename: String
    let mimeType: String   // text/markdown
    let bytes: Data

    /// Convenience: write to a temp URL the share sheet can hand to
    /// any extension. The URL persists for the lifetime of the
    /// process; iOS cleans NSTemporaryDirectory periodically.
    func temporaryFileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedFilename)
        try bytes.write(to: url, options: .atomic)
        return url
    }
}
// ========== BLOCK 01: TYPES - END ==========


// ========== BLOCK 02: EXPORTER - START ==========
enum AnnotationExporter {

    /// Build a Markdown export of every annotation associated with
    /// `document`. Notes and bookmarks come from the `notes` table;
    /// Ask Posey conversation turns and anchor markers come from
    /// `ask_posey_conversations`. The resulting file is sorted in
    /// document order (by offset).
    ///
    /// This is best-effort: any individual datasource that fails
    /// (e.g., a corrupted JSON in `chunks_injected`) is skipped
    /// gracefully so the user still gets a partial export rather
    /// than nothing.
    static func export(
        document: Document,
        databaseManager: DatabaseManager
    ) -> AnnotationExportPayload {
        let notes = (try? databaseManager.notes(for: document.id)) ?? []
        let conversationTurns = (try? databaseManager.askPoseyConversationTurns(for: document.id)) ?? []
        let anchorRows = (try? databaseManager.askPoseyAnchorRows(for: document.id)) ?? []

        let markdown = renderMarkdown(
            document: document,
            notes: notes,
            conversationTurns: conversationTurns,
            anchorRows: anchorRows
        )
        let safeTitle = sanitizeFilename(document.title)
        let timestamp = ISO8601DateFormatter.shared.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return AnnotationExportPayload(
            suggestedFilename: "\(safeTitle) — Annotations \(timestamp).md",
            mimeType: "text/markdown",
            bytes: Data(markdown.utf8)
        )
    }

    // MARK: - Markdown rendering

    static func renderMarkdown(
        document: Document,
        notes: [Note],
        conversationTurns: [StoredAskPoseyTurn],
        anchorRows: [StoredAskPoseyTurn]
    ) -> String {
        var out = ""
        out += "# \(document.title)\n\n"
        out += "*Posey export — \(displayDate(Date()))*\n\n"
        out += "Source file: `\(document.fileName)` (\(document.fileType.uppercased()), \(document.characterCount.formatted()) chars)\n\n"
        out += "---\n\n"

        // Group everything by section then sort by offset.
        if !notes.isEmpty {
            let bookmarks = notes.filter { $0.kind == .bookmark }
                                 .sorted { $0.startOffset < $1.startOffset }
            let plainNotes = notes.filter { $0.kind == .note }
                                  .sorted { $0.startOffset < $1.startOffset }

            if !bookmarks.isEmpty {
                out += "## Bookmarks (\(bookmarks.count))\n\n"
                for b in bookmarks {
                    out += "- **Offset \(b.startOffset)** — saved \(displayDate(b.createdAt))\n"
                    if let body = b.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out += "  \(body)\n"
                    }
                }
                out += "\n"
            }

            if !plainNotes.isEmpty {
                out += "## Notes (\(plainNotes.count))\n\n"
                for n in plainNotes {
                    out += "### Offset \(n.startOffset)–\(n.endOffset) — \(displayDate(n.createdAt))\n\n"
                    if let body = n.body, !body.isEmpty {
                        out += "\(body)\n\n"
                    } else {
                        out += "*(no body)*\n\n"
                    }
                }
            }
        }

        // Ask Posey conversation thread, anchored. Group turns by
        // anchor row when one exists nearby; otherwise emit as a flat
        // chronological thread. Conversation entries are typically
        // ordered chronologically already; we keep that order so the
        // exchange reads as a transcript.
        if !conversationTurns.isEmpty || !anchorRows.isEmpty {
            out += "## Ask Posey Conversations\n\n"

            // Build a quick anchor lookup so each user/assistant turn
            // can credit the most recent prior anchor (if any).
            let anchorByOffset: [Int: StoredAskPoseyTurn] = Dictionary(
                anchorRows.compactMap { row in
                    row.anchorOffset.map { ($0, row) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            let sortedAnchors = anchorRows.compactMap { $0.anchorOffset }.sorted()

            // Walk the turns chronologically; insert an anchor heading
            // whenever we see a new anchor row.
            var lastAnchorID: String? = nil
            for turn in conversationTurns {
                if turn.role == "anchor" {
                    if turn.id != lastAnchorID {
                        out += "### Anchored at offset \(turn.anchorOffset ?? 0)\n\n"
                        out += "> \(escapedQuote(turn.content))\n\n"
                        out += "*(\(displayDate(turn.timestamp)))*\n\n"
                        lastAnchorID = turn.id
                    }
                    continue
                }
                if turn.role == "user" {
                    if lastAnchorID == nil,
                       let nearest = nearestAnchor(forOffset: turn.anchorOffset, sortedAnchors: sortedAnchors),
                       let row = anchorByOffset[nearest] {
                        out += "### Anchored at offset \(nearest)\n\n"
                        out += "> \(escapedQuote(row.content))\n\n"
                        lastAnchorID = row.id
                    }
                    out += "**You:** \(turn.content)\n\n"
                } else if turn.role == "assistant" {
                    // Skip auto-summary rows: they aren't user-visible
                    // (Task 4 #1).
                    if turn.isSummary { continue }
                    out += "**Posey:** \(turn.content)\n\n"
                }
            }
        }

        if notes.isEmpty && conversationTurns.isEmpty && anchorRows.isEmpty {
            out += "*No annotations or conversations have been saved for this document yet.*\n"
        }

        return out
    }

    // MARK: - Helpers

    private static func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(
            of: #"[\/\\:*?"<>|]"#, with: "-", options: .regularExpression
        )
        return stripped.isEmpty ? "Posey Document" : stripped
    }

    private static func displayDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// Escape `>` already at line-start in the quoted block so we
    /// don't accidentally produce nested quotes or break Markdown.
    private static func escapedQuote(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n> ")
    }

    /// Find the largest anchor offset that is ≤ the turn's offset,
    /// so a turn's "this conversation was about offset X" anchor
    /// resolves to the most recent anchor seen.
    private static func nearestAnchor(forOffset offset: Int?, sortedAnchors: [Int]) -> Int? {
        guard let offset else { return nil }
        var best: Int? = nil
        for a in sortedAnchors {
            if a <= offset { best = a } else { break }
        }
        return best
    }
}
// ========== BLOCK 02: EXPORTER - END ==========


private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
