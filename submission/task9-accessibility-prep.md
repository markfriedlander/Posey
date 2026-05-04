# Task 9 — Accessibility Pass Prep

_Catalog of items for Mark to review when running the accessibility pass._

This is the autonomous prep work — code-side audit results.
Subjective passes (does VoiceOver phrasing read well? do the
reading-style preferences map to a real workflow?) need Mark
present.

## Audit results

### VoiceOver labels — image-only buttons without accessibilityLabel

**Result: 0 issues found.**

Audited every `Button { Image(systemName: "...") }` block in
Features/. Each has an explicit `.accessibilityLabel("...")`
within 25 lines. Audit script:
`python3 <<EOF` block in commit ae3ab86.

Buttons with text labels (e.g. `Button("Done")`) inherit their
text as the accessibility label automatically — those are fine.

### Touch targets under 44pt (Apple HIG minimum)

**Result: 0 issues found.**

Audited every `.frame(width: N, height: M)` in interactive
context (Button or .onTapGesture nearby). All are ≥44×44.

Top chrome buttons (search, TOC, preferences, notes) are
explicitly sized at 44×44 in `topControls`. Bottom transport
(Ask Posey, prev, play, next, restart) likewise.

### Animations not gated by Reduce Motion

**Result: 9 issues found and FIXED in commit 3534ae4.**

Originally unguarded:
| Location | Animation type | Status |
|---|---|---|
| ReaderView.swift:194 | `.transition(.move(edge: .top).combined(with: .opacity))` | Now `reduceMotion ? .opacity : .move(...)` |
| ReaderView.swift:530 | `.transition(.opacity)` | Acceptable as-is — opacity isn't motion |
| ReaderView.swift:2012 (NotesSheet) | `withAnimation(.easeInOut(duration: 0.18))` | NotesSheet now reads `@Environment(\.accessibilityReduceMotion)`; gated |
| ReaderView.swift:2765 | `withAnimation` inside `else` branch of `if Self.reduceMotionEnabled` — already gated, false positive |
| LibraryView.swift:295 | `.transition(.move(edge: .bottom).combined(with: .opacity))` | LibraryView now reads RM env; gated |
| LibraryView.swift:296 | `.animation(.easeInOut(duration: 0.2), value: message)` | Gated |
| AskPoseyView.swift:70 | `withAnimation(.easeInOut(duration: 0.18))` | AskPoseyView now reads RM env; gated |
| AskPoseyView.swift:118 | `withAnimation(.easeInOut(duration: 0.18))` | Gated |
| AskPoseyView.swift:141 | `.transition(.opacity)` | Acceptable as-is |

Pattern used: `reduceMotion ? nil : .easeInOut(...)` for animations,
`reduceMotion ? .opacity : .move(...).combined(...)` for
transitions where motion-edge slides are visible.

## What still needs Mark's eyes

### VoiceOver phrasing (subjective)

Run VoiceOver and listen to each label. The labels are present
but their wording may need tightening for screen-reader cadence:

- "Search in document" — fine as-is
- "Table of contents" — fine
- "Reader preferences" — possibly redundant; "Preferences" alone
  may read better
- "Notes" — fine
- "Ask Posey" — fine
- "Previous sentence" / "Next sentence" / "Play" / "Restart from
  beginning" — verify these match user mental model
- "Search" toolbar items have separate labels for the input
  field, prev-match button, next-match button, dismiss button —
  walk through with VoiceOver to confirm flow

### Dynamic Type scaling

Posey's reader uses `viewModel.font(for: block)` and
`.system(size: motionFontSize(forSegment:))` — these don't
explicitly use `Font.body` or `.dynamicTypeSize`-aware
constructions. At AX1+ (largest accessibility text size), the
reader font still scales but other UI (preferences sheet,
notes sheet, library cards) needs to be exercised to confirm:

- Library cards remain readable
- Preferences sheet labels don't truncate
- Notes sheet annotation rows reflow properly
- Ask Posey conversation bubbles reflow

### Reduce Motion (subjective verification)

Code now gates the animations identified above. Manual verify:
toggle Reduce Motion in iOS Settings, walk through each path,
confirm nothing slides unexpectedly.

### VoiceOver navigation order

Walk the reader top-to-bottom with the rotor. Confirm focus
order is sensible — top chrome (search, TOC, preferences,
notes), then segments in reading order, then bottom transport.
Sheets (Notes, Preferences, Ask Posey, TOC) need their own
walks.

### Color contrast

The reader uses `Color.primary` and `Color.secondary` which
adapt to dark/light. Custom tints (`chromeTint`,
`chromeSecondaryTint`) are `Color.white.opacity(0.9)` and
`Color.white.opacity(0.62)` — visible against the chrome's
`.ultraThinMaterial` capsule, but the secondary tint may be
borderline at the 0.62 opacity. Verify with the Accessibility
Inspector's Color Contrast Calculator at 4.5:1 (normal text)
and 3:1 (large text).

## Fix priorities (when Mark runs the pass)

1. **VoiceOver flow walks** — labels exist; verify they READ
   well in context.
2. **Dynamic Type at AX5** — reflow check for non-reader sheets.
3. **Color contrast** for the secondary chrome tint.
4. **Reduce Motion verification on device** — code change is
   shipped; confirm visually.

If anything fails 1-4, fixes are typically small (label rephrase,
font scaling tweak, opacity bump).
