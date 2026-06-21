import UIKit

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
        tv.textContainerInset = UIEdgeInsets(top: tuning.topInset, left: tuning.sideInset,
                                             bottom: tuning.bottomInset, right: tuning.sideInset)
        tv.attributedText = content.attributed
        self.textView = tv
        super.init()
        // Tap-to-jump: non-cancelling so native long-press selection still works.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if let idx = charIndex(at: g.location(in: textView)) { onTap?(idx) }
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
}

// ========== BLOCK 01: READER SURFACE (CORE SPINE) - END ==========
