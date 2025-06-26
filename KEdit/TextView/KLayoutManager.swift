//
//  KLayoutManager.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

struct LineInfo {
    let ctLine: CTLine
    let range: Range<Int>
}

// MARK: - protocol KLayoutManagerReadable

protocol KLayoutManagerReadable: AnyObject {
    var lines: ArraySlice<LineInfo> { get }
    var lineCount: Int { get }
    var lineHeight: CGFloat { get }
    var lineSpacing: CGFloat { get }
    var maxLineWidth: CGFloat { get }
}

// MARK: - KLayoutManager

final class KLayoutManager: KLayoutManagerReadable {

    // MARK: - Properties

    private(set) var _lines: [LineInfo] = []
    private var _maxLineWidth: CGFloat = 0
    private let _textStorageRef: KTextStorageProtocol
    
    var lineSpacing: CGFloat = 2.0
    
    var lineHeight: CGFloat {
        let font = _textStorageRef.baseFont
        return font.ascender + abs(font.descender) + lineSpacing
    }
    
    var lineCount: Int {
        return _lines.count
    }
    
    var maxLineWidth: CGFloat {
        return _maxLineWidth
    }
    
    var lines: ArraySlice<LineInfo> {
        return ArraySlice(_lines)
    }

    // MARK: - Init

    init(textStorageRef: KTextStorageProtocol) {
        _textStorageRef = textStorageRef 
        textStorageRef.string = "abcde日本語の文章でも問題ないか確認。\n複数行ではどうなるかな。\nこれは3行目。ちゃんと表示されてほしい。"
        rebuildLayout()
    }

    // MARK: - Layout
    
    func rebuildLayout() {
        _lines.removeAll()
        _maxLineWidth = 0

        var currentIndex = 0
        let characters = _textStorageRef.characterSlice
        let font = _textStorageRef.baseFont
        
        if _textStorageRef.count == 0 {
            _lines.append(LineInfo(ctLine: CTLineCreateWithAttributedString(NSAttributedString(string: "")), range: 0..<0))
        }

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

            _lines.append(LineInfo(ctLine: ctLine, range: lineRange))

            currentIndex = lineEndIndex
            
            
            if currentIndex < characters.count && characters[currentIndex] == "\n" {
                //_lines.append(makeEmptyLine(index: currentIndex))
                currentIndex += 1 // 改行をスキップ
            }
            
        }
        
    }
    
    private func makeEmptyLine(index: Int) -> LineInfo {
        return LineInfo(ctLine: CTLineCreateWithAttributedString(NSAttributedString(string: "")), range: index..<index)
    }
}
