import Foundation

struct Document: Identifiable, Equatable, Hashable {
    let id: UUID
    let title: String
    let fileName: String
    let fileType: String
    let importedAt: Date
    let modifiedAt: Date
    let displayText: String
    let plainText: String
    let characterCount: Int
}
