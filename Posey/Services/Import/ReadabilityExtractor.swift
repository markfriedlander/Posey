import Foundation
import Readability

// ========== BLOCK 01: READABILITY EXTRACTOR - START ==========

/// Thin shim around `Ryu0118/swift-readability` (Mozilla Readability
/// JS wrapped in WKWebView). Returns cleaned article HTML — the same
/// content Firefox Reader View extracts — with site chrome (nav,
/// sidebar, footer, related-articles, ads) stripped.
///
/// 2026-05-22 — Added after the 35-doc corpus audit confirmed every
/// real-world HTML import was extracting the entire site navigation
/// as if it were article content. swift-readability's WKWebView is
/// `@MainActor` + `async`, so callers (HTMLDocumentImporter) become
/// async too.
///
/// Hybrid threshold policy (Mark approved 2026-05-22):
///   - If Readability succeeds → return cleaned `result.content` HTML
///     (Mozilla's `<article>` extract, headings preserved, images
///     preserved as `<img>`)
///   - If Readability throws `readerIsUnavailable` → return nil so
///     the caller can fall back to NSAttributedString extraction on
///     the full raw HTML. This handles non-article HTML (rendered
///     READMEs, EPUB internal chapters, doc pages, recipe pages).
///
/// The shim never throws on its own — failure paths return nil and
/// the caller decides whether to fall back or surface an error.
enum ReadabilityExtractor {

    /// Wrap the extracted article HTML in a minimal `<html><body>`
    /// shell so the downstream NSAttributedString parser sees a
    /// well-formed document. Readability's `content` is just the
    /// inner HTML of the extracted article body — no surrounding
    /// `<html>` / `<head>` / `<body>` tags.
    static func wrap(title: String, content: String, language: String?) -> String {
        // Build a minimal but legal document. The lang attribute helps
        // NSAttributedString's renderer pick the right default font.
        let langAttr = (language?.isEmpty == false) ? " lang=\"\(language!)\"" : ""
        // A `<meta charset>` tag so any UTF-8 multibyte sequences in
        // the article body round-trip cleanly through the parser.
        return """
        <!DOCTYPE html>
        <html\(langAttr)>
        <head>
        <meta charset="utf-8">
        <title>\(htmlEscape(title))</title>
        </head>
        <body>
        \(content)
        </body>
        </html>
        """
    }

    private static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Run Mozilla Readability over the given HTML. Returns the
    /// cleaned + shelled HTML on success, nil on failure.
    /// Failure cases are silent on purpose — callers fall back.
    @MainActor
    static func extractArticleHTML(rawHTML: String, baseURL: URL?) async -> String? {
        let readability = Readability()
        do {
            let result = try await readability.parse(
                html: rawHTML,
                options: nil,
                baseURL: baseURL
            )
            // 2026-05-22 — Mozilla's default `charThreshold` is 500;
            // pages with less than that throw `readerIsUnavailable`.
            // Belt-and-suspenders: if we get a result but the textContent
            // is suspiciously short, treat as failure so the caller's
            // fallback gets a chance. Articles shorter than 200 chars
            // are extremely rare in real-world reading material.
            guard result.textContent.count >= 200 else { return nil }
            return wrap(title: result.title,
                        content: result.content,
                        language: result.language)
        } catch {
            return nil
        }
    }
}

// ========== BLOCK 01: READABILITY EXTRACTOR - END ==========
