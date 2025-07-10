//
//  KLayoutManager.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa


struct KLineInfo {
    let ctLine: CTLine
    let range: Range<Int>
    let hardLineIndex: Int
    let softLineIndex: Int
}


// MARK: - protocol KLayoutManagerReadable

protocol KLayoutManagerReadable: AnyObject {
    //var lines: ArraySlice<KLineInfo> { get }
    var lines: [KLine] { get }
    var lineCount: Int { get }
    var lineHeight: CGFloat { get }
    var lineSpacing: CGFloat { get }
    var maxLineWidth: CGFloat { get }
    
    func makeLayoutRects() -> LayoutRects?
    func makeEmptyLine(index: Int, hardLineIndex: Int) -> KLine
    func makeLines(range: Range<Int>, hardLineIndex: Int, width: CGFloat?) -> [KLine]?
    func makeFakeCTLines(from attributedString: NSAttributedString, width: CGFloat?) -> [CTLine]
}

// MARK: - KLayoutManager

final class KLayoutManager: KLayoutManagerReadable {

    // MARK: - Properties

    //private(set) var _lines: [KLineInfo] = []
    private(set) var _lines: [KLine] = []
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
    /*
    var lines: ArraySlice<KLineInfo> {
        return ArraySlice(_lines)
    }*/
    var lines: [KLine] {
        return _lines
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
    
    private func rebuildLayout() {
        _lines.removeAll()
        _maxLineWidth = 0
        
        guard let layoutRects = makeLayoutRects() else { print("\(#function) - layoutRects is nil"); return }

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
            
            /*
            // タブの横幅を指定しつつ文字列をattributedstringに変換する。
            /*guard let attrString = _textStorageRef.attributedString(for: lineRange, tabWidth: tabWidth) else { print("\(#function) - attrString is nil"); return }
            
            let ctLine = CTLineCreateWithAttributedString(attrString)*/
            guard let ctLine = ctLine(in: lineRange) else { print("\(#function) - ctLine is nil"); return }
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            if width > _maxLineWidth {
                _maxLineWidth = width
            }

            _lines.append(KLineInfo(ctLine: ctLine, range: lineRange, hardLineIndex: currentLineNumber, softLineIndex: 0))
            */
            /*
            let line = KLine(range: lineRange, hardLineIndex: currentLineNumber, softLineIndex: 0, layoutManager: self)
            _lines.append(line)
            let width = line.width
            if width > _maxLineWidth {
                _maxLineWidth = width
            }
             */
            
            //guard let lineArray = makeLines(range: lineRange, hardLineIndex: currentLineNumber, width: layoutRects?.textRegionWidth) else { print("\(#function) - lineArray is nil"); return }
            guard let lineArray = makeLines(range: lineRange, hardLineIndex: currentLineNumber, width: layoutRects.textRegionWidth - layoutRects.textEdgeInsets.right) else { print("\(#function) - lineArray is nil"); return }
            _lines.append(contentsOf: lineArray)
            
            let width = lineArray[0].width
            if width > _maxLineWidth {
                _maxLineWidth = width
            }

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
            //rebuildLayout()
            //print("\(#function): call rebuildLayout()")
            view.textStorageDidModify(modification)
            

        case let .colorChanged(range):
            print("🎨 カラー変更: range = \(range)")
            
        }
    }
    
    // TextViewのframeが変更された際に呼び出される。
    func textViewFrameInvalidated() {
        rebuildLayout()
        //print("\(#function): call rebuildLayout()")
        _textView?.updateFrameSizeToFitContent()
    }
 
    
    // characterIndex文字目の文字が含まれるKLineとその行番号(ソフトラップの)を返す。
    // 現在の文字がテキストの最後の場合には(nil, -1)が返る。
    func line(at characterIndex: Int) -> (line: KLine?, lineIndex: Int) {
        for (i, line) in lines.enumerated() {
            if line.range.contains(characterIndex) || characterIndex == line.range.upperBound {
                return (line, i)
            }
        }
        return (nil, -1)
    }
    
    // KLinesからctLineを構築するために利用する。
    func ctLine(in range: Range<Int>) -> CTLine? {
        guard let attrString = _textStorageRef.attributedString(for: range, tabWidth: tabWidth) else { print("\(#function) - attrString is nil"); return nil }
        
        return CTLineCreateWithAttributedString(attrString)
    }
    
    // 現在のLayoutRectsを生成する。専らTextViewから呼び出される。
    func makeLayoutRects() -> LayoutRects? {
        guard let textView = _textView else { print("\(#function) - textView is nil"); return nil }
        /*guard let clipBounds = textView.enclosingScrollView?.contentView.bounds else {
            print("\(#function) - clipBound is nil")
            return nil
        }*/
        
        return LayoutRects(
            layoutManagerRef: self,
            textStorageRef: _textStorageRef,
            //bounds: clipBounds,
            visibleRect: textView.visibleRect,
            showLineNumbers: textView.showLineNumbers,
            wordWrap: textView.wordWrap,
            textEdgeInsets: .default
        )
    }
    
    
    
    // MARK: - private function
    
    // 表示用に空行を作成する。
    
    func makeEmptyLine(index: Int, hardLineIndex: Int) -> KLine {
        return KLine(range: index..<index, hardLineIndex: hardLineIndex, softLineIndex: 0, layoutManager: self)
    }
    
    
    func makeLines(range: Range<Int>, hardLineIndex: Int, width: CGFloat?) -> [KLine]? {
        let hardLine = KLine(range: range, hardLineIndex: hardLineIndex, softLineIndex: 0, layoutManager: self)

        guard let textWidth = width, _textView?.wordWrap == true else {
            return [hardLine]
        }

        // オフセットリストを取得
        let offsets = hardLine.characterOffsets()

        guard offsets.count > 0 else {
            return [hardLine]  // 空行またはオフセット取得失敗
        }

        var softLines: [KLine] = []

        var startIndex = range.lowerBound
        var lastOffset: CGFloat = 0.0
        var softLineIndex = 0

        for i in 1..<offsets.count {
            let currentOffset = offsets[i]

            if currentOffset - lastOffset > textWidth {
                let endIndex = range.lowerBound + i
                let softRange = startIndex..<endIndex
                let softLine = KLine(range: softRange,
                                     hardLineIndex: hardLineIndex,
                                     softLineIndex: softLineIndex,
                                     layoutManager: self)
                softLines.append(softLine)
                softLineIndex += 1
                startIndex = endIndex
                lastOffset = currentOffset
            }
        }

        // 残りを追加
        if startIndex < range.upperBound {
            let softLine = KLine(range: startIndex..<range.upperBound,
                                 hardLineIndex: hardLineIndex,
                                 softLineIndex: softLineIndex,
                                 layoutManager: self)
            softLines.append(softLine)
        }

        return softLines
    }
    
    // 既存のAttributedStringからCTLineのリストを作成する。
    func makeFakeCTLines(from attributedString: NSAttributedString,
                             width: CGFloat?) -> [CTLine] {
        guard attributedString.length > 0 else { return [] }
        guard let width = width else {
            return [CTLineCreateWithAttributedString(attributedString)]
        }

        var lines: [CTLine] = []

        var currentLocation = 0
        let fullLength = attributedString.length

        while currentLocation < fullLength {
            // 対象部分のAttributedString
            let remainingRange = NSRange(location: currentLocation, length: fullLength - currentLocation)
            let subAttr = attributedString.attributedSubstring(from: remainingRange)
            let line = CTLineCreateWithAttributedString(subAttr)

            // この行に収まる最大のインデックスを取得
            let truncationIndex = CTLineGetStringIndexForPosition(line, CGPoint(x: width, y: 0))

            // 折り返し地点の調整
            var breakIndex = truncationIndex
            if breakIndex == kCFNotFound || breakIndex == 0 {
                breakIndex = 1 // 最低でも1文字進める
            }

            let actualRange = NSRange(location: currentLocation, length: breakIndex)
            let actualAttr = attributedString.attributedSubstring(from: actualRange)
            let actualLine = CTLineCreateWithAttributedString(actualAttr)

            lines.append(actualLine)
            currentLocation += breakIndex
        }

        return lines
    }
    
    
    
}


