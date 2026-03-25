import Foundation

struct ReadingPosition: Equatable {
    let documentID: UUID
    let updatedAt: Date
    let characterOffset: Int
    let sentenceIndex: Int

    static func initial(for documentID: UUID) -> ReadingPosition {
        ReadingPosition(
            documentID: documentID,
            updatedAt: .now,
            characterOffset: 0,
            sentenceIndex: 0
        )
    }
}
