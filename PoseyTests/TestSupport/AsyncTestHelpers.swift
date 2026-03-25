import Foundation
import XCTest

enum AsyncTestHelpers {
    static func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: UInt64 = 50_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        XCTFail("Condition not met before timeout", file: file, line: line)
    }
}
