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
    }
}
