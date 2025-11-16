//
//  KLayoutManager.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa


// MARK: - protocol KLayoutManagerReadable

protocol KLayoutManagerReadable: AnyObject {
    var lines: KLines { get }
    var lineCount: Int { get }
    var lineHeight: CGFloat { get }
    var lineSpacing: CGFloat { get }
    var maxLineWidth: CGFloat { get }
    var fontHeight: CGFloat { get }
    
    func makeLayoutRects() -> KLayoutRects?
    func makeEmptyLine(index: Int, hardLineIndex: Int) -> KLine
    func makeLines(range: Range<Int>, hardLineIndex: Int, width: CGFloat?) -> [KLine]?
    func makeFakeLines(from attributedString: NSAttributedString,hardLineIndex: Int, width: CGFloat?) -> [KFakeLine]
}

// MARK: - Struct and Enum.

// 行の折り返しの際、折り返された2行目以降の行のオフセットをどうするかの種別。
enum KWrapLineOffsetType : Int {
    case none = 0 // オフセットなし
    case same = 1 // 最初の行と同じオフセット
    case tab1 = 2 // 最初の行の更に1tab分右にオフセット
    case tab1_5 = 3 // 最初の行の更に1.5tab分右にオフセット
    case tab2 = 4 // 最初の行の更に2tab分右にオフセット
    
    static func fromSetting(_ raw:String) -> KWrapLineOffsetType {
        switch raw.lowercased() {
        case "none": return .none
        case "same": return .same
        case "1tab": return .tab1
        case "1.5tab": return .tab1_5
        case "2tab": return .tab2
        default: return .none
        }
    }
}


// MARK: - KLayoutManager

// テキストのレイアウトを担当するクラス。KTextViewインスタンスそれぞれに1つ存在する。
final class KLayoutManager: KLayoutManagerReadable {
    
    // MARK: - Struct and Enum.
    
    enum KRebuildReason {
        case charactersChanged(info: KStorageModifiedInfo)
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
    private var _tabWidth: Int = 2
    
    private var _prevLineNumberRegionWidth: CGFloat = 0
    
    private var _lineSpacing: CGFloat = 2.0
    
    private var _wrapLineOffsetType: KWrapLineOffsetType = .same
    
    // 表示される行をまとめるKLinesクラスインスタンス。
    private lazy var _lines: KLines = {
        return KLines(layoutManager: self, textStorageRef: _textStorageRef)
    }()
    
    // 行間設定。
    //var lineSpacing: CGFloat = 2.0
    var lineSpacing: CGFloat {
        get { _lineSpacing }
        set {
            _lineSpacing = newValue
            textView?.textStorageDidModify(.colorChanged(range: 0..<_textStorageRef.count))
        }
    }
    
    var lineHeight: CGFloat {
        let font = _textStorageRef.baseFont
        return font.ascender - font.descender + font.leading + lineSpacing
    }
    
    var fontHeight: CGFloat {
        let font = _textStorageRef.baseFont
        return font.ascender - font.descender
    }
    
    var lineCount: Int {
        return _lines.count
    }
    
    var wrapLineOffsetType: KWrapLineOffsetType {
        get { _wrapLineOffsetType }
        set {
            _wrapLineOffsetType = newValue
            rebuildLayout()
            
            textView?.textStorageDidModify(.colorChanged(range: 0..<_textStorageRef.count))
        }
    }
    
    // KLinesが持つ最も幅の大きな行の幅を返します。表示マージンなし。
    // hardwrapの場合にlayoutRects.textRegion.rect.widthを設定するために使用する。
    // softwrapであっても値は返すが、内容は不定。
    var maxLineWidth: CGFloat {
        //return _maxLineWidth
        guard let textView = _textView else { log("_textView = nil", from:self); return 0 }
        let visibleRectWidth = textView.visibleRect.width
        
        return wordWrap ? visibleRectWidth : _lines.maxLineWidth
    }
    
    
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
    
    var showInvisibleCharacters: Bool {
        guard let textView = _textView else { log("_textView = nil", from:self); return false }
        return textView.showInvisibleCharacters
    }
    
    
    // MARK: - Init

    init(textStorageRef: KTextStorageProtocol) {
        _textStorageRef = textStorageRef
        
        _textStorageRef.addObserver(self) { [weak self] note in
                guard let self else { return }
            switch note {
            case .textChanged(let info):
                self.rebuildLayout(reason: .charactersChanged(info: info))
                self.textView?.textStorageDidModify(note)
            case .colorChanged(_):
                self.rebuildLayout(reason: .destructiveChange)
                self.textView?.textStorageDidModify(.colorChanged(range: 0..<_textStorageRef.count))
            }
        }
        
    }
    
    deinit {
        _textStorageRef.removeObserver(self)
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
        case .charactersChanged(let info):
            //let timer = KTimeChecker(name:".charactersChanged")
            _lines.rebuildLines(with: info)
            //timer.stop()
        case .attributesChanged:
            log("attributedChanged?", from:self)
        case .destructiveChange:
            _lines.rebuildLines()
        }
        
    }
    
    // TextViewのframeが変更された際に呼び出される。
    func textViewFrameInvalidated() {
        if let wordWrap = _textView?.wordWrap, wordWrap {
            rebuildLayout()
        }
        
    }
    
    // 現在のLayoutRectsを生成する。専らTextViewから呼び出される。
    func makeLayoutRects() -> KLayoutRects? {
        guard let textView = _textView else { log("textView = nil", from:self); return nil }
        
        return KLayoutRects(
            layoutManagerRef: self,
            textStorageRef: _textStorageRef,
            visibleRect: textView.visibleRect,
            showLineNumbers: textView.showLineNumbers,
            wordWrap: textView.wordWrap,
            textEdgeInsets: .default
        )
    }
    
    
    
    // MARK: - private function
    
    // 表示用に空行を作成する。
    func makeEmptyLine(index: Int, hardLineIndex: Int) -> KLine {
        return KLine(range: index..<index, hardLineIndex: hardLineIndex, softLineIndex: 0, wordWrapOffset: 0.0, layoutManager: self, textStorageRef: _textStorageRef)
    }
    
    // KLineインスタンスを作成する。
    func makeLines(range: Range<Int>, hardLineIndex: Int, width: CGFloat?) -> [KLine]? {
        
        let hardLine = KLine(range: range, hardLineIndex: hardLineIndex, softLineIndex: 0, wordWrapOffset: 0.0, layoutManager: self, textStorageRef: _textStorageRef)
        
        if hardLine.range.count == 0 {
            return [hardLine]
        }

        guard let textWidth = width, wordWrap == true else {
            return [hardLine]
        }
        
        let leadingLineOffset = leadingWhitespaceOffset(in: range)
        let trailingLineWidth = textWidth - leadingLineOffset
        
        // オフセットリストを取得
        let offsets = hardLine.characterOffsets

        if offsets.count == 0 {
            return [hardLine]
        }
        var softLines: [KLine] = []

        var startIndex = range.lowerBound
        var lastOffset: CGFloat = 0.0
        var softLineIndex = 0
        var isFirstLine = true
       
        for i in 0..<offsets.count {
            let currentOffset = offsets[i]
            let currentTextWidth = isFirstLine ? textWidth : trailingLineWidth
            
            if currentOffset - lastOffset > currentTextWidth {
                let endIndex = range.lowerBound + i
                let softRange = startIndex..<endIndex
                let softLine = KLine(range: softRange,
                                     hardLineIndex: hardLineIndex,
                                     softLineIndex: softLineIndex,
                                     wordWrapOffset: isFirstLine ? 0.0 : leadingLineOffset,
                                     layoutManager: self,
                                     textStorageRef: _textStorageRef)
                softLines.append(softLine)
                softLineIndex += 1
                startIndex = endIndex
                lastOffset = currentOffset
                isFirstLine = false
            }
            
            
        }
        
        // 残りを追加
        if startIndex < range.upperBound {
            let softLine = KLine(range: startIndex..<range.upperBound,
                                 hardLineIndex: hardLineIndex,
                                 softLineIndex: softLineIndex,
                                 wordWrapOffset: isFirstLine ? 0.0 : leadingLineOffset,
                                 layoutManager: self,
                                 textStorageRef: _textStorageRef)
            softLines.append(softLine)
        }
        
        return softLines
    }
    
    // Input methodで入力中の文字列を表示するためのKFakeLineを生成する。
    func makeFakeLines(from attributedString: NSAttributedString,hardLineIndex: Int,
                       width: CGFloat?) -> [KFakeLine] {
        guard attributedString.length > 0 else { return [] }
        guard let textWidth = width else {
            return [KFakeLine(attributedString: attributedString, hardLineIndex: hardLineIndex, softLineIndex: 0, wordWrapOffset: 0.0, layoutManager: self, textStorageRef: _textStorageRef)]
        }
        
        var fakeLines: [KFakeLine] = []
        
        let fullLine = CTLineCreateWithAttributedString(attributedString)
        
        
        guard let hardLineRange = lines.hardLineRange(hardLineIndex: hardLineIndex) else { log("0"); return [] }
        let leadingLineOffset = leadingWhitespaceOffset(in: hardLineRange)
        var isFirstLine = true
        let trailingLineWidth = textWidth - leadingLineOffset
        
        var baseOffset: CGFloat = 0
        var baseIndex: Int = 0
        var softLineIndex: Int = 0
        for i in 0..<attributedString.length {
            let offset = CTLineGetOffsetForStringIndex(fullLine, i, nil)
            let currentTextWidth = isFirstLine ? textWidth : trailingLineWidth
            
            if offset - baseOffset >= currentTextWidth {
                
                let subAttr = attributedString.attributedSubstring(from: NSRange(location: baseIndex, length: i - baseIndex))
                let fakeLine = KFakeLine(attributedString: subAttr,
                                         hardLineIndex: hardLineIndex,
                                         softLineIndex: softLineIndex,
                                         wordWrapOffset:isFirstLine ? 0.0 : leadingLineOffset,//0.0,
                                         layoutManager: self,
                                         textStorageRef: _textStorageRef)
                fakeLines.append(fakeLine)
                baseIndex = i
                baseOffset = offset
                softLineIndex += 1
                isFirstLine = false
            }
        }
        let subAttr = attributedString.attributedSubstring(from: NSRange(location: baseIndex, length: attributedString.length - baseIndex))
        
        fakeLines.append(KFakeLine(attributedString: subAttr,
                                   hardLineIndex: hardLineIndex,
                                   softLineIndex: softLineIndex,
                                   wordWrapOffset: isFirstLine ? 0.0 : leadingLineOffset,//0.0,
                                   layoutManager: self,
                                   textStorageRef: _textStorageRef))
        
        return fakeLines
    }
    
    
    // ソフトウェア行の2行目以降の右オフセットの量を返す。
    private func leadingWhitespaceOffset(in range:Range<Int>) -> CGFloat {
        if wrapLineOffsetType == .none { return 0.0 }
        
        let tabSpaceCount = KTextParagraph.leadingWhitespaceWidth(storage: _textStorageRef, range: range, tabWidth: tabWidth)
        
        let leadingLineOffset:CGFloat
        switch wrapLineOffsetType {
        case .none: leadingLineOffset = 0
        case .same: leadingLineOffset = CGFloat(tabSpaceCount) * _textStorageRef.spaceAdvance
        case .tab1: leadingLineOffset = CGFloat(tabSpaceCount + 1 * tabWidth) * _textStorageRef.spaceAdvance
        case .tab1_5: leadingLineOffset = (CGFloat(tabSpaceCount) + 1.5 * CGFloat(tabWidth)) * _textStorageRef.spaceAdvance
        case .tab2: leadingLineOffset = CGFloat(tabSpaceCount + 2 * tabWidth) * _textStorageRef.spaceAdvance
        }
        return leadingLineOffset
    }
    
}


