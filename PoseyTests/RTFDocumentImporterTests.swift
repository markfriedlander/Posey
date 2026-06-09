import XCTest
@testable import Posey

final class RTFDocumentImporterTests: XCTestCase {
    func testLoadTextExtractsReadableStringFromRTF() throws {
        let fixtureURL = TestFixtureLoader.url(named: "StructuredSample", fileExtension: "rtf")

        let text = try RTFDocumentImporter().loadText(from: fixtureURL)

        XCTAssertTrue(text.contains("Serious Reading"))
        XCTAssertTrue(text.contains("First bullet clarifies the key idea."))
        XCTAssertTrue(text.contains("Closing thought: readers need structure to stay oriented."))
        XCTAssertFalse(text.contains(#"\rtf1"#))
    }

    func testLoadTextRejectsEmptyRTFDocument() throws {
        let emptyRTF = Data("{\\rtf1\\ansi   }".utf8)

        XCTAssertThrowsError(try RTFDocumentImporter().loadText(fromData: emptyRTF)) { error in
            XCTAssertEqual(error as? RTFDocumentImporter.ImportError, .emptyDocument)
        }
    }

    // MARK: - #2 RTF image extraction (2026-06-09)

    /// A real 2×2 PNG (75 bytes) hex-encoded as a `\pngblip`, embedded
    /// between two paragraphs. Locks the extractor + displayText splice:
    /// the image is decoded, a POSEY_VISUAL_PAGE marker is placed in
    /// displayText (NOT plainText), and the marker sits AFTER the
    /// preceding paragraph (needle placement).
    func testExtractsEmbeddedPNGBlipIntoDisplayTextMarker() throws {
        let pngHex = "89504e470d0a1a0a0000000d4948445200000002000000020802000000fdd49a73" +
                     "0000001249444154789c633c2127c7c0c0c0c40006000d040108a3134e5a" +
                     "0000000049454e44ae426082"
        // A well-formed RTF: a paragraph, then a centered pict group, then a caption.
        let rtf = "{\\rtf1\\ansi\\deff0 The quick brown fox jumps over the lazy dog.\\par\\par " +
                  "{\\qc {\\pict\\pngblip\\picw100\\pich100 \(pngHex)}}\\par\\par " +
                  "Figure caption follows the image.\\par}"
        let parsed = try RTFDocumentImporter().loadDocument(fromData: Data(rtf.utf8))

        // One image decoded; bytes are a real PNG (magic 0x89 'P' 'N' 'G').
        XCTAssertEqual(parsed.images.count, 1)
        let bytes = try XCTUnwrap(parsed.images.first?.data)
        XCTAssertGreaterThan(bytes.count, 16)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        // Marker lives in displayText, not plainText.
        let imageID = try XCTUnwrap(parsed.images.first?.imageID)
        XCTAssertTrue(parsed.displayText.contains("[[POSEY_VISUAL_PAGE:0:\(imageID)]]"),
                      "displayText must carry the visual-page marker for the image")
        XCTAssertFalse(parsed.plainText.contains("POSEY_VISUAL_PAGE"),
                       "plainText must stay marker-free (TTS/search/offset coordinate)")

        // Needle placement: marker is after the preceding sentence and
        // before the caption.
        let dt = parsed.displayText
        let foxRange = try XCTUnwrap(dt.range(of: "lazy dog."))
        let markerRange = try XCTUnwrap(dt.range(of: "[[POSEY_VISUAL_PAGE"))
        let captionRange = try XCTUnwrap(dt.range(of: "Figure caption"))
        XCTAssertLessThan(foxRange.lowerBound, markerRange.lowerBound)
        XCTAssertLessThan(markerRange.lowerBound, captionRange.lowerBound)
    }

    /// An RTF with no `\pict` yields no images and a displayText that
    /// equals plainText (no markers) — the image-free path must be inert.
    func testNoImagesYieldsMarkerFreeDisplayText() throws {
        let rtf = "{\\rtf1\\ansi\\deff0 Plain paragraph one.\\par\\par Plain paragraph two.\\par}"
        let parsed = try RTFDocumentImporter().loadDocument(fromData: Data(rtf.utf8))
        XCTAssertTrue(parsed.images.isEmpty)
        XCTAssertEqual(parsed.displayText, parsed.plainText)
        XCTAssertFalse(parsed.displayText.contains("POSEY_VISUAL_PAGE"))
    }
}
