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
            
            let line = KLine(range: lineRange, hardLineIndex: currentLineNumber, softLineIndex: 0, layoutManager: self)
            _lines.append(line)
            let width = line.width
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
            rebuildLayout()
            view.textStorageDidModify(modification)
            

        case let .colorChanged(range):
            print("🎨 カラー変更: range = \(range)")
            
        }
    }
    
    /*
    func lineInfo(at index: Int) -> KLineInfo? {
        //print("lineInfo(at: \(index))")
        for line in lines {
            if line.range.contains(index) || index == line.range.upperBound {
                    return line
            }
        }
        return nil
    }*/
    
    // index文字目の存在するKLineを返す。
    func lineInfo(at index: Int) -> KLine? {
        //print("lineInfo(at: \(index))")
        for line in lines {
            if line.range.contains(index) || index == line.range.upperBound {
                    return line
            }
        }
        return nil
    }
    
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
    
    
    /*
    func offsetsForAllGlyphs(in info: LineInfo) -> [CGFloat] {
        var result: [CGFloat] = []
        
        for i in 0..<info.range.count {
            result.appen()
        }
        
        return []
    }*/
    
    
    // MARK: - private function
    
    // 表示用に空行を作成する。
    /*
    private func makeEmptyLine(index: Int, hardLineIndex: Int) -> KLineInfo {
        return KLineInfo(ctLine: CTLineCreateWithAttributedString(NSAttributedString(string: "")),
                        range: index..<index,
                        hardLineIndex: hardLineIndex,
                        softLineIndex: 0)
    }*/
    private func makeEmptyLine(index: Int, hardLineIndex: Int) -> KLine {
        return KLine(range: index..<index, hardLineIndex: hardLineIndex, softLineIndex: 0, layoutManager: self)
    }
    
    
    
    
    
    
}


// MARK: - KLine
// 表示される行1行を表すクラス。ソフトラップの場合はハードラップの行が複数に分割されて見た目のままの行配列になる。

final class KLine {
    private weak var _layoutManager: KLayoutManager?
    private var _ctLine: CTLine?
    private var _obsolete: Bool = false
    
    let range: Range<Int>
    let hardLineIndex: Int
    let softLineIndex: Int
    
    // キャッシュされているCTLineを返す。
    // attributeが変更された場合、表示は無効だがサイズなどは有効のため古いキャッシュをそのまま利用する。
    private var _cachedCTLine: CTLine? {
        if _ctLine == nil {
            _obsolete = false
            makeCTLine()
        }
        return _ctLine
    }
    
    // 有効なCTLineを返す。
    var ctLine: CTLine? {
        if _ctLine == nil || _obsolete {
            _obsolete = false
            //print("\(#function): KLine. build CTLine. hardLineIndex:\(hardLineIndex), softLineIndex:\(softLineIndex)")
            makeCTLine()
        }
        return _ctLine
    }
    
    // 行の幅をCGFloatで返す。
    var width: CGFloat {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return 0.0 }
        
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
    
    init(range: Range<Int>, hardLineIndex: Int, softLineIndex: Int, layoutManager: KLayoutManager){
        self.range = range
        self.hardLineIndex = hardLineIndex
        self.softLineIndex = softLineIndex
        self._layoutManager = layoutManager
    }
    
    func attributesChanged(){
        _obsolete = true
    }
    
    func charactersChanged(){
        _ctLine = nil
    }
    
    // この行における文字のオフセットを行の左端を0.0とした相対座標のx位置のリストで返す。
    func characterOffsets() -> [CGFloat] {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return [] }
        
        let stringRange = CTLineGetStringRange(line)
        let start = stringRange.location
        let length = stringRange.length
        var offsets: [CGFloat] = []
        
        for i in start..<(start + length) {
            let offset = CTLineGetOffsetForStringIndex(line, i, nil)
            offsets.append(offset)
        }
        return offsets
    }
    
    // この行におけるindex文字目の相対位置を返す。
    func characterOffset(at index:Int) -> CGFloat {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return 0.0 }
        
        return CTLineGetOffsetForStringIndex(line, index, nil)
    }
    
    // この行における相対座標のx位置を返す。
    func characterIndex(at x: CGFloat) -> Int {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return 0 }
        
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        
        return index < 0 ? 0 : index // 空行の場合に-1が返るため、その場合は0を返す。
    }
    
    // この行のCTLineを作成する。作成はlayoutManagerに依頼する。
    private func makeCTLine(){
        guard let line = _layoutManager?.ctLine(in: range) else {
            print("\(#function): faild to generate CTLine for range ");
            return
        }
        _ctLine = line
    }
    
    
    
    
}
