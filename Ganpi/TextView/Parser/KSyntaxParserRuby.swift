//
//  KSyntaxParserRuby.swift
//  Ganpi
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {
    
    private struct LineInfo {
        var endState: EndState = .neutral
        var spans: [AttributedSpan] = []
        var dirty: Bool = true
    }
    
    private indirect enum EndState: Equatable {
        case neutral
        case inMultiComment
        case inStringSingle
        case inStringDouble
        case inPercentLiteral(closing: UInt8)
        case inInterpolation(ret: EndState, depth: Int, outerClosing: UInt8)
        case inHereDoc(term: [UInt8], allowIndent: Bool, interpolation: Bool)
        case inRegexSlash
    }
    
    private let _enableStringInterpolationColoring = false
    
    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []
    private var _needsRebuild = true
    
    // colors
    private let _colorString   = NSColor(hexString: "#860300") ?? .black
    private let _colorComment  = NSColor(hexString: "#0B5A00") ?? .black
    private let _colorKeyword  = NSColor(hexString: "#070093") ?? .black
    private let _colorNumber   = NSColor(hexString: "#070093") ?? .black
    private let _colorVariable = NSColor(hexString: "#7A4E00") ?? .black  // 茶色
    
    // keywords
    private let _keywords: Set<String> = [
        "BEGIN","END","alias","and","begin","break","case","class","def","defined?",
        "do","else","elsif","end","ensure","false","for","if","in","module","next",
        "nil","not","or","redo","rescue","retry","return","self","super","then",
        "true","undef","unless","until","when","while","yield"
    ]
    
    // “/regex/” を置きやすい導入語（直前がこの単語なら / を regex 開始とみなす）
    private let _regexLeaderWords: Set<String> = [
        "if","elsif","while","until","when","case","then","and","or","not","return"
    ]
    
    private var _tmpSpans: [AttributedSpan] = []
    
    let storage: KTextStorageReadable
    init(storage: KTextStorageReadable) { self.storage = storage }
    
    func noteEdit(oldRange: Range<Int>, newCount: Int) { _needsRebuild = true }
    
    func ensureUpToDate(for range: Range<Int>) {
        rebuildIfNeeded()
        let need = lineRangeCovering(range, pad: 2)
        let anchor = anchorLine(before: need.lowerBound)
        parseLines(in: anchor..<need.upperBound)
    }
    
    func parse(range: Range<Int>) {
        rebuildIfNeeded()
        let need = lineRangeCovering(range, pad: 0)
        let anchor = anchorLine(before: need.lowerBound)
        parseLines(in: anchor..<need.upperBound)
    }
    
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan] {
        if range.isEmpty { return [] }
        ensureUpToDate(for: range)
        let lineCount = max(0, _lineStarts.count - 1)
        if lineCount == 0 { return [] }
        
        let textCount = storage.count
        let loOff = max(0, min(range.lowerBound, max(0, textCount - 1)))
        let hiProbe = max(0, min(max(range.upperBound - 1, 0), max(0, textCount - 1)))
        
        var li0 = lineIndex(at: loOff)
        var li1 = lineIndex(at: hiProbe)
        li0 = max(0, min(li0, lineCount - 1))
        li1 = max(0, min(li1, lineCount - 1))
        if li0 > li1 { return [] }
        
        var result: [AttributedSpan] = []
        result.reserveCapacity(32)
        
        for li in li0...li1 {
            for span in _lines[li].spans {
                if span.range.upperBound <= range.lowerBound { continue }
                if span.range.lowerBound >= range.upperBound { break }
                let a = max(span.range.lowerBound, range.lowerBound)
                let b = min(span.range.upperBound, range.upperBound)
                if a < b {
                    result.append(AttributedSpan(range: a..<b, attributes: span.attributes))
                }
            }
        }
        return result
    }
    
    func wordRange(at index: Int) -> Range<Int>? { nil }
    
    // MARK: - 行テーブル構築
    
    private func rebuildIfNeeded() {
        guard _needsRebuild else { return }
        _needsRebuild = false
        
        let skel = storage.skeletonString
        let lf = skel.newlineIndices()
        
        _lineStarts.removeAll(keepingCapacity: true)
        _lineStarts.append(0)
        for p in lf { _lineStarts.append(p + 1) }
        if _lineStarts.last! != storage.count { _lineStarts.append(storage.count) }
        
        let n = max(0, _lineStarts.count - 1)
        _lines = Array(repeating: LineInfo(), count: n)
        for i in 0..<n { _lines[i].dirty = true }
        _tmpSpans.reserveCapacity(16)
    }
    
    private func lineRangeCovering(_ charRange: Range<Int>, pad: Int) -> Range<Int> {
        let n = max(0, _lineStarts.count - 1)
        guard n > 0 else { return 0..<0 }
        let lo = lineIndex(at: charRange.lowerBound)
        let hi = lineIndex(at: max(charRange.upperBound - 1, 0))
        let lo2 = max(0, lo - pad)
        let hi2 = min(n, hi + pad)
        return lo2..<hi2
    }
    
    private func lineIndex(at offset: Int) -> Int {
        var lo = 0, hi = max(0, _lineStarts.count - 1)
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if _lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
    
    private func anchorLine(before line: Int) -> Int {
        guard !_lines.isEmpty else { return 0 }
        var i = max(0, min(line, _lines.count - 1))
        i = max(0, i - 1)
        while i > 0 {
            if _lines[i].endState == .neutral && !_lines[i].dirty { return i }
            if _lines[i].endState == .neutral && _lines[i].spans.isEmpty { return i }
            i -= 1
        }
        return 0
    }
    
    private func parseLines(in range: Range<Int>) {
        guard !_lines.isEmpty else { return }
        let skel = storage.skeletonString
        
        var state: EndState = (range.lowerBound > 0) ? _lines[range.lowerBound - 1].endState : .neutral
        
        skel.bytes.withUnsafeBufferPointer { whole in
            let baseAll = whole.baseAddress!
            
            for li in range {
                if !_lines[li].dirty && _lines[li].endState == state {
                    state = _lines[li].endState
                    continue
                }
                
                let lo = _lineStarts[li]
                let hi = _lineStarts[li + 1]
                let count = hi - lo
                let linePtr = baseAll + lo
                
                let (newState, spans) = lexLine(base: linePtr, count: count, startOffset: lo, initial: state)
                _lines[li].endState = newState
                _lines[li].spans = spans
                _lines[li].dirty = false
                state = newState
            }
        }
    }
    // MARK: - 字句解析

    private func lexLine(base: UnsafePointer<UInt8>, count: Int, startOffset: Int, initial: EndState) -> (EndState, [AttributedSpan]) {
        _tmpSpans.removeAll(keepingCapacity: true)

        var state = initial
        var i = 0
        let n = count

        // 継続状態の処理
        if state == .inMultiComment {
            if matchLineHead(base, n, token: "=end") {
                appendSpan(startOffset, 0, n, _colorComment); return (.neutral, _tmpSpans)
            } else {
                appendSpan(startOffset, 0, n, _colorComment); return (.inMultiComment, _tmpSpans)
            }
        }
        if state == .inStringSingle {
            let (closed, end) = scanQuotedNoInterp(base, n, from: 0, quote: FuncChar.singleQuote)
            appendSpan(startOffset, 0, end, _colorString)
            if closed { i = end; state = .neutral } else { return (.inStringSingle, _tmpSpans) }
        }
        if state == .inStringDouble {
            let (closed, end) = scanQuotedNoInterp(base, n, from: 0, quote: FuncChar.doubleQuote)
            appendSpan(startOffset, 0, end, _colorString)
            if closed { i = end; state = .neutral } else { return (.inStringDouble, _tmpSpans) }
        }
        if case let .inPercentLiteral(closing) = state {
            let r = scanUntilOrInterp(base, n, from: 0, closing: closing)
            switch r {
            case .closed(let end): appendSpan(startOffset, 0, end, _colorString); i = end; state = .neutral
            case .eof(let end):    appendSpan(startOffset, 0, end, _colorString); return (.inPercentLiteral(closing: closing), _tmpSpans)
            case .interp:          return (.inPercentLiteral(closing: closing), _tmpSpans)
            }
        }
        if case let .inHereDoc(term, allowIndent, interpolation) = state {
            let endAt = matchHereDocTerm(base, n, term: term, allowIndent: allowIndent)
            if endAt >= 0 { appendSpan(startOffset, 0, endAt, _colorString); i = endAt; state = .neutral }
            else { appendSpan(startOffset, 0, n, _colorString); return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interpolation), _tmpSpans) }
        }
        if state == .inRegexSlash {
            let r = scanRegexSlash(base, n, from: 0)
            appendSpan(startOffset, 0, r.closedTo, _colorString)
            if r.closed { state = .neutral; i = r.closedTo } else { return (.inRegexSlash, _tmpSpans) }
        }

        // "=begin" 行頭
        if matchLineHead(base, n, token: "=begin") {
            appendSpan(startOffset, 0, n, _colorComment)
            return (.inMultiComment, _tmpSpans)
        }

        // 通常走査
        while i < n {
            let c = base[i]

            // # 行コメント
            if c == FuncChar.numeric {
                appendSpan(startOffset, i, n, _colorComment)
                break
            }

            // 文字列
            if c == FuncChar.singleQuote {
                let (closed, end) = scanQuotedNoInterp(base, n, from: i, quote: FuncChar.singleQuote)
                appendSpan(startOffset, i, end, _colorString)
                if closed { i = end } else { return (.inStringSingle, _tmpSpans) }
                continue
            }
            if c == FuncChar.doubleQuote {
                let (closed, end) = scanQuotedNoInterp(base, n, from: i, quote: FuncChar.doubleQuote)
                appendSpan(startOffset, i, end, _colorString)
                if closed { i = end } else { return (.inStringDouble, _tmpSpans) }
                continue
            }

            // heredoc 開始（<<[-~]? の直後に空白は許可しない／演算子 << と衝突回避）
            if c == FuncChar.lt, i + 1 < n, base[i + 1] == FuncChar.lt {
                let (ok, nextI, term, allowIndent, interp) = parseHereDocHead(base, n, from: i)
                if ok { i = nextI; return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interp), _tmpSpans) }
            }

            // %r... regex
            if c == FuncChar.percent, i + 2 < n, (base[i+1] == 0x72 || base[i+1] == 0x52) {
                let delim = base[i+2]
                let (open, close) = pairedDelims(for: delim)
                let closing: UInt8 = (open == 0 && close == 0) ? delim : close
                let r = scanUntilOrInterp(base, n, from: i+3, closing: closing)
                switch r {
                case .closed(let end): appendSpan(startOffset, i, end, _colorString); i = end; continue
                case .eof(let end):    appendSpan(startOffset, i, end, _colorString); return (.inPercentLiteral(closing: closing), _tmpSpans)
                case .interp:          return (.inPercentLiteral(closing: closing), _tmpSpans)
                }
            }

            // /.../ regex（除算と区別）
            if c == FuncChar.slash, isRegexLikelyAfterSlash(base, n, at: i, startOfLine: (i == 0)) {
                let r = scanRegexSlash(base, n, from: i)
                appendSpan(startOffset, i, r.closedTo, _colorString)
                i = r.closedTo
                if r.closed { continue } else { return (.inRegexSlash, _tmpSpans) }
            }

            // 変数（茶色）
            if c == FuncChar.dollar {
                let end = scanGlobalVar(base, n, from: i)
                appendSpan(startOffset, i, end, _colorVariable)
                i = end; continue
            }
            if c == FuncChar.at {
                let end = scanAtVar(base, n, from: i)
                if end > i { appendSpan(startOffset, i, end, _colorVariable); i = end; continue }
            }

            // "::" はスコープ演算子 → :symbol 誤検出を避けるためスキップ
            if c == FuncChar.colon, i + 1 < n, base[i + 1] == FuncChar.colon {
                i += 2; continue
            }

            // :symbol
            if c == FuncChar.colon {
                let end = scanSymbolLiteral(base, n, from: i)
                if end > i { appendSpan(startOffset, i, end, _colorString); i = end; continue }
            }

            // 数値（-1 含む）
            if c == FuncChar.minus || isDigit(c) {
                let end = scanNumber(base, n, from: i)
                appendSpan(startOffset, i, end, _colorNumber)
                i = end; continue
            }

            // 識別子/キーワード
            if isIdentStart(c) {
                let end = scanIdentEnd(base, n, from: i)
                let buf = UnsafeBufferPointer(start: base + i, count: end - i)
                let text = String(decoding: buf, as: UTF8.self)
                let color = _keywords.contains(text) ? _colorKeyword : .black
                appendSpan(startOffset, i, end, color)
                i = end; continue
            }

            i += 1
        }

        return (state, _tmpSpans)
    }

    // MARK: - 補助関数

    private func appendSpan(_ baseOff: Int, _ lo: Int, _ hi: Int, _ color: NSColor) {
        if lo < hi {
            _tmpSpans.append(AttributedSpan(range: baseOff + lo ..< baseOff + hi,
                                            attributes: [.foregroundColor: color]))
        }
    }

    private func matchLineHead(_ base: UnsafePointer<UInt8>, _ n: Int, token: String) -> Bool {
        if n == 0 { return false }
        let u = Array(token.utf8)
        if n < u.count { return false }
        for k in 0..<u.count where base[k] != u[k] { return false }
        return true
    }

    private enum ScanRI { case closed(Int), interp(Int), eof(Int) }

    private func scanQuotedNoInterp(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, quote: UInt8) -> (Bool, Int) {
        var i = from + 1
        while i < n {
            if base[i] == quote {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return (true, i + 1) }
            }
            i += 1
        }
        return (false, n)
    }

    private func scanUntilOrInterp(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, closing: UInt8) -> ScanRI {
        var i = from
        while i < n {
            if base[i] == closing {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .closed(i + 1) }
            }
            i += 1
        }
        return .eof(n)
    }

    // heredoc ヘッダ解析：<<[-~]? の直後に空白を許さない（演算子 << との衝突を避ける）
    private func parseHereDocHead(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int)
    -> (Bool, Int, [UInt8], Bool, Bool) {
        var i = from
        guard i + 1 < n, base[i] == FuncChar.lt, base[i + 1] == FuncChar.lt else {
            return (false, i, [], false, false)
        }
        i += 2
        var allowIndent = false
        if i < n, (base[i] == FuncChar.minus || base[i] == FuncChar.tilde) { allowIndent = true; i += 1 }

        // 空白直後は NG（<< Link を誤検出しない）
        if i >= n { return (false, from, [], false, false) }
        if base[i] == FuncChar.space || base[i] == FuncChar.tab { return (false, from, [], false, false) }

        var interpolation = true
        var term: [UInt8] = []

        if base[i] == FuncChar.singleQuote || base[i] == FuncChar.doubleQuote {
            let q = base[i]; interpolation = (q == FuncChar.doubleQuote); i += 1
            let s = i
            while i < n, base[i] != q { i += 1 }
            if i >= n { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + s, count: i - s))
            i += 1
        } else {
            let s = i
            while i < n {
                let c = base[i]
                let isAZ = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore || (c >= 0x30 && c <= 0x39)
                if !isAZ { break }
                i += 1
            }
            if i == s { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + s, count: i - s))
        }
        return (true, i, term, allowIndent, interpolation)
    }

    private func matchHereDocTerm(_ base: UnsafePointer<UInt8>, _ n: Int, term: [UInt8], allowIndent: Bool) -> Int {
        var i = 0
        if allowIndent {
            while i < n, (base[i] == FuncChar.space || base[i] == FuncChar.tab) { i += 1 }
        }
        if i + term.count > n { return -1 }
        for k in 0..<term.count { if base[i + k] != term[k] { return -1 } }
        var p = i + term.count
        while p < n, (base[p] == FuncChar.space || base[p] == FuncChar.tab) { p += 1 }
        if p == n { return n }
        return -1
    }

    private func scanGlobalVar(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from + 1
        if i >= n { return from + 1 }
        let c = base[i]
        if c == FuncChar.minus {
            if i + 1 < n { i += 2; return i }
            return i + 1
        }
        if c >= 0x30 && c <= 0x39 {
            i += 1
            while i < n, (base[i] >= 0x30 && base[i] <= 0x39) { i += 1 }
            return i
        }
        if isIdentStart(c) {
            i += 1
            while i < n, isIdentPart(base[i]) { i += 1 }
            return i
        }
        return i + 1
    }

    private func scanAtVar(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        if i + 1 < n, base[i] == FuncChar.at, base[i + 1] == FuncChar.at {
            i += 2
            if i < n, isIdentStart(base[i]) {
                i += 1; while i < n, isIdentPart(base[i]) { i += 1 }
                return i
            }
            return from
        } else if base[i] == FuncChar.at {
            i += 1
            if i < n, isIdentStart(base[i]) {
                i += 1; while i < n, isIdentPart(base[i]) { i += 1 }
                return i
            }
            return from
        }
        return from
    }

    private func scanSymbolLiteral(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        guard base[i] == FuncChar.colon else { return from }
        i += 1
        if i >= n { return from + 1 }

        let c = base[i]
        if c == FuncChar.singleQuote || c == FuncChar.doubleQuote {
            let (closed, end) = scanQuotedNoInterp(base, n, from: i, quote: c)
            return closed ? end : n
        } else if isIdentStart(c) {
            var j = i + 1; while j < n, isIdentPart(base[j]) { j += 1 }
            return j
        }
        return from
    }

    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore
    }

    private func isIdentPart(_ c: UInt8) -> Bool {
        isIdentStart(c) || isDigit(c) || c == FuncChar.question || c == FuncChar.exclamation
    }

    private func scanNumber(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        if i < n, base[i] == FuncChar.minus { i += 1 }
        while i < n {
            let c = base[i]
            if !isDigit(c) && c != FuncChar.period &&
               !(c >= 0x61 && c <= 0x7A) && !(c >= 0x41 && c <= 0x5A) { break }
            i += 1
        }
        return i
    }

    private func scanIdentEnd(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        while i < n {
            let c = base[i]
            if !isIdentPart(c) { break }
            i += 1
        }
        return i
    }

    // --- /.../ regex ---

    // 直前トークンから “ここは/でregexが来やすい文脈か” を推定
    private func isRegexLikelyAfterSlash(_ base: UnsafePointer<UInt8>, _ n: Int, at i: Int, startOfLine: Bool) -> Bool {
        var j = i - 1
        // 空白・タブはスキップ
        while j >= 0, (base[j] == FuncChar.space || base[j] == FuncChar.tab) { j -= 1 }
        if j < 0 { return true } // 行頭なら regex の可能性が高い

        // 直前が各種区切り・演算子なら regex の可能性が高い
        switch base[j] {
        case FuncChar.equals, FuncChar.plus, FuncChar.asterisk, FuncChar.percent,
             FuncChar.caret, FuncChar.pipe, FuncChar.ampersand, FuncChar.minus,
             FuncChar.exclamation, FuncChar.question, FuncChar.colon, FuncChar.semicolon,
             FuncChar.comma, FuncChar.leftParen, FuncChar.leftBracket, FuncChar.leftBrace,
             FuncChar.lt, FuncChar.gt:
            return true
        default:
            break
        }

        // 直前が識別子 → 単語をさかのぼって取り出し、導入語なら regex
        if isIdentPart(base[j]) {
            var k = j
            while k >= 0, isIdentPart(base[k]) { k -= 1 }
            let start = k + 1
            let len = j - start + 1
            if len > 0 {
                let word = String(decoding: UnsafeBufferPointer(start: base + start, count: len), as: UTF8.self)
                if _regexLeaderWords.contains(word) { return true }
            }
            return false
        }

        // 右括弧や数字の直後は除算の公算が高い
        if base[j] == FuncChar.rightParen || base[j] == FuncChar.rightBracket || base[j] == FuncChar.rightBrace { return false }
        if isDigit(base[j]) { return false }

        return true
    }

    private struct RegexScanResult { let closed: Bool; let closedTo: Int }

    // /.../ 本体のスキャン（[] 内の / は終端にしない。エスケープ対応）
    private func scanRegexSlash(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> RegexScanResult {
        var i = from + 1
        var inClass = 0
        while i < n {
            let c = base[i]
            if c == FuncChar.leftBracket {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { inClass += 1 }
                i += 1; continue
            }
            if c == FuncChar.rightBracket, inClass > 0 {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { inClass -= 1 }
                i += 1; continue
            }
            if c == FuncChar.slash, inClass == 0 {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 {
                    i += 1
                    // フラグをざっくり許容
                    while i < n {
                        let f = base[i]
                        if (f >= 0x41 && f <= 0x5A) || (f >= 0x61 && f <= 0x7A) { i += 1 } else { break }
                    }
                    return RegexScanResult(closed: true, closedTo: i)
                }
            }
            i += 1
        }
        return RegexScanResult(closed: false, closedTo: n)
    }

    // %r デリミタのペア
    private func pairedDelims(for c: UInt8) -> (UInt8, UInt8) {
        switch c {
        case FuncChar.leftParen:   return (FuncChar.leftParen,   FuncChar.rightParen)
        case FuncChar.leftBracket: return (FuncChar.leftBracket, FuncChar.rightBracket)
        case FuncChar.leftBrace:   return (FuncChar.leftBrace,   FuncChar.rightBrace)
        case FuncChar.lt:          return (FuncChar.lt,          FuncChar.gt)
        default: return (0, 0) // 同一文字で閉じる（%r! ... ! など）
        }
    }
}
