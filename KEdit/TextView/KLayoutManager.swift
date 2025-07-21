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
    //var lines: [KLine] { get }
    var lines: KLines { get }
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
    
    // MARK: - Struct and Enum.
    
    enum KRebuildReason {
            case charactersChanged(range: Range<Int>, insertedCount: Int)
            case attributesChanged
            case destructiveChange
        }

    // MARK: - Properties

    // 関連するインスタンスの参照
    private let _textStorageRef: KTextStorageProtocol
    private weak var _textView: KTextView?
    
    // 計測上の全ての行の横幅の最大値。ワードラップありの場合には意味がない。
    private var _maxLineWidth: CGFloat = 0
    
    // baseFontの現在のサイズにおけるspaceの幅の何倍かで指定する。
    private var _tabWidth: Int = 4
    
    // 前回の描画部分のclipViewの矩形を記録する。
    //private var _prevTextViewFrame: NSRect = .zero
    
    //private var _currentTextStorageVersion: Int = 0
    
    private var _prevLineNumberRegionWidth: CGFloat = 0
    
    // 表示される行をまとめるKLinesクラスインスタンス。
    private lazy var _lines: KLines = {
        return KLines(layoutManager: self, textStorageRef: _textStorageRef)
    }()
    
    // 行間設定。
    var lineSpacing: CGFloat = 2.0
    
    var lineHeight: CGFloat {
        let font = _textStorageRef.baseFont
        return font.ascender + abs(font.descender) + lineSpacing
    }
    
    var lineCount: Int {
        return _lines.count
    }
    
    // KLinesが持つ最も幅の大きな行の幅を返します。表示マージンなし。
    // hardwrapの場合にlayoutRects.textRegion.rect.widthを設定するために使用する。
    // softwrapであっても値は返すが、内容は不定。
    var maxLineWidth: CGFloat {
        return _maxLineWidth
    }
    /*
    var lines: ArraySlice<KLineInfo> {
        return ArraySlice(_lines)
    }*/
    //var lines: [KLine] {
    var lines: KLines {
        return _lines
    }
    
    var textView: KTextView? {
        get { return _textView }
        set { _textView = newValue }
    }

    var tabWidth: Int {
        get { _tabWidth }
        set {
            _tabWidth = newValue
            _lines.rebuildLines()
        }
    }
    
    var wordWrap: Bool {
        guard let textView = _textView else { log("_textView = nil", from:self); return false }
        return textView.wordWrap
    }
    
    
    // MARK: - Init

    init(textStorageRef: KTextStorageProtocol) {
        _textStorageRef = textStorageRef
        
        //_textStorageRef.string = "sample"
        
        //_lines = KLines(layoutManager: self, textStorageRef: _textStorageRef)
        
        textStorageRef.addObserver { [weak self] modification in
            self?.textStorageDidModify(modification)
        }
        
        rebuildLayout()
    }

    // MARK: - Layout
    
    func rebuildLayout(reason: KRebuildReason = .destructiveChange) {
        guard let layoutRects = makeLayoutRects() else { log("layoutRects is nil", from:self); return }
        let lineNumberRegionWidth = layoutRects.lineNumberRegion?.rect.width ?? 0
        if lineNumberRegionWidth != _prevLineNumberRegionWidth {
            _prevLineNumberRegionWidth = lineNumberRegionWidth
            _lines.rebuildLines()
            return
        }
        
        switch reason {
        case .charactersChanged(range: let range, insertedCount: let insertedCount):
            _lines.rebuildLines()
        case .attributesChanged:
            // 将来的に実装
            _lines.rebuildLines()
        case .destructiveChange:
            _lines.rebuildLines()
        }
        
        
        
        if let wordWrap = _textView?.wordWrap,
                let visibleRectWidth = _textView?.visibleRect.width {
            if wordWrap {
                _maxLineWidth = visibleRectWidth
            } else {
                _maxLineWidth = _lines.maxLineWidth
            }
        }
        
              
    }
    
    
    // TextStorageが変更された際に呼び出される。
    func textStorageDidModify(_ modification: KStorageModified) {
        guard let view = textView else { log("KLayoutManager - textStorageDidChange - textView is nil", from:self); return }
        
        switch modification {
        case let .textChanged(range, insertedCount):
            
            //log("range: \(range), insertedCount: \(insertedCount)",from:self)
            
            rebuildLayout(reason: .charactersChanged(range: range, insertedCount: insertedCount))
            view.textStorageDidModify(modification)

        case let .colorChanged(range):
            print("🎨 カラー変更: range = \(range)")
            
        }
    }
    
    // TextViewのframeが変更された際に呼び出される。
    func textViewFrameInvalidated() {
        if let wordWrap = _textView?.wordWrap, wordWrap {
            rebuildLayout()
        }
        
        //print("\(#function): call rebuildLayout()")
        //_textView?.updateFrameSizeToFitContent()
    }
 
    
    // characterIndex文字目の文字が含まれるKLineとその行番号(ソフトラップの)を返す。
    // 現在の文字がテキストの最後の場合には(nil, -1)が返る。
    func line(at characterIndex: Int) -> (line: KLine?, lineIndex: Int) {
        //for (i, line) in lines.enumerated() {
        //log("lines.count = \(lines.count)", from:self)
        
        for i in 0..<lines.count {
            guard let line = lines[i] else { log("line is nil.", from:self); continue }
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
        guard let textView = _textView else { log("textView = nil", from:self); return nil }
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
        return KLine(range: index..<index, hardLineIndex: hardLineIndex, softLineIndex: 0, layoutManager: self, textStorageRef: _textStorageRef)
    }
    
    
    func makeLines(range: Range<Int>, hardLineIndex: Int, width: CGFloat?) -> [KLine]? {
        let hardLine = KLine(range: range, hardLineIndex: hardLineIndex, softLineIndex: 0, layoutManager: self, textStorageRef: _textStorageRef)

        guard let textWidth = width, wordWrap == true else {
            
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
                                     layoutManager: self,
                                     textStorageRef: _textStorageRef)
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
                                 layoutManager: self,
                                 textStorageRef: _textStorageRef)
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
        
        let fullLine = CTLineCreateWithAttributedString(attributedString)
        
        var baseOffset: CGFloat = 0
        var baseIndex: Int = 0
        for i in 0..<attributedString.length {
            let offset = CTLineGetOffsetForStringIndex(fullLine, i, nil)
            
            if offset - baseOffset >= width {
                
                let subAttr = attributedString.attributedSubstring(from: NSRange(location: baseIndex, length: i - baseIndex))
                lines.append(CTLineCreateWithAttributedString(subAttr))
                baseIndex = i
                baseOffset = offset
            }
        }
        let subAttr = attributedString.attributedSubstring(from: NSRange(location: baseIndex, length: attributedString.length - baseIndex))
        //log("subAttr = \(subAttr.string)", from:self)
        lines.append(CTLineCreateWithAttributedString(subAttr))
        
        return lines
        
    }
    
    
}


