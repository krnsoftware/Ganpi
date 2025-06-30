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
    let hardLineIndex: Int
    let softLineIndex: Int
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
        //textStorageRef.string = "abcde日本語の文章でも問題ないか確認。\n複数行ではどうなるかな。\nこれは3行目。ちゃんと表示されてほしい。"
        rebuildLayout()
        print("\(#function) - Layoutmanager initialized. and rebuild.")
    }

    // MARK: - Layout
    
    func rebuildLayout() {
        _lines.removeAll()
        _maxLineWidth = 0

        var currentIndex = 0
        var currentLineNumber = 0
        let characters = _textStorageRef.characterSlice
        //let font = _textStorageRef.baseFont
        
        // storageが空だった場合、空行を1つ追加する。
        if _textStorageRef.count == 0 {
            _lines.append(makeEmptyLine(index: 0, hardLineIndex: 0))
            print("\(#function) - textStorage is empty. add empty line.")
            return
        }

        while currentIndex < characters.count {
            var lineEndIndex = currentIndex

            // 改行まで進める（改行文字は含めない）
            while lineEndIndex < characters.count && characters[lineEndIndex] != "\n" {
                lineEndIndex += 1
            }

            let lineRange = currentIndex..<lineEndIndex
            
            /*
            let lineText = String(characters[lineRange])
            let attrString = NSAttributedString(string: lineText, attributes: [.font: font])
            */
            guard let attrString = _textStorageRef.attributedString(for: lineRange) else { print("\(#function) - attrString is nil"); return }
            
            let ctLine = CTLineCreateWithAttributedString(attrString)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            if width > _maxLineWidth {
                _maxLineWidth = width
            }

            _lines.append(LineInfo(ctLine: ctLine, range: lineRange, hardLineIndex: currentLineNumber, softLineIndex: 0))

            currentIndex = lineEndIndex
            currentLineNumber += 1
            
            
            if currentIndex < characters.count && characters[currentIndex] == "\n" {
                currentIndex += 1 // 改行をスキップ
            }
            
        }
        
        //最後の文字が改行だった場合、空行を1つ追加する。
        if _textStorageRef.characterSlice.last == "\n" {
            _lines.append(makeEmptyLine(index: _textStorageRef.count, hardLineIndex: _lines.count))
        }
        
        print("✅ lines.count = \(lines.count)")
        
    }
    
    private func makeEmptyLine(index: Int, hardLineIndex: Int) -> LineInfo {
        return LineInfo(ctLine: CTLineCreateWithAttributedString(NSAttributedString(string: "")),
                        range: index..<index,
                        hardLineIndex: hardLineIndex,
                        softLineIndex: 0)
    }
    
    
    func lineInfo(at index: Int) -> LineInfo? {
        for line in lines {
            if line.range.contains(index) || index == line.range.upperBound {
                    return line
            }
        }
        return nil
    }
}
