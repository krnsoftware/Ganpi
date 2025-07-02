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
    private weak var _textView: KTextView?
    
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
    
    var textView: KTextView? {
        get { return _textView }
        set { _textView = newValue }
    }

    var tabWidth: Int = 4 // baseFontの現在のサイズにおけるspaceの幅の何倍かで指定する。
    
    
    // MARK: - Init

    init(textStorageRef: KTextStorageProtocol) {
        _textStorageRef = textStorageRef
        
        textStorageRef.addObserver { [weak self] modification in
            self?.textStorageDidModify(modification)
        }
        
        rebuildLayout()
    }

    // MARK: - Layout
    
    func rebuildLayout() {
        _lines.removeAll()
        _maxLineWidth = 0

        var currentIndex = 0
        var currentLineNumber = 0
        let characters = _textStorageRef.characterSlice
        
        // storageが空だった場合、空行を1つ追加する。
        if _textStorageRef.count == 0 {
            _lines.append(makeEmptyLine(index: 0, hardLineIndex: 0))
            return
        }

        while currentIndex < characters.count {
            var lineEndIndex = currentIndex

            // 改行まで進める（改行文字は含めない）
            while lineEndIndex < characters.count && characters[lineEndIndex] != "\n" {
                lineEndIndex += 1
            }

            let lineRange = currentIndex..<lineEndIndex
            
            guard let attrString = _textStorageRef.attributedString(for: lineRange, tabWidth: tabWidth) else { print("\(#function) - attrString is nil"); return }
            
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
                
    }
    
    
    // TextStorageが変更された際に呼び出される。
    func textStorageDidModify(_ modification: KStorageModified) {
        guard let view = textView else { print("KLayoutManager - textStorageDidChange - textView is nil"); return }
        
        switch modification {
        case let .textChanged(range, insertedCount):
            //print("🔧 テキスト変更: range = \(range), inserted = \(insertedCount)")
            rebuildLayout()
            view.textStorageDidModify(modification)
            

        case let .colorChanged(range):
            print("🎨 カラー変更: range = \(range)")
            
        }
    }
    
    // 表示用に空行を作成する。
    private func makeEmptyLine(index: Int, hardLineIndex: Int) -> LineInfo {
        return LineInfo(ctLine: CTLineCreateWithAttributedString(NSAttributedString(string: "")),
                        range: index..<index,
                        hardLineIndex: hardLineIndex,
                        softLineIndex: 0)
    }
    
    
    func lineInfo(at index: Int) -> LineInfo? {
        //print("lineInfo(at: \(index))")
        for line in lines {
            if line.range.contains(index) || index == line.range.upperBound {
                    return line
            }
        }
        return nil
    }
}
