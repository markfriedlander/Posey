import Foundation

final class TestFixtureBundleAnchor {}

enum TestFixtureLoader {
    static func url(named name: String, fileExtension: String = "txt") -> URL {
        let bundle = Bundle(for: TestFixtureBundleAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            fatalError("Missing fixture: \(name).\(fileExtension)")
        }
        return url
    }

    static func string(named name: String, fileExtension: String = "txt") throws -> String {
        try String(contentsOf: url(named: name, fileExtension: fileExtension), encoding: .utf8)
    }
}
