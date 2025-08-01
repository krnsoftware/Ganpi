//
//  KLine.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
// 表示される行1行を表すクラス。ソフトラップの場合はハードラップの行が複数に分割されて見た目のままの行配列になる。

import Cocoa

class KLine: CustomStringConvertible {
    fileprivate weak var _layoutManager: KLayoutManager?
    fileprivate weak var _textStorageRef: KTextStorageReadable?
    private var _ctLine: CTLine?
    fileprivate var _cachedOffsets: [CGFloat]
    private var _widthAndOffsetsFixed: Bool = false
    
    var range: Range<Int>
    var hardLineIndex: Int
    let softLineIndex: Int
    
    // 有効なCTLineを返す。
    var ctLine: CTLine? {
        if _ctLine == nil {
            makeCTLine()
        }
        return _ctLine
    }
    
    // 行の幅をCGFloatで返す。
    var width: CGFloat {
        return _cachedOffsets.last ?? 0.0
    }
    
    var description: String {
        return "KLine - range: \(range), hardLineIndex: \(hardLineIndex), softLineIndex: \(softLineIndex)"
    }
    
    
    init(range: Range<Int>, hardLineIndex: Int, softLineIndex: Int, layoutManager: KLayoutManager, textStorageRef: KTextStorageReadable){
        self.range = range
        self.hardLineIndex = hardLineIndex
        self.softLineIndex = softLineIndex
        self._layoutManager = layoutManager
        self._textStorageRef = textStorageRef
        
        // 文字のオフセットをadcanveから算出してcache。
        // この値は実測に比べて不正確のため、CTLineが生成された時点で正確なものに入れ替えられる。
        /*
        var result:[CGFloat] = [0.0]
        _ = textStorageRef.advances(in: range).reduce(into: 0) { sum, value in
            sum += value
            result.append(sum)
        }
        _cachedOffsets = result*/
        
        // 文頭の連続したtabはタブ幅に従って、それ以外のtabはspaceと同じ幅でoffsetsを構築する。
        // この値はCTLineによる実測に比べ不正確なため、行の横幅を計算する以外の用途には用いられない。
        /*
        let tabCar:Character = "\t"
        let tabWidth = CGFloat(layoutManager.tabWidth) * textStorageRef.spaceAdvance
        var result:[CGFloat] = [0.0]
        var isInHeadTabs:Bool = true
        var offset:CGFloat = 0.0
        for i in range.lowerBound..<range.upperBound {
            guard let char = textStorageRef[i] else { log("textStorageRef[i] = nil."); continue }
            if isInHeadTabs, char == tabCar {
                offset += tabWidth
                
            } else {
                isInHeadTabs = false
                if char == tabCar {
                    offset += textStorageRef.spaceAdvance
                } else {
                    offset += textStorageRef.advance(for: char)
                }
            }
            result.append(offset)
        }
        _cachedOffsets = result
         */
        //  460ms->370ms
        let tabChar: Character = "\t"
        let tabWidth = CGFloat(layoutManager.tabWidth) * textStorageRef.spaceAdvance
        let chars = textStorageRef.characterSlice[range]

        var result: [CGFloat] = [0.0]
        var offset: CGFloat = 0.0
        var index = 0

        // 行頭の連続tabのみ特別扱い
        for ch in chars {
            if ch == tabChar {
                offset += tabWidth
                result.append(offset)
                index += 1
            } else {
                break
            }
        }

        // 残りをadvance(for:)ですべて処理（tabも含む）
        for ch in chars.dropFirst(index) {
            offset += textStorageRef.advance(for: ch) // "\t"も高速に処理される
            result.append(offset)
        }
        _cachedOffsets = result
    }
    
    func shiftRange(by delta:Int){
        range = (range.lowerBound + delta)..<(range.upperBound + delta)
    }
    
    func shiftHardLineIndex(by delta:Int){
        hardLineIndex += delta
    }
    
    func removeCTLine() {
        _ctLine = nil
    }
    
    // この行における文字のオフセットを行の左端を0.0とした相対座標のx位置のリストで返す。
    func characterOffsets() -> [CGFloat] {
        // offsetを取得する前にCTLineを生成しておく必要がある。
        _ = ctLine
        
        return _cachedOffsets
    }
    
    // この行におけるindex文字目の相対位置を返す。
    func characterOffset(at index:Int) -> CGFloat {
        // offsetを取得する前にCTLineを生成しておく必要がある。
        _ = ctLine
        
        if index < 0 || index >= _cachedOffsets.count {
            log("index(\(index)) out of range.",from:self)
            return 0.0
        }
        
        return _cachedOffsets[index]
    }
    
    // KTextView.draw()から利用される描画メソッド
    func draw(at point: CGPoint, in bounds: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { log("NSGraphicsContext.current is nil.", from: self); return }
        guard let ctLine = self.ctLine else { log("ctLine is nil.", from: self); return }
        guard let textStorageRef = _textStorageRef else { log("_textStorageRef is nil.", from: self); return }
        guard let layoutManager = _layoutManager else { log("_layoutManager is nil.", from: self); return }

        context.saveGState()
            
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1.0, y: -1.0)
            
        let ascent = CTFontGetAscent(textStorageRef.baseFont)
        let lineOriginY = bounds.height - point.y - ascent
        context.textPosition = CGPoint(x: point.x, y: lineOriginY)
        
        CTLineDraw(ctLine, context)
        
        // 不可視文字を表示。
        // 最初はattributedstring.draw(at:)で描画する予定だったが、contextの混乱が生じてどうやっても上手く描画できずCTLineを使用することになった。
        if layoutManager.showInvisibleCharacters {
            let newlineChar:Character = "\n"
            var index = 0
            for i in range.lowerBound..<range.upperBound {
                guard let char = textStorageRef[i] else { log("textStorageRef[\(i)] is nil."); return }
                
                if let ctChar = textStorageRef.invisibleCharacters?.ctLine(for: char) {
                    context.textPosition = CGPoint(x: point.x + _cachedOffsets[index], y: lineOriginY)
                    CTLineDraw(ctChar, context)
                }
                index += 1
            }
            if range.upperBound < textStorageRef.count, textStorageRef[range.upperBound] == newlineChar {
                if let newlineCTChar = textStorageRef.invisibleCharacters?.ctLine(for: newlineChar) {
                    context.textPosition = CGPoint(x: point.x + _cachedOffsets.last!, y: lineOriginY)
                    CTLineDraw(newlineCTChar, context)
                }
            }
        }
        
        context.restoreGState()
        
    }
    
    // この行のCTLineを作成する。
    // 同時に、offsetsのキャッシュをadvanceのキャッシュから生成した暫定のものからCTLineを利用した正確なものに入れ替え。
    private func makeCTLine() {
        guard let textStorageRef = _textStorageRef else {
            log("textStorageRef is nil.", from: self)
            return
        }
        guard let layoutManager = _layoutManager else {
            log("layoutManager is nil.", from: self)
            return
        }

        guard let attrString = textStorageRef.attributedString(for: range, tabWidth: layoutManager.tabWidth) else {
            log("attrString is nil.", from: self)
            return
        }

        let ctLine = CTLineCreateWithAttributedString(attrString)
        _ctLine = ctLine

        // CTLineから文字のoffsetを算出してcacheを入れ替える。
        if !_widthAndOffsetsFixed {
            let string = attrString.string
            var offsets: [CGFloat] = []
            
            for i in 0...string.count {
                let prefixCount = string.index(string.startIndex, offsetBy: i).utf16Offset(in: string)
                let offset = CTLineGetOffsetForStringIndex(ctLine, prefixCount, nil)
                offsets.append(offset)
            }
            _cachedOffsets = offsets.isEmpty ? [0.0] : offsets
            _widthAndOffsetsFixed = true
        }
    }
    
   
    
    
    
}

// MARK: - KFakeLine

final class KFakeLine : KLine {
    private let _ctLine: CTLine
    private let _attributedString: NSAttributedString
    
    override var ctLine: CTLine? { _ctLine }
    
    override var width: CGFloat {
        return _cachedOffsets.last ?? 0
    }
    
    
    init(attributedString: NSAttributedString, hardLineIndex: Int, softLineIndex: Int, layoutManager: KLayoutManager, textStorageRef: KTextStorageReadable) {
        _ctLine = CTLineCreateWithAttributedString(attributedString)
        _attributedString = attributedString
        
        super.init(range: 0..<0, hardLineIndex: hardLineIndex, softLineIndex: softLineIndex, layoutManager: layoutManager, textStorageRef: textStorageRef)
        
        let string = _attributedString.string
        var offsets: [CGFloat] = []
        for i in 0...string.count {
            let prefixCount = string.index(string.startIndex, offsetBy: i).utf16Offset(in: string)
            let offset = CTLineGetOffsetForStringIndex(_ctLine, prefixCount, nil)
            offsets.append(offset)
        }
        _cachedOffsets = offsets.isEmpty ? [0.0] : offsets
    }
}


// MARK: - KLines
// KLineを保持するクラス。
// 格納された行は見た目の行構成をそのまま表している。つまりソフトラップを1行として上から順に並んでいる。
// KTextView.draw()内で、Text Inputによる変換中の文字列を扱うために仮の文字列を挿入する機能を持つ。
// 仮文字列はdraw()の最初に設定(addFakeLine)し、最後に削除(removeFakeLine)すること。

final class KLines: CustomStringConvertible {
    private var _lines: [KLine] = []
    
    // cache.
    private var _hardLineIndexMap: [Int:Int] = [:]
    private var _replaceLineIndex: Int? // index of first line of replaced lines (soft-lines)
    private var _replaceLineCount: Int? // count of replaced lines (soft-lines)
    
    private var _fakeLines: [KFakeLine] = []
    private var _replaceLineNumber: Int = 0 // hard-line number.
    
    private weak var _layoutManager: KLayoutManager?
    private weak var _textStorageRef: KTextStorageReadable?
    
    var hasFakeLine: Bool { _fakeLines.isEmpty == false }
    var fakeLines: [KFakeLine] { _fakeLines }
    var replaceLineNumber: Int { _replaceLineNumber }
    
    // 格納するKLineの数を返す。
    // fakeLinesがある場合、fakeLinesの行数からオリジナルの行数を引いたものを追加する。
    var count: Int {
        guard !_fakeLines.isEmpty else { return _lines.count }
        //let originalLineCount = lines(hardLineIndex: _replaceLineNumber).count
        guard let originalLineCount = countSoftLinesOf(hardLineIndex: _replaceLineNumber) else {
            log("originalLineCount is nil",from:self)
            return -1
        }

        return _lines.count + _fakeLines.count - originalLineCount
    }
    
    var maxLineWidth: CGFloat {
        _lines.map{ $0.width }.max() ?? 0.0
    }
    
    // _linesのデータが正しいかチェックする。
    var isValid: Bool {
        guard !_lines.isEmpty else {
            log("_lines.isEmpty", from: self)
            return false
        }

        var expectedHardLineIndex = _lines[0].hardLineIndex
        var expectedSoftLineIndex = 0
        var currentRange = _lines[0].range

        for i in 1..<_lines.count {
            let line = _lines[i]

            if line.hardLineIndex == expectedHardLineIndex {
                // 同一ハードライン内のソフトライン継続
                expectedSoftLineIndex += 1
                if line.softLineIndex != expectedSoftLineIndex {
                    log("error: unexpected softLineIndex at index \(i)", from: self)
                    return false
                }
                if line.range.lowerBound != currentRange.upperBound {
                    log("error: range discontinuity within hardLine at index \(i)", from: self)
                    return false
                }
            } else if line.hardLineIndex == expectedHardLineIndex + 1 {
                // 新しいハードラインの開始
                expectedHardLineIndex += 1
                expectedSoftLineIndex = 0
                if line.softLineIndex != expectedSoftLineIndex {
                    log("error: expected softLineIndex 0 at new hardLine \(i)", from: self)
                    return false
                }
                if line.range.lowerBound != currentRange.upperBound + 1 {
                    log("error: range gap between hardLines at index \(i)", from: self)
                    return false
                }
            } else {
                log("error: unexpected hardLineIndex at index \(i)", from: self)
                return false
            }

            currentRange = line.range
        }

        return true
    }
    
    // 文字列に変換される際の文字列を返す。
    var description: String {
        return "KLines - count: \(_lines.count), valid?: \(isValid)"
    }
    
    
    init(layoutManager: KLayoutManager?, textStorageRef: KTextStorageReadable?) {
        _layoutManager = layoutManager
        _textStorageRef = textStorageRef
        
        rebuildLines()
        
    }
    
    
    
    // 外部から特定の行について別のAttributedStringを挿入することができる。
    // hardLineIndex行のinsertionオフセットの部分にattrStringを挿入する形になる。
    func addFakeLine(replacementRange: Range<Int>, attrString: NSAttributedString) {
                
        _fakeLines = []
        guard let textStorageRef = _textStorageRef else { print("\(#function) - textStorageRef is nil"); return }
        guard let layoutManager = _layoutManager else { print("\(#function) - layoutManagerRef is nil"); return }
        
        guard let  hardLineIndex = lineContainsCharacter(index: replacementRange.lowerBound)?.hardLineIndex else { print("\(#function) - replacementRange.lowerBound is out of range"); return }
        _replaceLineNumber = hardLineIndex
        
        guard let range = hardLineRange(hardLineIndex: hardLineIndex) else { print("\(#function) - hardLineIndex:\(hardLineIndex) is out of range"); return }
        
        guard let layoutRects = _layoutManager?.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        if let lineA = textStorageRef.attributedString(for: range.lowerBound..<replacementRange.lowerBound, tabWidth: nil),
           let lineB = textStorageRef.attributedString(for: replacementRange.upperBound..<range.upperBound, tabWidth: nil){
            let muAttrString =  NSMutableAttributedString(attributedString: attrString)
            muAttrString.addAttribute(.font, value: textStorageRef.baseFont, range: NSRange(location: 0, length: muAttrString.length))
            
            let fullLine = NSMutableAttributedString()
            fullLine.append(lineA)
            fullLine.append(muAttrString)
            fullLine.append(lineB)
            
            let width: CGFloat? = layoutManager.wordWrap ? layoutRects.textRegionWidth - layoutRects.textEdgeInsets.right : nil
            
            _fakeLines.append(contentsOf: layoutManager.makeFakeLines(from: fullLine, hardLineIndex: hardLineIndex, width: width))
        }
        
        _replaceLineCount = countSoftLinesOf(hardLineIndex: _replaceLineNumber)
        _replaceLineIndex = lineArrayIndex(for: _replaceLineNumber)
    }
    
    func removeFakeLines() {
        _fakeLines.removeAll()
        _replaceLineIndex = nil
        _replaceLineCount = nil
        
    }
    
    func removeAllLines() {
        _lines.removeAll()
        _fakeLines.removeAll()
    }
    
    subscript(i: Int) -> KLine? {
        if !hasFakeLine { return _lines[i] }
        
        /*
        guard let lineArrayIndex = lineArrayIndex(for: _replaceLineNumber) else {
            log("lineArrayIndex == nil, _replaceLineNumber = \(_replaceLineNumber)", from: self)
            return nil
        }*/
        guard let lineArrayIndex = _replaceLineIndex else { log("_fakeLineIndex = nil.", from:self); return nil}
        guard let replaceLineCount = _replaceLineCount else { log("_fakeLineCount = nil.", from:self); return nil}
        
        
        guard i >= 0 && i < count else { log("i is out of range.", from: self); return nil }
        
        // IM稼働中ではないか、あるいは入力中の行より前の場合にはそのまま返す。
        if !hasFakeLine || i < lineArrayIndex  { /*log("normal.", from:self);*/ return _lines[i] }
        
             
        // 入力中の行の場合は、fake行を返す。
        if lineArrayIndex <= i, i < lineArrayIndex + _fakeLines.count {
            //log("fake.", from:self)
            return _fakeLines[i - lineArrayIndex] as KLine?
        }
        
        // 入力中の行より後の場合は、入力中の行の次の行を連続して取得できるようずらす。
        //let convertedCount = i - _fakeLines.count + lines(hardLineIndex: _replaceLineNumber).count
        let convertedCount = i - _fakeLines.count + replaceLineCount
        //log("slided.", from:self)
        
        return _lines[convertedCount]
        
    }
    
    
    // for debug.
    func printLines() {
        let linesCount = count
        guard let textStorageRef = _textStorageRef else { print("\(#function) - textStorageRef is nil (\(linesCount)"); return}
        for i in 0..<linesCount {
            if let line = self[i] {
                let string = String(textStorageRef.characterSlice[line.range])
                print("KLine: No.\(i) - \(string)")
            }
            
        }
    }
    
    // 行の構成を再構築する。
    func rebuildLines(with info: KStorageModifiedInfo? = nil) {
        guard let textStorageRef = _textStorageRef else { log("textStorageRef is nil", from:self); return }
        guard let layoutManager = _layoutManager else { log("layoutManager is nil", from:self); return }
        guard let layoutRects = layoutManager.makeLayoutRects() else { log("layoutRects is nil", from:self); return }
        
        // storageが空だった場合は空行を追加するのみ。
        if textStorageRef.count == 0 {
            _lines.removeAll()
            _lines.append(layoutManager.makeEmptyLine(index: 0, hardLineIndex: 0))
            _hardLineIndexMap.removeAll()
            _hardLineIndexMap[0] = 0
            return
        }
        
        let newLineCharacter:Character = "\n"
        let characters = textStorageRef.characterSlice
        
        var newRange = 0..<textStorageRef.count
        //var startIndex = 0
        var removeRange = 0..<_lines.count
        
        if let info = info {
            /// 削除前の range.lowerBound に属していた KLine を特定
            guard let startSoftLine = lineContainsCharacter(index: info.range.lowerBound) else {
                log("startLine not found", from: self)
                return
            }

            /// その行の hardLineIndex を取得
            let startHardLineIndex = startSoftLine.hardLineIndex

            /// KLine 配列上の startIndex を取得
            //guard let startHardLineArrayIndex = lineArrayIndex(for: startHardLineIndex, softLineIndex: startSoftLine.softLineIndex) else {
            guard let startHardLineArrayIndex = lineArrayIndex(for: startHardLineIndex) else {
                log("startIndex not found", from: self)
                return
            }

            /// 削除対象のハード行数（改行 + 1）
            let deleteHardLineCount = info.deletedNewlineCount + 1

            /// 削除対象の末尾ハード行の行番号
            let lastHardLineIndex = startHardLineIndex + deleteHardLineCount - 1

            /// 末尾ハード行の先頭 index を取得
            guard let lastHardLineStartIndex = lineArrayIndex(for: lastHardLineIndex) else {
                log("lastHardLineStartIndex not found", from: self)
                return
            }

            /// 末尾ハード行のソフト行数を取得
            guard let softCount = countSoftLinesOf(hardLineIndex: lastHardLineIndex) else {
                log("softLine count not found for hardLineIndex \(lastHardLineIndex)", from: self)
                return
            }

            /// 削除対象の範囲
            let endIndex = lastHardLineStartIndex + softCount
            removeRange = startHardLineArrayIndex..<endIndex
            
            let characters = textStorageRef.characterSlice
            let newLineCharacter: Character = "\n"

            var lower = info.range.lowerBound
            var upper = info.range.lowerBound + info.insertedCount

            // 前方：行頭まで戻る
            while lower > 0 {
                if characters[lower - 1] == newLineCharacter { break }
                lower -= 1
            }

            // 後方：行末（改行を含めた直後）まで進む
            while upper < characters.count {
                if characters[upper] == newLineCharacter {
                    upper += 1 // 改行そのものも範囲に含める
                    break
                }
                upper += 1
            }

            newRange = lower..<upper
            
            /*_lines[removeRange.upperBound..<_lines.count].forEach {
                $0.shiftRange(by: info.insertedCount - info.range.count)
                $0.shiftHardLineIndex(by: info.insertedNewlineCount - info.deletedNewlineCount)
                //log("line index shifted by \(info.insertedNewlineCount - info.deletedNewlineCount)")
            }*/
            
            
            DispatchQueue.concurrentPerform(iterations: _lines.count - removeRange.upperBound) { i in
                _lines[removeRange.upperBound + i].shiftRange(by: info.insertedCount - info.range.count)
                _lines[removeRange.upperBound + i].shiftHardLineIndex(by: info.insertedNewlineCount - info.deletedNewlineCount)
            }
            
            //_lines.forEach { $0.removeCTLine() }
            DispatchQueue.concurrentPerform(iterations: _lines.count) { i in
                _lines[i].removeCTLine()
            }
        }
        
        // その領域の文字列に含まれる行の領域の配列を得る。
        var lineRanges:[Range<Int>] = []
        var start = newRange.lowerBound
        for i in newRange {
            if characters[i] == newLineCharacter {
                if start < i {
                    lineRanges.append(start..<i)
                } else {
                    lineRanges.append(start..<start)
                }
                start = i + 1
            }
        }
        if start < newRange.upperBound {
            lineRanges.append(start..<newRange.upperBound)
        }
        /*
        guard let newStartLine = lineContainsCharacter(index: newRange.lowerBound) else { log("newStartLine is nil", from:self); return }
        let newStartHardLineIndex = newStartLine.hardLineIndex
        var newLines:[KLine] = []
        for (i, range) in lineRanges.enumerated() {
            guard let lineArray = layoutManager.makeLines(range: range, hardLineIndex: (newStartHardLineIndex + i), width: layoutRects.textRegionWidth - layoutRects.textEdgeInsets.right) else {
                log("lineArray is nil", from:self)
                return
            }
            newLines.append(contentsOf: lineArray)
        }
        
        _lines.replaceSubrange(removeRange, with: newLines)*/
        
        // 並列処理を導入する。15000行のデータで1200ms->460msに短縮。
        guard let newStartLine = lineContainsCharacter(index: newRange.lowerBound) else {
            log("newStartLine is nil", from: self)
            return
        }
        let newStartHardLineIndex = newStartLine.hardLineIndex

        
        var newLinesBuffer = Array(repeating: [KLine](), count: lineRanges.count)
        let width = layoutRects.textRegionWidth - layoutRects.textEdgeInsets.right

        DispatchQueue.concurrentPerform(iterations: lineRanges.count) { i in
            let range = lineRanges[i]
            let hardLineIndex = newStartHardLineIndex + i
            if let lineArray = layoutManager.makeLines(range: range, hardLineIndex: hardLineIndex, width: width) {
                newLinesBuffer[i] = lineArray
            } else {
                log("lineArray is nil for index \(i)", from: self)
                // エラー通知にする場合は別途検出処理を入れる必要あり
            }
        }

        let newLines = newLinesBuffer.flatMap { $0 }
        _lines.replaceSubrange(removeRange, with: newLines)
        
        // kokomade
        
        guard let newLastLine = _lines.last else {
            log("newLastLine is nil", from: self)
            return
        }

        let count = characters.count

        // 最後の文字が改行で、かつ最後のKLineが末尾に達していなければ空行を追加
        if characters.last == "\n" && newLastLine.range.upperBound < count {
            let emptyLine = layoutManager.makeEmptyLine(index: textStorageRef.count, hardLineIndex: newLastLine.hardLineIndex + 1)
            _lines.append(emptyLine)
        }
        
        log("isValid: \(isValid)",from:self)

        // mapも再構築
        _hardLineIndexMap.removeAll()
        for (i, line) in _lines.enumerated() where line.softLineIndex == 0 {
            _hardLineIndexMap[line.hardLineIndex] = i
        }
        
    }
    
    
    
    // ハード行の行番号hardLineIndexの行を取り出す。ソフトラップの場合は複数行になることがある。
    func lines(hardLineIndex: Int) -> [KLine]? {
        guard let startIndex = _hardLineIndexMap[hardLineIndex] else {
            log("_hardLineIndexMap[\(hardLineIndex)] not found", from: self)
            return nil
        }

        var lines: [KLine] = []
        for i in startIndex..<_lines.count {
            let line = _lines[i]
            if line.hardLineIndex == hardLineIndex {
                lines.append(line)
            } else {
                break
            }
        }

        return lines.isEmpty ? nil : lines
    }
    
    // ハード行の行番号hardLineIndexの行に含まれるソフト行の数を返す。
    func countSoftLinesOf(hardLineIndex: Int) -> Int? {
        guard let startIndex = _hardLineIndexMap[hardLineIndex] else {
            log("_hardLineIndexMap[\(hardLineIndex)] not found",from:self)
            return nil
        }
        var count = 0
        for i in startIndex..<_lines.count {
            let line = _lines[i]
            if line.hardLineIndex == hardLineIndex {
                count += 1
            } else {
                break
            }
        }
        if count == 0 { log("nothing...",from:self) }
        return count > 0 ? count : nil
    }
    
    
    // ハード行の番号iの行のRangeを得る。行末の改行は含まない。
    func hardLineRange(hardLineIndex: Int) -> Range<Int>? {
        guard let lines = lines(hardLineIndex: hardLineIndex) else { log("hardLineRange(\(hardLineIndex)) not found",from:self); return nil}
        //guard !lines.isEmpty else { return nil }
        if lines.isEmpty {
            return nil
        }
        
        return lines.first!.range.lowerBound..<lines.last!.range.upperBound
    }
    
    // index文字目を含む行の_lines上のindexを返す。ソフト・ハードを問わない。
    func lineIndexContainsCharacter(index: Int) -> Int? {
        guard let textStorageRef = _textStorageRef else {
            log("\(#function): textStorageRef is nil",from:self)
            return nil
        }

        let count = textStorageRef.count
        guard count > 0 else { return 0 }
        guard index >= 0 && index <= count else {
            log("index out of range (\(index))", from: self)
            return nil
        }

        var low = 0
        var high = _lines.count - 1

        while low <= high {
            let mid = (low + high) / 2
            guard mid < _lines.count else {
                log("mid out of range", from: self)
                return nil
            }

            let line = _lines[mid]
            let range = line.range.lowerBound ..< (line.range.upperBound + 1)  // include newline

            if range.contains(index) {
                return mid
            } else if index < range.lowerBound {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        log("no match for index \(index)", from: self)
        return nil
    }
    
    // index文字目の文字を含む行のKLineインスタンスを返す。
    func lineContainsCharacter(index: Int) -> KLine? {
        guard let lineIndex = lineIndexContainsCharacter(index: index) else { log("no line contains character at index \(index)"); return nil }
        return _lines[lineIndex]
    }
 
    // hardLineIndexを持つ行を返す。softLineIndexを指定することもできる。
    func lineArrayIndex(for hardLineIndex: Int, softLineIndex: Int = 0) -> Int? {
        guard let lineIndex = _hardLineIndexMap[hardLineIndex] else {
            log("lineIndex not found.", from: self)
            return nil
        }

        if softLineIndex == 0 {
            return lineIndex
        }

        for i in (lineIndex + 1)..<_lines.count {
            let line = _lines[i]
            if line.softLineIndex == 0 {
                break
            }
            if line.softLineIndex == softLineIndex {
                return i
            }
        }

        return nil
    }
    
    // Text Input ClientのfirstRect()でRectを返すためのpointを返す。
    func pointForFirstRect(for characterIndex: Int) -> CGPoint? {
        guard let layoutManager = _layoutManager else { log("layoutManager not found.", from: self); return nil }
        guard let layoutRects = layoutManager.makeLayoutRects() else { log("layoutRects not found.", from: self); return nil }
        
        guard let lineIndex = lineIndexContainsCharacter(index: characterIndex) else { log("lineIndex not found.", from: self); return .zero}
        
        
        let line = _lines[lineIndex]
        let offset = line.characterOffset(at: characterIndex - line.range.lowerBound)
        let x = layoutRects.textRegion.rect.origin.x + layoutRects.horizontalInsets + offset
        let y = layoutRects.textEdgeInsets.top + CGFloat(lineIndex + 1) * layoutManager.lineHeight
        
        return CGPoint(x: x, y: y)
    }
    
}
