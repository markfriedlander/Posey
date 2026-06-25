import UIKit

// ========== BLOCK 00: ANNOTATION SEAM TYPES - START ==========

/// What the selection menu can place. UI-agnostic on purpose (the core knows nothing
/// about Posey's `NoteKind`); the owner maps this to the domain model.
enum AnnotationKind { case note, bookmark }

/// A rendered annotation: an exact surface range to underline + a kind-glyph drawn in
/// the left margin gutter beside its first line. The underline marks WHERE + confidence
/// (solid = sure; dotted = `unsure`, text changed under it). The `symbol` (an SF Symbol
/// name) marks WHAT kind — note / bookmark / conversation. Both the underline and the
/// glyph are tap targets; `id` is opaque to the core — the owner round-trips it back.
struct SurfaceMarker {
    let id: UUID
    let surfaceRange: NSRange
    var unsure: Bool = false
    var symbol: String = "square.and.pencil"
}

// ========== BLOCK 00: ANNOTATION SEAM TYPES - END ==========

// ========== BLOCK 01: READER SURFACE (CORE SPINE) - START ==========

/// The CORE of the rebuilt reader: ONE owned UITextView (which IS its own scroll
/// view — no SwiftUI ScrollView wrapper, no reach-down into UIKit). Pure MECHANISM —
/// geometry, scroll, the single-line read-along band, hit-testing. No policy (TTS,
/// dimming, search live elsewhere). Proven in the standalone tester (scale + line-pin
/// + sentence-TTS); this is its port into Posey behind the `useNewReaderSurface` flag.
@MainActor
final class ReaderSurface: NSObject {

    let textView: UITextView
    private(set) var content: ReaderSurfaceContent
    var tuning: ReaderTuning

    /// The single line currently lit by read-along — tracked so we clear ONLY the
    /// prior line (a full-range attribute edit re-lays-out the whole book; measured
    /// ~700ms/step — the scale-test bug we fixed).
    private var activeLineRange: NSRange?

    /// Tap-to-jump (core): fires the tapped character offset. Coexists with native
    /// selection (the gesture doesn't cancel touches, so long-press selection still
    /// works). The owner resolves the offset → sentence → playback position.
    var onTap: ((Int) -> Void)?

    /// Fired when the user picks Note/Bookmark from the selection menu, with the
    /// current SURFACE selection range. The owner converts it to a canonical anchor
    /// and persists (E2 create flow).
    var onAnnotate: ((NSRange, AnnotationKind) -> Void)?

    /// Fired when the user taps an annotation's underline — the owner opens it.
    var onOpenMarker: ((UUID) -> Void)?

    /// When the owner is re-placing an unsure note ("Move it"), the selection menu
    /// offers "Move note here" instead of Note/Bookmark, and a selection fires this.
    var awaitingMove = false
    var onMoveHere: ((NSRange) -> Void)?

    /// Rendered annotations (kept so a tap can be hit-tested against their ranges and
    /// the prior underline attributes cleared on the next `setMarkers`).
    private var markers: [SurfaceMarker] = []
    /// Margin kind-glyph buttons, keyed by annotation id (repositioned on re-layout).
    private var glyphButtons: [UUID: UIButton] = [:]

    init(content: ReaderSurfaceContent, tuning: ReaderTuning = .aml) {
        self.content = content
        self.tuning = tuning
        let tv = UITextView(usingTextLayoutManager: false)   // TextKit 1 → simple layoutManager rects
        tv.isEditable = false
        tv.isSelectable = true                               // native selection, spans anything
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .clear
        // Contiguous layout: lay out once, then every rect/glide is cheap + uniform.
        tv.layoutManager.allowsNonContiguousLayout = false
        // Left inset = gutter (room for the margin kind-glyph); right = reading margin.
        tv.textContainerInset = UIEdgeInsets(top: tuning.topInset, left: tuning.gutterWidth,
                                             bottom: tuning.bottomInset, right: tuning.sideInset)
        tv.attributedText = content.attributed
        self.textView = tv
        super.init()
        tv.delegate = self                                   // selection-menu actions
        // Tap-to-jump: non-cancelling so native long-press selection still works.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let idx = charIndex(at: g.location(in: textView)) else { return }
        // A tap landing ON an annotation's underline opens it; anywhere else jumps
        // playback. Annotations are sparse, so this is unambiguous in practice.
        if let m = markers.first(where: { NSLocationInRange(idx, $0.surfaceRange) }) {
            onOpenMarker?(m.id)
        } else {
            onTap?(idx)
        }
    }

    // ========== BLOCK 02: GEOMETRY - START ==========

    /// Bounding rect of a character range in the text view's coordinate space.
    func rect(for range: NSRange) -> CGRect {
        let lm = textView.layoutManager
        lm.ensureLayout(for: textView.textContainer)   // glyphs lay out lazily; force first
        let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyph, in: textView.textContainer)
        r.origin.x += textView.textContainerInset.left
        r.origin.y += textView.textContainerInset.top
        return r
    }

    /// The character range + rect of the single VISUAL LINE the glyph at `charIndex`
    /// sits on — font/size/width-aware (it IS the laid-out result). The unit of
    /// read-along motion; this is what dissolves the multi-line-sentence sawtooth.
    func visualLine(forCharAt charIndex: Int) -> (rect: CGRect, range: NSRange)? {
        guard charIndex >= 0, charIndex < textView.textStorage.length else { return nil }
        let lm = textView.layoutManager
        lm.ensureLayout(for: textView.textContainer)
        let glyph = lm.glyphIndexForCharacter(at: charIndex)
        var effGlyph = NSRange(location: 0, length: 0)
        var r = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effGlyph)
        r.origin.x += textView.textContainerInset.left
        r.origin.y += textView.textContainerInset.top
        return (r, lm.characterRange(forGlyphRange: effGlyph, actualGlyphRange: nil))
    }

    /// Hit test: the character offset nearest a tap point (tap-to-jump).
    func charIndex(at point: CGPoint) -> Int? {
        guard let pos = textView.closestPosition(to: point) else { return nil }
        return textView.offset(from: textView.beginningOfDocument, to: pos)
    }

    // ========== BLOCK 02: GEOMETRY - END ==========

    // ========== BLOCK 03: SCROLL (SINGLE OWNER) - START ==========

    var focalFraction: CGFloat {
        textView.bounds.width > textView.bounds.height
            ? tuning.focalFractionLandscape : tuning.focalFractionPortrait
    }

    /// Glide so a rect (a line fragment) sits at the focal position. A live selection
    /// makes UITextView auto-scroll to keep it visible and fights us, so drop it.
    /// `setContentOffset(animated:true)` is the ONLY reliable scroll on a UITextView
    /// (wrapping `contentOffset =` in UIView.animate does not commit — verified).
    func glide(toRect r: CGRect) {
        if textView.isFirstResponder { textView.resignFirstResponder() }
        textView.selectedTextRange = nil
        let bh = textView.bounds.height
        guard bh > 0 else { return }
        let targetY = r.midY - focalFraction * bh
        let maxOff = max(0, textView.contentSize.height - bh)
        let y = min(max(0, targetY), maxOff)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    // ========== BLOCK 03: SCROLL (SINGLE OWNER) - END ==========

    // ========== BLOCK 04: READ-ALONG LINE BAND (LOCAL EDIT) - START ==========

    /// Light exactly the given line range (optionally widened by the highlight knobs),
    /// clearing only the PRIOR line. Pass nil to clear.
    func setActiveLine(_ range: NSRange?) {
        let ts = textView.textStorage
        ts.beginEditing()
        if let last = activeLineRange, NSMaxRange(last) <= ts.length {
            ts.removeAttribute(.backgroundColor, range: last)
        }
        if let range, range.length > 0, NSMaxRange(range) <= ts.length {
            ts.addAttribute(.backgroundColor, value: tuning.highlightColor, range: range)
            activeLineRange = range
        } else {
            activeLineRange = nil
        }
        ts.endEditing()
    }

    // ========== BLOCK 04: READ-ALONG LINE BAND (LOCAL EDIT) - END ==========

    // ========== BLOCK 05: ANNOTATION MARKERS (UNDERLINE) - START ==========

    /// Render the given annotations by underlining each anchored substring in the
    /// highlight hue. Replaces the previous set wholesale (attribute-only edits —
    /// cheap, no reflow). `.underlineStyle` is independent of the read-along band's
    /// `.backgroundColor`, so a note and the moving highlight coexist on the same line
    /// without fighting. The underline is the marker AND the tap target (see handleTap);
    /// no inline glyph — it would either collide with the prose or force a reflow that
    /// shifts every downstream offset (the coordinate drift this rebuild exists to kill).
    func setMarkers(_ newMarkers: [SurfaceMarker]) {
        let ts = textView.textStorage
        ts.beginEditing()
        for m in markers where NSMaxRange(m.surfaceRange) <= ts.length {
            ts.removeAttribute(.underlineStyle, range: m.surfaceRange)
            ts.removeAttribute(.underlineColor, range: m.surfaceRange)
        }
        for m in newMarkers where m.surfaceRange.length > 0 && NSMaxRange(m.surfaceRange) <= ts.length {
            // Confident = solid thick underline. Unsure = dotted + dimmed: visibly "this
            // note's spot isn't certain," never a confident (mis)placement.
            let style: NSUnderlineStyle = m.unsure ? [.thick, .patternDot] : .thick
            let color = m.unsure ? tuning.annotationUnderlineColor.withAlphaComponent(0.55)
                                 : tuning.annotationUnderlineColor
            ts.addAttribute(.underlineStyle, value: style.rawValue, range: m.surfaceRange)
            ts.addAttribute(.underlineColor, value: color, range: m.surfaceRange)
        }
        ts.endEditing()

        // Rebuild the margin kind-glyphs (note / bookmark / conversation), one per
        // annotation, in the left gutter beside its first line — collision-free.
        glyphButtons.values.forEach { $0.removeFromSuperview() }
        glyphButtons.removeAll()
        markers = newMarkers
        for m in newMarkers {
            let b = makeGlyphButton(for: m)
            glyphButtons[m.id] = b
            textView.addSubview(b)
        }
        refreshMarkerPositions()
    }

    /// Position each margin glyph in the gutter, vertically aligned with the first line
    /// of its annotation. Call after any re-layout (rotation / Dynamic Type / re-flow).
    func refreshMarkerPositions() {
        let lm = textView.layoutManager
        lm.ensureLayout(for: textView.textContainer)
        let size = tuning.annotationGlyphPointSize + 8   // tap target ≈ glyph + padding
        for m in markers {
            guard let b = glyphButtons[m.id], m.surfaceRange.length > 0,
                  NSMaxRange(m.surfaceRange) <= textView.textStorage.length else { continue }
            let firstChar = NSRange(location: m.surfaceRange.location, length: 1)
            let r = rect(for: firstChar)
            // Center the glyph in the gutter (left of the text column), on the line.
            let x = max(0, (tuning.gutterWidth - size) / 2)
            b.frame = CGRect(x: x, y: r.minY + (r.height - size) / 2, width: size, height: size)
        }
    }

    private func makeGlyphButton(for m: SurfaceMarker) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: m.symbol,
                            withConfiguration: UIImage.SymbolConfiguration(
                                pointSize: tuning.annotationGlyphPointSize, weight: .semibold))
        cfg.contentInsets = .zero
        cfg.baseForegroundColor = m.unsure ? tuning.annotationUnderlineColor.withAlphaComponent(0.55)
                                           : tuning.annotationUnderlineColor
        let b = UIButton(configuration: cfg)
        let id = m.id
        b.addAction(UIAction { [weak self] _ in self?.onOpenMarker?(id) }, for: .touchUpInside)
        b.accessibilityLabel = m.symbol.contains("bookmark") ? "Open bookmark"
                             : m.symbol.contains("bubble") ? "Open conversation" : "Open note"
        return b
    }

    // ========== BLOCK 05: ANNOTATION MARKERS - END ==========

    // ========== BLOCK 05B: CONTENT RELOAD (FONT-SIZE / RE-FLOW) - START ==========

    /// Swap in freshly-built content (e.g. rebuilt at a new body point size) on the
    /// SAME text view — the SwiftUI host keeps its reference, so the document re-flows
    /// in place. Clears transient render state (active line, markers); the owner
    /// re-applies markers afterward, re-resolving canonical anchors → the NEW surface
    /// ranges. This is the E2 Step-2 durability path: an annotation underline must
    /// land on the exact same characters after the re-flow.
    func reload(content newContent: ReaderSurfaceContent) {
        content = newContent
        activeLineRange = nil
        markers = []
        textView.attributedText = newContent.attributed
    }

    // ========== BLOCK 05B: CONTENT RELOAD - END ==========
}

// ========== BLOCK 01: READER SURFACE (CORE SPINE) - END ==========

// ========== BLOCK 06: SELECTION MENU (NOTE / BOOKMARK) - START ==========

extension ReaderSurface: UITextViewDelegate {
    /// Inject Note + Bookmark into the selection's contextual menu. The user selects
    /// text and picks one; the owner converts the SURFACE range to a canonical anchor.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        if awaitingMove {
            // Re-placing an unsure note: the only annotation action is "move it here".
            let move = UIAction(title: "Move note here", image: UIImage(systemName: "hand.point.up.left.fill")) {
                [weak self] _ in self?.onMoveHere?(range)
            }
            return UIMenu(children: [UIMenu(title: "", options: .displayInline, children: [move])] + suggestedActions)
        }
        let note = UIAction(title: "Note", image: UIImage(systemName: "square.and.pencil")) {
            [weak self] _ in self?.onAnnotate?(range, .note)
        }
        let bookmark = UIAction(title: "Bookmark", image: UIImage(systemName: "bookmark.fill")) {
            [weak self] _ in self?.onAnnotate?(range, .bookmark)
        }
        let group = UIMenu(title: "", options: .displayInline, children: [note, bookmark])
        return UIMenu(children: [group] + suggestedActions)
    }
}

// ========== BLOCK 06: SELECTION MENU - END ==========
