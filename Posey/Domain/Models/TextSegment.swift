import Foundation

struct TextSegment: Identifiable, Equatable {
    let id: Int
    let text: String
    let startOffset: Int
    let endOffset: Int
}
