import CoreGraphics
import CoreText
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)

func makeAttributedString(_ text: String) -> NSAttributedString {
    NSAttributedString(
        string: text,
        attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font
        ]
    )
}

func draw(pageText: String, in context: CGContext, mediaBox: CGRect) {
    context.beginPDFPage(nil)
    context.textMatrix = .identity
    context.translateBy(x: 0, y: mediaBox.height)
    context.scaleBy(x: 1, y: -1)

    var y: CGFloat = mediaBox.height - 96
    let lines = pageText.components(separatedBy: "\n")

    for line in lines {
        if line.isEmpty {
            y -= 18
            continue
        }

        context.textPosition = CGPoint(x: 72, y: y)
        let textLine = CTLineCreateWithAttributedString(makeAttributedString(line))
        CTLineDraw(textLine, context)
        y -= 28
    }

    context.endPDFPage()
}

let pageTexts = [
    """
    Serious Reading in PDF

    Dense pages still need a calm reading flow.
    The first PDF pass should stay honest about text extraction.
    """,
    """
    Second page reminder: preserve context across page breaks.

    Notes, playback, and restore should feel the same as other formats.
    """
]

var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
    fatalError("Could not create PDF consumer.")
}

let info = [
    kCGPDFContextTitle as String: "Structured Sample PDF"
] as CFDictionary

guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
    fatalError("Could not create PDF context.")
}

for pageText in pageTexts {
    draw(pageText: pageText, in: context, mediaBox: mediaBox)
}

context.closePDF()
