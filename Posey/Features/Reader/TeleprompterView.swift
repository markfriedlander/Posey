import SwiftUI
import UIKit

// ========== BLOCK 01: TELEPROMPTER VIEW - START ==========

/// Full-screen, one-sentence-at-a-time read-along presentation (Mark, 2026-07-12).
///
/// While Teleprompter mode is PLAYING, the reader shows ONLY the current sentence —
/// large, flush-left, on the blank reading background — swapping to the next sentence
/// as the voice advances. Advancement rides the reliable per-sentence signal
/// (`currentSentenceIndex`, didStart-driven), so it works on ANY voice, with nothing
/// to lag or overrun. Stop playback → back to the normal scrolling page.
///
/// Sizing (Mark, 2026-07-12):
/// - `.fit` — auto-size the sentence to fill the view, but ONLY within a MODEST font
///   band (a "reasonable pocket") so the size never swings between a giant short
///   sentence and a tiny long one. A sentence too long even at the band's floor
///   scrolls instead of shrinking further.
/// - `.fixed` — one consistent size; long sentences scroll.
struct TeleprompterView: UIViewRepresentable {

    enum Sizing: String, CaseIterable { case fit, fixed }

    let text: String
    /// Default `.fixed`: long sentences are split into capped CHUNKS upstream (see
    /// `SentenceChunker` / `chunkMaxChars`), so every card holds a comfortable amount
    /// of text at one consistent size — Mark's "reasonable pocket," reached by capping
    /// words per card rather than shrinking the font. `.fit` (auto-size a whole
    /// sentence within a band) is kept for a future user option.
    var sizing: Sizing = .fixed
    /// Any touch reveals the (auto-fading) transport so the reader can pause.
    var onReveal: () -> Void = {}

    /// Max characters per card/chunk — the knob that controls how much text (and thus
    /// how much negative space) is on each card at the fixed font. TUNING KNOB.
    static let chunkMaxChars = 100

    /// Font sizes. `fixedPointSize` is the sizable, calm default; the band is for the
    /// future `.fit` option. TUNING KNOBS.
    static let minPointSize: CGFloat = 26
    static let maxPointSize: CGFloat = 46
    static let fixedPointSize: CGFloat = 40

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 28, left: 22, bottom: 28, right: 22)
        tv.textContainer.lineFragmentPadding = 0
        tv.showsVerticalScrollIndicator = false
        tv.textColor = .label
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        context.coordinator.onReveal = onReveal
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onReveal = onReveal
        context.coordinator.apply(text: text, sizing: sizing, to: tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        private var lastText: String?
        var onReveal: () -> Void = {}

        @objc func handleTap() { onReveal() }

        func apply(text: String, sizing: Sizing, to tv: UITextView) {
            let bounds = tv.bounds
            guard bounds.width > 1, bounds.height > 1 else {
                // Bounds not ready — set at a default; the next layout pass re-applies.
                tv.attributedText = Self.attributed(text, pointSize: TeleprompterView.fixedPointSize)
                return
            }
            let changed = text != lastText
            guard changed || tv.attributedText.length == 0 else { return }
            lastText = text
            let pt = TeleprompterView.pointSize(for: text, sizing: sizing,
                                                in: bounds, insets: tv.textContainerInset)
            let attr = Self.attributed(text, pointSize: pt)
            let setBlock = {
                tv.attributedText = attr
                Self.positionVertically(tv)
            }
            if changed, tv.window != nil {
                UIView.transition(with: tv, duration: 0.22,
                                  options: .transitionCrossDissolve, animations: setBlock)
            } else {
                setBlock()
            }
        }

        private static func attributed(_ text: String, pointSize: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: pointSize, weight: .bold),
                .paragraphStyle: Self.paragraph,
                .foregroundColor: UIColor.label
            ])
        }

        static let paragraph: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.alignment = .left            // flush left (Mark's preference)
            p.lineBreakMode = .byWordWrapping
            p.lineHeightMultiple = 1.08
            return p
        }()

        /// Center the card vertically when it fits (Mark, 2026-07-13: the balanced,
        /// beautiful look is worth more than a fixed top anchor); pin to the top and let
        /// it scroll when a card overflows the view.
        private static func positionVertically(_ tv: UITextView) {
            tv.layoutIfNeeded()
            let contentH = tv.contentSize.height
            let viewH = tv.bounds.height
            let slack = max(0, (viewH - contentH) / 2)
            tv.contentInset = UIEdgeInsets(top: slack, left: 0, bottom: 0, right: 0)
            tv.setContentOffset(CGPoint(x: 0, y: -slack), animated: false)
        }
    }

    /// Largest point size within the band whose wrapped text fits the view height;
    /// falls to the floor (and scrolls) if even that overflows. `.fixed` uses one size.
    static func pointSize(for text: String, sizing: Sizing,
                          in bounds: CGRect, insets: UIEdgeInsets) -> CGFloat {
        if sizing == .fixed { return fixedPointSize }
        let w = bounds.width - insets.left - insets.right
        let h = bounds.height - insets.top - insets.bottom
        guard w > 1, h > 1 else { return minPointSize }
        let ns = text as NSString
        func fits(_ pt: CGFloat) -> Bool {
            let rect = ns.boundingRect(
                with: CGSize(width: w, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.systemFont(ofSize: pt, weight: .bold),
                             .paragraphStyle: Coordinator.paragraph],
                context: nil)
            return ceil(rect.height) <= h
        }
        var pt = maxPointSize
        while pt > minPointSize {
            if fits(pt) { return pt }
            pt -= 1
        }
        return minPointSize
    }
}

// ========== BLOCK 01: TELEPROMPTER VIEW - END ==========
