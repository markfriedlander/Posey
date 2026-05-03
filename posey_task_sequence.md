# Posey — Definitive Task Sequence to Submission
# Built 2026-05-02

Each task is a discrete unit. CC completes it fully, verifies it on device with screenshots, and reports back before receiving the next task. No skipping ahead.

---

## TASK 0 — API Completeness (DONE)

1. Endpoint to move reader to a specific sentence index or character offset — DONE
2. Endpoint to simulate UI taps on device via RemoteTargetRegistry — DONE
3. Endpoint to create a note at a specific position — DONE
4. Endpoint to create a bookmark at a specific position — DONE
5. Endpoint to invoke Ask Posey passage-scoped at a specific offset — DONE
6. Endpoint to read current reader state — DONE
7. Autonomous device screenshots via UIGraphicsImageRenderer — DONE
8. Full audit of all existing endpoints — DONE
Remaining gap: READ_TREE returns identifier-less skeleton due to SwiftUI iOS 26 stripping accessibility identifiers. Documented. Does not block current work.

---

## TASK 1 — Ask Posey UI Bug Fix (DONE)

9. Anchor threading inline in ScrollView — DONE
10. Post-send scroll fix — DONE
11. Placeholder → "Ask Posey..." — DONE
12. Save to Notes button removed — DONE
13. Single Ask Posey entry point, no two-choice menu — DONE
14. Double-tap sentence → moves highlight and playback position — DONE
15. Unified Saved Annotations — conversations, notes, bookmarks with icons — DONE
16. Tap anchor in thread → jumps reader — DONE
17. Doc-scope invocation → document title as anchor marker — DONE
18. Tap conversation in Notes → opens Ask Posey at that anchor — DONE
19. Tap note in Notes → expands inline, navigates reader — DONE
20. Tap bookmark in Notes → navigates reader — DONE
21. All three annotation types coexist chronologically — DONE
22. qa_battery.sh title-based lookup — DONE

---

## TASK 2 — Ask Posey Remaining UI Bugs (CURRENT)

23. Markdown not rendering in Posey responses — bold showing as literal asterisks
24. Sources disappear after tapping one and returning
25. Sources UX redesign — inline superscript citations, tap to jump to passage. Research how Perplexity handles inline citations before implementing.
26. Motion permission asks on launch — should only ask when user selects Auto in Reading Style preferences. Default motion mode to Off.

Verify all four on device with screenshots before reporting back.

---

## TASK 3 — Ask Posey Deep Conversation Testing

27. Real unscripted conversations on all 7 formats: TXT, MD, RTF, DOCX, HTML, EPUB, PDF
28. For each format: factual question, honest refusal test, 5+ turn chain, topic switch, vague question, structural question, passage-scoped and document-scoped invocations
29. Report findings only — no fixes yet

---

## TASK 4 — Ask Posey Quality Fixes

30. Fix everything surfaced in Task 3, prioritized by user impact
31. For each fix: explain root cause, explain fix, verify on device

---

## TASK 5 — Reader Deep Testing

32. Full reading, playback, navigation, notes, and reading styles test across all 7 formats
33. Every button, every menu, every error path
34. Report findings only — no fixes yet

---

## TASK 6 — Reader Quality Fixes

35. Fix everything surfaced in Task 5

---

## TASK 7 — Audio Export

36. Investigate whether AVSpeechSynthesizer.write captures Best Available voices
37. Implement M4A export with progress indicator
38. Save to Files + share sheet on completion
39. Clear messaging if Best Available voices cannot be exported
40. Verify on device — export a real M4A and confirm it plays correctly

---

## TASK 8 — Format Parity Audit

41. Text normalization — confirm all importers delegating to shared TextNormalizer including PDFDocumentImporter which still has its own normalize()
42. TOC detection and navigation — EPUB playback-skip-until-offset still missing, DOCX TOC fields not parsed
43. Inline images — DOCX and HTML not yet done, only EPUB and PDF
44. Richer non-text preservation — figures, tables, charts in EPUB, DOCX, HTML
45. Visual significance threshold for blank visual stop pages — blank pages should not pause playback
46. Position persistence across all formats
47. Search across all formats
48. Ask Posey indexing verified on real corpus across all formats
49. Audio export across all formats
50. Reading Style preferences across all formats
51. Accessibility labels and Dynamic Type across all formats
52. Multilingual embedding — verify on real corpus, tune thresholds
53. Entity-aware relevance scoring v2 — multi-factor formula with entity overlap boost
54. Tap-to-reveal-chrome not firing reliably inside ScrollView — gesture recognizer conflict with textSelection

---

## TASK 9 — Accessibility Pass (Mark present)

55. VoiceOver labels on all custom controls
56. Navigation order audit
57. 44×44pt minimum touch targets
58. Dynamic Type scaling
59. Reduce Motion support
60. Color contrast audit
Report findings before fixing. Fix after Mark confirms priorities.

---

## TASK 10 — Mac Catalyst Verification

61. Voice list differences on Mac
62. File picker behavior
63. Half-sheet detents
64. Window sizing
65. Local API behavior on Mac
Report and fix any issues.

---

## TASK 11 — App Icon

66. Implement final icon — geometric P forming glasses, pure black and white, round lenses, record sleeve energy. Reference the GPT-generated round version Mark has.
67. Generate all required sizes 1024×1024 down to 20pt
68. Evaluate at actual home screen scale before locking

---

## TASK 12 — Share Feature

69. Share a single Q&A pair from Ask Posey
70. Option to copy full conversation for a document
71. Standard iOS share sheet. Test on device.

---

## TASK 13 — Pre-Submission Polish

72. Antenna defaults to OFF for release — LocalAPIServer class and all API methods compiled out entirely in release builds, not just UI hidden
73. All #if DEBUG guards complete — deeper compile-out remaining
74. No debug output in release path
75. Landscape centering — re-fire scrollToCurrentSentence on orientation change
76. Go-to-page UX polish — error wording, accessibility, stepper alternative
77. WORD - WORD space-hyphen-space artifact — resolve or document
78. TOCSheet id: \.playOrder non-unique — needs composite id
79. Full regression run of qa_battery.sh
80. Full reader test on all 7 formats

---

## TASK 14 — Submission Prep (Mark present for all)

81. Draft privacy policy addressing: on-device-only processing, Apple Intelligence, no third-party AI, no analytics, no network requests in core path. Host at stable URL.
82. App Store metadata — description leading with core loop, keywords, primary and secondary categories, age rating, What's New copy
83. Screenshots — use simulator MCP to capture key states across iPhone and iPad sizes: empty library, populated library, reader with active highlight, TOC sheet, Notes sheet, Preferences sheet, Ask Posey sheet (passage-scoped, document-scoped, navigation results)
84. Final submission — Mark present for all irreversible steps (signing in, two-factor, final submit button). Verify release configuration. Submit. Monitor review feedback.

---

## Notes on Execution

- Each task is complete only when verified on device with screenshots
- CC reports back before receiving the next task
- Mark does not test. CC tests. Testing is CC's responsibility end to end.
- If something surfaces in one task that belongs in a later task, log it in NEXT.md and continue with the current task scope
- If something is genuinely blocked, say so explicitly with the reason. Do not paper over it.
- Commit and push are one action. Every commit goes to origin/main immediately.
- Resize all screenshots to under 800px wide before adding to context.
