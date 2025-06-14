//
//  KLayoutManager.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

struct LineInfo {
    let text: String
    let glyphAdvances: [CGFloat]
    let range: Range<Int>
}

final class KLayoutManager {

    // MARK: - Properties

    private(set) var lines: [LineInfo] = []
    private(set) var maxLineWidth: CGFloat = 0
    private let textStorage: KTextStorage
    
    var lineSpacing: CGFloat = 2.0
    
    var lineHeight: CGFloat {
        let font = textStorage.baseFont
        return font.ascender + abs(font.descender) + lineSpacing
    }

    // MARK: - Init

    init(textStorage: KTextStorage) {
        self.textStorage = textStorage
        textStorage.string = "abcde日本語の文章でも問題ないか確認。\n複数行ではどうなるかな。\nこれは3行目。ちゃんと表示されてほしい。"
        rebuildLayout()
    }

    // MARK: - Layout
    /*
    func rebuildLayout() {
        lines.removeAll()
        var currentIndex = 0

        let text = textStorage.string
        let lineTexts = text.split(separator: "\n", omittingEmptySubsequences: false)
        let calculator = GlyphAdvanceCalculator(font: textStorage.baseFont)

        for (i, line) in lineTexts.enumerated() {
            let lineText = String(line)
            let glyphAdvances = lineText.map { calculator.advanceForCharacter($0) }
            let lineRange = currentIndex..<(currentIndex + lineText.count)

            let lineInfo = LineInfo(text: lineText, glyphAdvances: glyphAdvances, range: lineRange)
            lines.append(lineInfo)

            currentIndex += lineText.count
            if i < lineTexts.count - 1 {
                currentIndex += 1 // 改行文字
            }
        }
    }*/
    
    func rebuildLayout() {
        lines.removeAll()
        maxLineWidth = 0

        var currentIndex = 0
        let characters = textStorage.characters
        let font = textStorage.baseFont

        while currentIndex < characters.count {
            var lineEndIndex = currentIndex

            // 改行まで進める（改行文字は含めない）
            while lineEndIndex < characters.count && characters[lineEndIndex] != "\n" {
                lineEndIndex += 1
            }

            let lineRange = currentIndex..<lineEndIndex
            let lineText = String(characters[lineRange])

            let attrString = NSAttributedString(string: lineText, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attrString)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            if width > maxLineWidth {
                maxLineWidth = width
            }

            lines.append(LineInfo(text: lineText, glyphAdvances: [], range: lineRange))

            currentIndex = lineEndIndex
            if currentIndex < characters.count && characters[currentIndex] == "\n" {
                currentIndex += 1 // 改行をスキップ
            }
        }
    }
}
