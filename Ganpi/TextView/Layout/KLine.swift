//
//  KLine.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
// 表示される行1行を表すクラス。ソフトラップの場合はハードラップの行が複数に分割されて見た目のままの行配列になる。

import Cocoa

class KLine: CustomStringConvertible {
    fileprivate weak var _layoutManager: KLayoutManager?
    fileprivate weak var _textStorageRef: KTextStorageReadable?
    fileprivate var _cachedOffsets: [CGFloat] = [0.0]
    private var _widthAndOffsetsFixed: Bool = false
    
    var range: Range<Int>
    var hardLineIndex: Int
    let softLineIndex: Int
    let wordWrapOffset: CGFloat
    
    // CTLineを返す。
    var ctLine: CTLine? {
        return makeCTLine()
    }
    
    // 行の幅をCGFloatで返す。
    var width: CGFloat {
        return characterOffsets.last ?? 0.0
    }
    
    
    var description: String {
        return "KLine - range:\(range), HLI:\(hardLineIndex), SLI:\(softLineIndex)"
    }
    
    
    init(range: Range<Int>, hardLineIndex: Int, softLineIndex: Int, wordWrapOffset: CGFloat, layoutManager: KLayoutManager, textStorageRef: KTextStorageReadable){
        self.range = range
        self.hardLineIndex = hardLineIndex
        self.softLineIndex = softLineIndex
        self.wordWrapOffset = wordWrapOffset
        self._layoutManager = layoutManager
        self._textStorageRef = textStorageRef
        
    }
    
    @inline(__always)
    func shiftRange(by delta:Int){
        range = (range.lowerBound + delta)..<(range.upperBound + delta)
    }
    
    @inline(__always)
    func shiftHardLineIndex(by delta:Int){
        hardLineIndex += delta
    }
    
    @inline(__always)
    var characterOffsets:[CGFloat] {
        if !_widthAndOffsetsFixed {
            
            _ = makeCTLine(withoutColors: true)
        }
        return _cachedOffsets
    }
    
    @inline(__always)
    func characterOffset(at index:Int) -> CGFloat {
        if index < 0 || index >= characterOffsets.count {
            log("index(\(index)) out of range.",from:self)
            return wordWrapOffset
        }
        return characterOffsets[index] + wordWrapOffset
    }
    
    
    // この行における左端を0.0としたx座標がpositionである文字のインデックス(左端0)を返す。
    // relativeX: 行左端=0基準のクリックX
    @inline(__always)
    func characterIndex(for relativeX: CGFloat) -> Int {
        // offetが0未満であれば先頭の文字。
        let relativeX = relativeX - wordWrapOffset
        if relativeX < 0 { return 0 }
        
        // 空行（edges==[0] 想定）
        guard characterOffsets.count >= 2 else { return 0 }

        let n = characterOffsets.count - 1 // 文字数
        let x = max(0, relativeX)

        // 端点ケア
        if x <= characterOffsets[0] { return 0 }
        if x >= characterOffsets[n] { return n }

        // 区間 [lo, lo+1) を二分探索で特定（edges[lo] <= x < edges[lo+1]）
        var lower = 0, upper = n
        while lower + 1 < upper {
            let mid = (lower + upper) >> 1
            if x < characterOffsets[mid] { upper = mid } else { lower = mid }
        }

        // 左75%なら lo、その右25%なら lo+1
        let left = characterOffsets[lower], right = characterOffsets[lower + 1]
        let threshold = left + (right - left) * 0.67
        return (x < threshold) ? lower : (lower + 1)
    }
    
    // KTextView.draw()から利用される描画メソッド
    func draw(at point: CGPoint, in bounds: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let ctLine = self.ctLine else { return }
        guard let textStorageRef = _textStorageRef else { log("_textStorageRef is nil.", from: self); return }
        guard let layoutManager = _layoutManager else { log("_layoutManager is nil.", from: self); return }
        
        
        func _alignToDevicePixel(_ yFromTop: CGFloat) -> CGFloat {
            // ウインドウが無いケースもあるので 1.0 をフォールバック
            let scale = NSApp.mainWindow?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1.0
            return (yFromTop * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        
        // ← ここを CTFontGetAscent(baseFont) ではなく、CTLine の実測に
        var asc: CGFloat = 0, des: CGFloat = 0, lead: CGFloat = 0
        _ = CTLineGetTypographicBounds(ctLine, &asc, &des, &lead)
        
        // 空行ガード：CTLine が実質空（asc/des ≒ 0）のときはベースフォントで補う
        if asc == 0 && des == 0 {
            let font = textStorageRef.baseFont
            asc = CTFontGetAscent(font)
            des = CTFontGetDescent(font)
        }
        
        // 後述の「ピクセル合わせ」を噛ませたベースライン
        let baselineFromTop = point.y + asc
        let baselineAligned = _alignToDevicePixel(baselineFromTop)
        
        let lineOriginY = bounds.height - baselineAligned
        //context.textPosition = CGPoint(x: point.x, y: lineOriginY)
        context.textPosition = CGPoint(x: point.x + wordWrapOffset, y: lineOriginY)
        
        CTLineDraw(ctLine, context)
        
        
        // 不可視文字を表示。
        if layoutManager.showInvisibleCharacters {
            let newlineChar:Character = "\n"
            var index = 0
            for i in range.lowerBound..<range.upperBound {
                guard let char = textStorageRef[i] else { log("textStorageRef[\(i)] is nil."); return }
                
                if let ctLine = textStorageRef.invisibleCharacters?.ctLine(for: char) {
                    // 1) その文字の実アドバンス幅（レイアウト済み値）を取得
                    let x0 = _cachedOffsets[index]
                    let x1: CGFloat = (index + 1 < _cachedOffsets.count) ? _cachedOffsets[index + 1] : x0
                    let advance = max(x1 - x0, 0)
                    
                    // 2) 代替CTLineのタイポ幅を取得
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    let placeholderWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
                    
                    // 3) 箱の中央に置く（advance が小さい場合は左寄せにフォールバック）
                    let dx = max((advance - placeholderWidth) * 0.5, 0)
                    
                    //context.textPosition = CGPoint(x: point.x + x0 + dx, y: lineOriginY)
                    context.textPosition = CGPoint(x: point.x + x0 + dx + wordWrapOffset, y: lineOriginY)
                    CTLineDraw(ctLine, context)
                }
                index += 1
            }
            // 改行文字を表示
            if range.upperBound < textStorageRef.count, textStorageRef[range.upperBound] == newlineChar {
                if let newlineCTChar = textStorageRef.invisibleCharacters?.ctLine(for: newlineChar) {
                    //context.textPosition = CGPoint(x: point.x + _cachedOffsets.last!, y: lineOriginY)
                    context.textPosition = CGPoint(x: point.x + _cachedOffsets.last! + wordWrapOffset, y: lineOriginY)
                    CTLineDraw(newlineCTChar, context)
                }
            }
        }
        
        context.restoreGState()
    }
    
    // この行のCTLineを作成する。
    // 作成時にCTLineから文字のoffsetを取得して格納する。
    private func makeCTLine(withoutColors:Bool = false) -> CTLine? {
        
        //guard !range.isEmpty else { return }
        guard let textStorageRef = _textStorageRef else {
            log("textStorageRef is nil.", from: self)
            return nil
        }
        
        guard let layoutManager = _layoutManager else {
            log("layoutManager is nil.", from: self)
            return nil
        }

        guard let attrString = textStorageRef.attributedString(for: range, tabWidth: layoutManager.tabWidth, withoutColors:withoutColors) else {
            log("attrString is nil.", from: self)
            return nil
        }

        let ctLine = CTLineCreateWithAttributedString(attrString)
        
        // CTLineから文字のoffsetを算出してcacheを入れ替える。
        if !_widthAndOffsetsFixed {
            // 1) UTF-16 境界ごとの x を用意（runs 一括で O(n) ）
            let ns = (attrString.string as NSString)
            let utf16Count = ns.length

            // NaN で初期化して「未設定」を表す
            var u16ToX = Array<CGFloat>(repeating: .nan, count: utf16Count + 1)

            let runs = CTLineGetGlyphRuns(ctLine) as NSArray
            for anyRun in runs {
                let run = anyRun as! CTRun
                let gCount = CTRunGetGlyphCount(run)
                if gCount == 0 { continue }

                // glyph -> UTF-16 string index（先頭位置）
                var stringIndices = Array<CFIndex>(repeating: 0, count: gCount)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

                // glyph の描画位置（x）
                var positions = Array<CGPoint>(repeating: .zero, count: gCount)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

                // 各 glyph 先頭の UTF-16 インデックスに x を割り当てる
                // （合字や結合文字は「先頭コードユニットの x」を採用）
                for g in 0..<gCount {
                    let u16 = max(0, min(Int(stringIndices[g]), utf16Count))
                    u16ToX[u16] = positions[g].x
                }

                // Run 終端の UTF-16 位置も、直前 glyph の x で穴埋めできるようにする
                let rs = CTRunGetStringRange(run)
                let runEnd = Int(rs.location + rs.length)
                if runEnd <= utf16Count, u16ToX[runEnd].isNaN, gCount > 0 {
                    u16ToX[runEnd] = positions[gCount - 1].x
                }
            }

            // 行幅を取得して「末尾の境界」を確定
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            u16ToX[utf16Count] = lineWidth

            // 未設定穴（NaN）を左から前方値で埋める（結合文字など）
            var lastX: CGFloat = 0
            for i in 0...utf16Count {
                if u16ToX[i].isNaN { u16ToX[i] = lastX } else { lastX = u16ToX[i] }
            }

            // 2) UTF-16 → Character 境界へ写像して _cachedOffsets を構築（O(n)）
            let s = attrString.string
            var offsets: [CGFloat] = []
            offsets.reserveCapacity(s.count + 1)

            var u16Pos = 0
            offsets.append(u16ToX[0])     // 先頭境界

            // 各 Character の UTF-16 長を足し込みながら境界 x を拾う
            for ch in s {
                // Character の UTF-16 長（結合文字等も正しくカバー）
                let len = ch.utf16.count
                u16Pos &+= len
                // 範囲防御
                let clamped = (u16Pos <= utf16Count) ? u16Pos : utf16Count
                offsets.append(u16ToX[clamped])
            }

            _cachedOffsets = offsets.isEmpty ? [0.0] : offsets
            _widthAndOffsetsFixed = true
        }
        
        return ctLine
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
    
    
    init(attributedString: NSAttributedString, hardLineIndex: Int, softLineIndex: Int, wordWrapOffset: CGFloat, layoutManager: KLayoutManager, textStorageRef: KTextStorageReadable) {
        _ctLine = CTLineCreateWithAttributedString(attributedString)
        _attributedString = attributedString
        
        super.init(range: 0..<0, hardLineIndex: hardLineIndex, softLineIndex: softLineIndex, wordWrapOffset: wordWrapOffset, layoutManager: layoutManager, textStorageRef: textStorageRef)
        
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
        
        setLinesEmpty()
        
        //rebuildLines() <- これのせいで循環してた。
        
    }
    
    enum KFakeLineKind {
        case im
        case completion
        case temporary // currently no use.
    }
    
    // 外部から特定の行について別のAttributedStringを挿入することができる。
    // hardLineIndex行のinsertionオフセットの部分にattrStringを挿入する形になる。
    func addFakeLine(replacementRange: Range<Int>, attrString: NSAttributedString, kind: KFakeLineKind = .im) {
                
        _fakeLines = []
        guard let textStorageRef = _textStorageRef else { print("\(#function) - textStorageRef is nil"); return }
        guard let layoutManager = _layoutManager else { print("\(#function) - layoutManagerRef is nil"); return }
        
        guard let  hardLineIndex = lineAt(characterIndex: replacementRange.lowerBound)?.hardLineIndex else { print("\(#function) - replacementRange.lowerBound is out of range"); return }
        _replaceLineNumber = hardLineIndex
        
        guard let range = hardLineRange(hardLineIndex: hardLineIndex) else { print("\(#function) - hardLineIndex:\(hardLineIndex) is out of range"); return }
        
        guard let layoutRects = _layoutManager?.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        if let lineA = textStorageRef.attributedString(for: range.lowerBound..<replacementRange.lowerBound, tabWidth: nil, withoutColors: false),
           let lineB = textStorageRef.attributedString(for: replacementRange.upperBound..<range.upperBound, tabWidth: nil, withoutColors: false){
            let muAttrString =  NSMutableAttributedString(attributedString: attrString)
            
            var attributes: [NSAttributedString.Key: Any] = [
                .font: textStorageRef.baseFont
            ]
            switch kind {
            case .im:
                // 挿入された文字列の直前(lineAの最後の文字)の.foregroundColorを挿入された文字全体に適用する。
                if lineA.length > 0, let lastCharColor = lineA.attribute(.foregroundColor, at: lineA.length - 1, effectiveRange: nil) as? NSColor {
                    attributes[.foregroundColor] = lastCharColor
                }
            case .completion:
                // 挿入された文字列をグレーにする。
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            default:
                log("currently no implementation.",from:self)
            }
            muAttrString.addAttributes(attributes, range: NSRange(location: 0, length: muAttrString.length))
            
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
        //guard  i >= 0, i < _lines.count else { log("i(\(i)) is out of range.", from:self); return nil }
        if !hasFakeLine { return _lines[i] }
        
        guard let lineArrayIndex = _replaceLineIndex else { log("_fakeLineIndex = nil.", from:self); return nil}
        guard let replaceLineCount = _replaceLineCount else { log("_fakeLineCount = nil.", from:self); return nil}
        
        
        guard i >= 0 && i < count else { log("i is out of range.", from: self); return nil }
        
        // IM稼働中ではないか、あるいは入力中の行より前の場合にはそのまま返す。
        if !hasFakeLine || i < lineArrayIndex  { /*log("normal.", from:self);*/ return _lines[i] }
        
             
        // 入力中の行の場合は、fake行を返す。
        if lineArrayIndex <= i, i < lineArrayIndex + _fakeLines.count {
            return _fakeLines[i - lineArrayIndex] as KLine?
        }
        
        // 入力中の行より後の場合は、入力中の行の次の行を連続して取得できるようずらす。
        let convertedCount = i - _fakeLines.count + replaceLineCount
        
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
        
        let skeleton = textStorageRef.skeletonString
        
        // storageが空だった場合は空行を追加するのみ。
        if textStorageRef.count == 0 { setLinesEmpty(); return }
        
        var newRange = 0..<textStorageRef.count
        //var startIndex = 0
        var removeRange = 0..<_lines.count
        
        if let info = info {
            /// 削除前の range.lowerBound に属していた KLine を特定
            guard let startSoftLine = lineAt(characterIndex: info.range.lowerBound) else {
                log("startLine not found", from: self)
                return
            }

            /// その行の hardLineIndex を取得
            let startHardLineIndex = startSoftLine.hardLineIndex

            /// KLine 配列上の startIndex を取得
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

            var lower = info.range.lowerBound
            var upper = info.range.lowerBound + info.insertedCount

            // 前方：行頭まで戻る
            while lower > 0 {
                if skeleton.bytes[lower - 1] == FuncChar.lf { break }
                lower -= 1
            }

            // 後方：行末（改行を含めた直後）まで進む
            while upper < skeleton.bytes.count {
                //if characters[upper] == newLineCharacter {
                if skeleton.bytes[upper] == FuncChar.lf {
                    upper += 1 // 改行そのものも範囲に含める
                    break
                }
                upper += 1
            }

            newRange = lower..<upper
            
            DispatchQueue.concurrentPerform(iterations: _lines.count - removeRange.upperBound) { i in
                let line = _lines[removeRange.upperBound + i]
                line.shiftRange(by: info.insertedCount - info.range.count)
                line.shiftHardLineIndex(by: info.insertedNewlineCount - info.deletedNewlineCount)
            }
        }
        

        // その領域の文字列に含まれる行の領域の配列を得る。
        var lineRanges:[Range<Int>] = []
        var start = newRange.lowerBound
        for i in newRange {
            //if characters[i] == newLineCharacter {
            if skeleton.bytes[i] == FuncChar.lf {
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
        
        
        // 並列処理を導入する。15000行のデータで1200ms->460msに短縮。
        guard let newStartLine = lineAt(characterIndex: newRange.lowerBound) else {
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
            }
        }
        
        let newLines = newLinesBuffer.flatMap { $0 }
        _lines.replaceSubrange(removeRange, with: newLines)
                
        guard let newLastLine = _lines.last else {
            log("newLastLine is nil", from: self)
            return
        }

        // 最後の文字が改行で、かつ最後のKLineが末尾に達していなければ空行を追加
        if skeleton.bytes.last == FuncChar.lf && newLastLine.range.upperBound < skeleton.bytes.count {
            let emptyLine = layoutManager.makeEmptyLine(index: skeleton.bytes.count, hardLineIndex: newLastLine.hardLineIndex + 1)
            _lines.append(emptyLine)
        }
        
        //log("isValid: \(isValid)",from:self)

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
        if lines.isEmpty {
            return nil
        }
        
        return lines.first!.range.lowerBound..<lines.last!.range.upperBound
    }
    
    
    
    // index文字目を含む行と_lines上のindexを返す。
    func lineInfo(at characterIndex: Int) -> (line:KLine?, lineIndex:Int) {
        guard let lineIndex = lineIndex(at: characterIndex) else { log("lineIndex is nil.",from:self); return (nil, -1) }
        guard lineIndex >= 0, lineIndex < _lines.count else { log("lineIndex(\(lineIndex) is out of range.",from:self); return (nil, -1) }
        let line = _lines[lineIndex]
        return (line, lineIndex)
    }
 
    // index文字目を含む行の_lines上のindexを返す。
    // ソフト行とソフト行の界面のindexだった場合、indexをlowerBoundとするソフト行を返す。
    func lineIndex(at characterIndex: Int) -> Int? {
        return Self.lineIndex(in: _lines, at: characterIndex)
    }
    
    // 検証用に残してある。
    /*
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
                // test
                if mid > 0, mid < _lines.count - 1, _lines[mid].range.upperBound == index, _lines[mid].range.upperBound == _lines[mid + 1].range.lowerBound {
                    log("mid:\(mid), index:\(index), range:\(_lines[mid].range)",from:self)
                    return mid + 1
                }
                return mid
            } else if index < range.lowerBound {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        log("no match for index \(index)", from: self)
        return nil
    }*/
    
    // index文字目がソフト行同士の界面か否か返す。
    func isBoundaryBetweenSoftwareLines(index: Int) -> Bool {
        guard let textStorage = _textStorageRef else { log("_textStorage is nil.",from:self); return false }
        guard index >= 0, index <= textStorage.count else { log("index is out of range.",from:self); return false }
        
        var low = 0
        var high = _lines.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            let line = _lines[mid]
            let head = line.range.lowerBound
            if head == index, mid > 0, _lines[mid - 1].range.upperBound == index {
                return true
            } else if index < head {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return false
    }
    
    // index文字目の文字を含む行のKLineインスタンスを返す。
    func lineAt(characterIndex: Int) -> KLine? {
        guard let lineIndex = lineIndex(at: characterIndex) else { log("no line contains character at index \(characterIndex)"); return nil }
        //log("lineIndex:\(lineIndex)",from:self)
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
        
        guard let lineIndex = lineIndex(at: characterIndex) else { log("lineIndex not found.", from: self); return .zero}
        
        
        let line = _lines[lineIndex]
        let offset = line.characterOffset(at: characterIndex - line.range.lowerBound)
        let x = layoutRects.textRegion.rect.origin.x + layoutRects.horizontalInsets + offset
        let y = layoutRects.textEdgeInsets.top + CGFloat(lineIndex + 1) * layoutManager.lineHeight
        
        return CGPoint(x: x, y: y)
    }
    
    
    private func setLinesEmpty() {
        guard let layoutManager = _layoutManager else { log("layoutManager not found.", from: self); return }
        
        _lines.removeAll()
        _lines.append(layoutManager.makeEmptyLine(index: 0, hardLineIndex: 0))
        _hardLineIndexMap.removeAll()
        _hardLineIndexMap[0] = 0
    }
    
    //MARK: - Static func.
    // index文字目を含む行の_lines上のindexを返す。
    // ソフト行とソフト行の界面のindexだった場合、indexをlowerBoundとするソフト行を返す。
    // rebuildLines()内でテキストが変更された後に利用されることがあるため、storageにアクセスしてはならない。
    static func lineIndex(in lines: [KLine], at characterIndex: Int) -> Int? {
        guard let characterCount = lines.last?.range.upperBound else {log("last item of _lines is nil.", from: self); return nil }
        guard characterIndex >= 0, characterIndex <= characterCount else { log("characterIndex is out of range.", from: self); return nil }
        if characterIndex == 0 { return 0 }
        if characterIndex == characterCount { return lines.count - 1 }
        if lines.isEmpty { return nil }
        
        var low = 0, high = lines.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            let range = lines[mid].range
            if characterIndex >= range.lowerBound && characterIndex < range.upperBound {
                return mid
            } else if characterIndex == range.upperBound {
                if mid < lines.count - 1, lines[mid + 1].range.lowerBound == characterIndex {
                    return mid + 1
                }
                return mid
            }
            if characterIndex < range.lowerBound {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        log("no match.",from:self)
        return nil
        
    }
}
