import Foundation
import NaturalLanguage

struct SentenceSegmenter {
    func segments(for text: String) -> [TextSegment] {
        guard text.isEmpty == false else {
            return []
        }

        var segments: [TextSegment] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.isEmpty == false else {
                return true
            }

            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)

            segments.append(
                TextSegment(
                    id: segments.count,
                    text: sentence,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
            )
            return true
        }

        if segments.isEmpty {
            return fallbackParagraphSegments(for: text)
        }

        return segments
    }

    private func fallbackParagraphSegments(for text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var searchStart = text.startIndex

        for chunk in text.components(separatedBy: "\n\n") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                continue
            }

            guard let range = text.range(of: chunk, range: searchStart..<text.endIndex) else {
                continue
            }

            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)

            segments.append(
                TextSegment(
                    id: segments.count,
                    text: trimmed,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
            )
            searchStart = range.upperBound
        }

        if segments.isEmpty {
            return [
                TextSegment(id: 0, text: text, startOffset: 0, endOffset: text.count)
            ]
        }

        return segments
    }
}
