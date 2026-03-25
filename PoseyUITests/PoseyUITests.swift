import XCTest

final class PoseyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPreloadedTXTLoopCanPlayPauseAndRestore() {
        let firstLaunch = configuredApp(fixtureName: "LongDenseSample", resetDatabase: true)
        firstLaunch.launch()

        let row = firstLaunch.buttons["library.document.LongDenseSample"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let playPauseButton = firstLaunch.buttons["reader.playPause"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
        playPauseButton.tap()

        let stateLabel = firstLaunch.staticTexts["reader.playbackState"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("playing", element: stateLabel))

        let sentenceLabel = firstLaunch.staticTexts["reader.currentSentenceIndex"]
        XCTAssertTrue(sentenceLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForNonZeroValue(element: sentenceLabel))

        playPauseButton.tap()
        XCTAssertTrue(waitForValue("paused", element: stateLabel))
        let savedSentenceIndex = sentenceLabel.label

        firstLaunch.terminate()

        let secondLaunch = configuredApp(fixtureName: "LongDenseSample", resetDatabase: false)
        secondLaunch.launch()

        let secondRow = secondLaunch.buttons["library.document.LongDenseSample"]
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
        secondRow.tap()

        let restoredSentenceLabel = secondLaunch.staticTexts["reader.currentSentenceIndex"]
        XCTAssertTrue(restoredSentenceLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(savedSentenceIndex, element: restoredSentenceLabel))
    }

    func testNotesSheetCanSaveNoteAndBookmark() {
        let app = configuredApp(fixtureName: "LongDenseSample", resetDatabase: true)
        app.launch()

        let row = app.buttons["library.document.LongDenseSample"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let notesButton = app.buttons["reader.notes"]
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        notesButton.tap()

        let emptyState = app.staticTexts["notes.empty"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))

        let draftField = app.textFields["notes.draft"]
        XCTAssertTrue(draftField.waitForExistence(timeout: 5))
        draftField.tap()
        draftField.typeText("Device note")

        let saveButton = app.buttons["notes.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        let bookmarkButton = app.buttons["notes.bookmark"]
        XCTAssertTrue(bookmarkButton.waitForExistence(timeout: 5))
        bookmarkButton.tap()

        XCTAssertFalse(emptyState.exists)

        app.buttons["Done"].tap()

        let noteCount = app.staticTexts["reader.noteCount"]
        XCTAssertTrue(noteCount.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("2", element: noteCount))
    }

    private func configuredApp(fixtureName: String, resetDatabase: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--posey-ui-test-mode"]
        app.launchEnvironment["POSEY_TEST_MODE"] = "1"
        app.launchEnvironment["POSEY_PLAYBACK_MODE"] = "simulated"
        app.launchEnvironment["POSEY_RESET_DATABASE"] = resetDatabase ? "1" : "0"
        app.launchEnvironment["POSEY_PRELOAD_TXT_TITLE"] = fixtureName
        app.launchEnvironment["POSEY_PRELOAD_TXT_FILENAME"] = "\(fixtureName).txt"
        app.launchEnvironment["POSEY_PRELOAD_TXT_INLINE_BASE64"] = fixtureBase64(named: fixtureName)
        return app
    }

    private func fixtureBase64(named name: String) -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "txt") else {
            fatalError("Missing UI fixture: \(name).txt")
        }
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Could not read UI fixture: \(name).txt")
        }
        return data.base64EncodedString()
    }

    private func waitForValue(_ expectedValue: String, element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNonZeroValue(element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label != %@", "0")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
