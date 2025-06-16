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

// MARK: - protocol KLayoutManagerReadable

protocol KLayoutManagerReadable: AnyObject {
    var lineCount: Int { get }
    var lineHeight: CGFloat { get }
    var lineSpacing: CGFloat { get }
}

// MARK: - KLayoutManager

final class KLayoutManager {

    // MARK: - Properties

    private(set) var _lines: [LineInfo] = []
    private(set) var _maxLineWidth: CGFloat = 0
    private let _textStorage: KTextStorage
    
    var lineSpacing: CGFloat = 2.0
    
    var lineHeight: CGFloat {
        let font = _textStorage.baseFont
        return font.ascender + abs(font.descender) + lineSpacing
    }

    // MARK: - Init

    init(textStorage: KTextStorage) {
        self._textStorage = textStorage
        textStorage.string = "abcde日本語の文章でも問題ないか確認。\n複数行ではどうなるかな。\nこれは3行目。ちゃんと表示されてほしい。"
        rebuildLayout()
    }

    // MARK: - Layout
    
    func rebuildLayout() {
        _lines.removeAll()
        _maxLineWidth = 0

        var currentIndex = 0
        let characters = _textStorage._characters
        let font = _textStorage.baseFont

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
            if width > _maxLineWidth {
                _maxLineWidth = width
            }

            _lines.append(LineInfo(text: lineText, glyphAdvances: [], range: lineRange))

            currentIndex = lineEndIndex
            if currentIndex < characters.count && characters[currentIndex] == "\n" {
                currentIndex += 1 // 改行をスキップ
            }
        }
    }
}
