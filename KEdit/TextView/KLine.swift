//
//  KLine.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
// 表示される行1行を表すクラス。ソフトラップの場合はハードラップの行が複数に分割されて見た目のままの行配列になる。

import Cocoa

class KLine {
    private weak var _layoutManager: KLayoutManager?
    private weak var _textStorageRef: KTextStorageReadable?
    private var _ctLine: CTLine?
    private var _cachedOffsets: [CGFloat]
    
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
    
    
    init(range: Range<Int>, hardLineIndex: Int, softLineIndex: Int, layoutManager: KLayoutManager, textStorageRef: KTextStorageReadable){
        self.range = range
        self.hardLineIndex = hardLineIndex
        self.softLineIndex = softLineIndex
        self._layoutManager = layoutManager
        self._textStorageRef = textStorageRef
        
        // 文字のオフセットをadcanveから算出してcache。
        var result:[CGFloat] = []
        _ = textStorageRef.advances(in: range).reduce(into: 0) { sum, value in
            sum += value
            result.append(sum)
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
        return _cachedOffsets
    }
    
    // この行におけるindex文字目の相対位置を返す。
    func characterOffset(at index:Int) -> CGFloat {
        guard index >= 0 && index <= _cachedOffsets.count else { log("index is out of range.", from:self); return 0.0 }
        
        if index == 0 {
            return 0
        }
        return _cachedOffsets[index - 1]
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

// MARK: - KFakeLine

final class KFakeLine : KLine {
    private let _ctLine: CTLine
    
    override var ctLine: CTLine? { _ctLine }
    
    override var width: CGFloat { CTLineGetTypographicBounds(_ctLine, nil, nil, nil) }
    
    init(ctLine: CTLine, hardLineIndex: Int, softLineIndex: Int, layoutManager: KLayoutManager, textStorageRef: KTextStorageReadable) {
        _ctLine = ctLine
        super.init(range: 0..<0, hardLineIndex: hardLineIndex, softLineIndex: softLineIndex, layoutManager: layoutManager, textStorageRef: textStorageRef)
    }
}


// MARK: - KLines
// KLineを保持するクラス。
// 格納された行は見た目の行構成をそのまま表している。つまりソフトラップを1行として上から順に並んでいる。
// KTextView.draw()内で、Text Inputによる変換中の文字列を扱うために仮の文字列を挿入する機能を持つ。
// 仮文字列はdraw()の最初に設定(addFakeLine)し、最後に削除(removeFakeLine)すること。

final class KLines {
    private var _lines: [KLine] = []
    //private var _maxLineWidth: CGFloat = 0
    
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
        let originalLineCount = lines(hardLineIndex: _replaceLineNumber).count

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
    
    
    
    init(layoutManager: KLayoutManager?, textStorageRef: KTextStorageReadable?) {
        _layoutManager = layoutManager
        _textStorageRef = textStorageRef
        
        rebuildLines()
        
        /*
        if _lines.count == 0 {
            if let layoutManagerRef = _layoutManager {
                
                _lines.append(layoutManagerRef.makeEmptyLine(index: 0, hardLineIndex: 0))
            }
            
        }*/
    }
    
    
    
    // 外部から特定の行について別のAttributedStringを挿入することができる。
    // hardLineIndex行のinsertionオフセットの部分にattrStringを挿入する形になる。
    func addFakeLine(replacementRange: Range<Int>, attrString: NSAttributedString) {
        let timer = KTimeChecker(name:"KLines.addFakeLine")
        
        
        _fakeLines = []
        guard let textStorageRef = _textStorageRef else { print("\(#function) - textStorageRef is nil"); return }
        guard let layoutManager = _layoutManager else { print("\(#function) - layoutManagerRef is nil"); return }
        
        timer.start(message:"lineContainsCharacter")
        guard let  hardLineIndex = lineContainsCharacter(index: replacementRange.lowerBound)?.hardLineIndex else { print("\(#function) - replacementRange.lowerBound is out of range"); return }
        _replaceLineNumber = hardLineIndex
        
        timer.stopAndGo(message:"hardLineRange")
        guard let range = hardLineRange(hardLineIndex: hardLineIndex) else { print("\(#function) - hardLineIndex:\(hardLineIndex) is out of range"); return }
        
        timer.stopAndGo(message:"makeLayoutRects")
        guard let layoutRects = _layoutManager?.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        timer.stopAndGo(message:"make Attributes")
        
        if let lineA = textStorageRef.attributedString(for: range.lowerBound..<replacementRange.lowerBound, tabWidth: nil),
           let lineB = textStorageRef.attributedString(for: replacementRange.upperBound..<range.upperBound, tabWidth: nil){
            let muAttrString =  NSMutableAttributedString(attributedString: attrString)
            muAttrString.addAttribute(.font, value: textStorageRef.baseFont, range: NSRange(location: 0, length: muAttrString.length))
            
            let fullLine = NSMutableAttributedString()
            fullLine.append(lineA)
            fullLine.append(muAttrString)
            fullLine.append(lineB)
            
            let width: CGFloat? = layoutManager.wordWrap ? layoutRects.textRegionWidth - layoutRects.textEdgeInsets.right : nil
            
            timer.stopAndGo(message:"3")
            let ctLines = layoutManager.makeFakeCTLines(from: fullLine, width: width)
            
            timer.stopAndGo(message:"4")
            for (i, fakeCTLine) in ctLines.enumerated() {
                let fakeLine = KFakeLine(ctLine: fakeCTLine, hardLineIndex: hardLineIndex, softLineIndex: i, layoutManager: layoutManager, textStorageRef: textStorageRef)
                
                _fakeLines.append(fakeLine)
            }
        }
        timer.stop()
        
        
        _replaceLineCount = lines(hardLineIndex: _replaceLineNumber).count
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
    

    
    //func rebuildLines(range: Range<Int>? = nil, insertedCount: Int? = nil) {
    func rebuildLines(with info: KStorageModifiedInfo? = nil){
        
       //log("start. time = \(Date())", from:self)
        /*if let info = info {
            log("info: \(info)",from:self)
        }*/
        
       
        guard let layoutManagerRef = _layoutManager else { log("layoutManagerRef is nil", from:self); return }
        guard let textStorageRef = _textStorageRef else { log("textStorageRef is nil", from:self); return }
       
        // storageが空だった場合、空行を1つ追加する。
        if textStorageRef.count == 0 {
            _lines.removeAll()
            _lines.append(layoutManagerRef.makeEmptyLine(index: 0, hardLineIndex: 0))
            return
        }
        
        
         var currentIndex = 0
         var currentLineNumber = 0
        
        //range, insertedCountが設定されている場合の影響範囲を導出する。
        
        //if let range = info.range, let insertedCount = info.insertedCount {
        if let info = info {
            let range = info.range
            let insertedCount = info.insertedCount
            log("range: \(range), insertedCount: \(insertedCount)",from:self)
            // すでにstorageは編集されており、編集されたテキストの内容を知ることはできない。
            // rangeは編集前のstorageからカットされた領域、insertedCountはそこに挿入された文字列の長さ。
            // rangeのlowerとupperのそれぞれについて含まれる行を確定し、それらを結合することで影響範囲とする。
            // 現状のstorageのrange.lowerBound..<range.lowerBound + insertedCount が挿入された文字列の領域。
            // insertedCount - range.count が編集された部位より後のシフト量。
            
            // まずは簡易に、入力された範囲より前の行については温存し、それ以降の行を作り直すことにする。
            var currentHardLineIndex = 0
            for (i, line) in _lines.enumerated() {
                if line.softLineIndex == 0 {
                    currentHardLineIndex = i
                }
                
                if line.range.upperBound + 1 > range.lowerBound {
                    currentIndex = line.range.lowerBound
                    _lines.removeSubrange(currentHardLineIndex..<_lines.count)
                    _lines.forEach { $0.removeCTLine() }
                    currentLineNumber = line.hardLineIndex
                    break
                }
            }
            
        } else {
            _lines.removeAll()
         }
        
        
        
        guard let layoutRects = layoutManagerRef.makeLayoutRects() else { log("layoutRects is nil", from:self); return }
        
        
        let characters = textStorageRef.characterSlice
        let newLine = "\n" as Character
        
        while currentIndex < characters.count {
            var lineEndIndex = currentIndex

            // 改行まで進める（改行文字は含めない）
            //while lineEndIndex < characters.count && characters[lineEndIndex] != "\n" {
            while lineEndIndex < characters.count && characters[lineEndIndex] != newLine {
                lineEndIndex += 1
            }

            let lineRange = currentIndex..<lineEndIndex
            
            guard let lineArray = layoutManagerRef.makeLines(range: lineRange, hardLineIndex: currentLineNumber, width: layoutRects.textRegionWidth - layoutRects.textEdgeInsets.right) else { print("\(#function) - lineArray is nil"); return }
            
            _lines.append(contentsOf: lineArray)

            currentIndex = lineEndIndex
            currentLineNumber += 1
            
            
            //if currentIndex < characters.count && characters[currentIndex] == "\n" {
            if currentIndex < characters.count && characters[currentIndex] == newLine {
                currentIndex += 1 // 改行をスキップ
            }
            
        }
        
        //最後の文字が改行だった場合、空行を1つ追加する。
        if textStorageRef.characterSlice.last == "\n" {
            _lines.append(layoutManagerRef.makeEmptyLine(index: textStorageRef.count, hardLineIndex: currentLineNumber))
        }
        
        // for testing
        log("is valid: \(isValid)",from:self)
        
        
        // _linesに格納されているKLineのうち、softLineIndexが0の行のhardLineIndexと、その行の_lines上のindexをMapしておく。
        _hardLineIndexMap.removeAll()
        var currentHardLineIndex: Int = -1
        for (i, line) in _lines.enumerated() {
            if line.hardLineIndex == currentHardLineIndex + 1 {
                currentHardLineIndex += 1
                _hardLineIndexMap[currentHardLineIndex] = i
            }
        }
        //log("_hardLineIndexMap: \(_hardLineIndexMap)",from:self)
                
    }
    
    
    
    // ハード行の行番号hardLineIndexの行を取り出す。ソフトラップの場合は複数行になることがある。
    func lines(hardLineIndex: Int) -> [KLine] {
        guard let startIndex = _hardLineIndexMap[hardLineIndex] else {
            log("_hardLineIndexMap[\(hardLineIndex)] not found",from:self)
            return []
        }
        var lines:[KLine] = []
        for i in startIndex..<_lines.count {
            let line = _lines[i]
            if line.hardLineIndex == hardLineIndex {
                lines.append(line)
            } else {
                break
            }
        }
        return lines
        //let timer = KTimeChecker(name:"KLines.lines()")
        /*
        var lines: [KLine] = []
        for line in _lines {
            if line.hardLineIndex == hardLineIndex {
                lines.append(line)
            } else if line.hardLineIndex > hardLineIndex {
                break
            }
        }
        //timer.stop()

        return lines*/
    }
    
    // ハード行の番号iの行のRangeを得る。行末の改行は含まない。
    func hardLineRange(hardLineIndex: Int) -> Range<Int>? {
        let lines = lines(hardLineIndex: hardLineIndex)
        guard !lines.isEmpty else { return nil }
        
        return lines.first!.range.lowerBound..<lines.last!.range.upperBound
    }
    
    // index文字目の文字を含む行を返す。ソフト・ハードを問わない。
    func lineContainsCharacter(index: Int) -> KLine? {
        guard let textStorageRef = _textStorageRef else {
            log("\(#function): textStorageRef is nil",from:self)
            return nil
        }

        let count = textStorageRef.count
        guard count > 0 else { return _lines.first }
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
                return line
            } else if index < range.lowerBound {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        log("no match for index \(index)", from: self)
        return nil
    }
    /*
    func lineContainsCaharacter(index: Int) -> KLine? {
        
        guard let textStorageRef = _textStorageRef else { print("\(#function): textstorageref==nil"); return nil }
        
        let count = textStorageRef.count
        
        // 空行のみの場合は1行目の空行を返す。
        guard count > 0 else { return _lines.first }
        
        //log("index:\(index), count:\(count)", from: self)
        guard index >= 0 && index <= count else { log("out of range.", from: self); return nil }
        
        for line in _lines {
            //print("\(#function) hardLineIndex:\(line.hardLineIndex), index:\(index)")
            let range = line.range.lowerBound..<line.range.upperBound + 1
            if range.contains(index) {
                //print("\(#function) contains = true")
                return line
            }
        }
        log("out of range.", from: self)
        return nil
    }*/
    
    // hardLineIndex番目の行が_linesのどのindexか返す。
    /*
    func lineArrayIndex(for hardLineIndex: Int) -> Int? {
        for (i, line) in _lines.enumerated() {
            if line.hardLineIndex == hardLineIndex {
                return i
            }
        }
        return nil
    }*/
    func lineArrayIndex(for hardLineIndex: Int) -> Int? {
        _hardLineIndexMap[hardLineIndex]
    }
    
    
    
    
}
