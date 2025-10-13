//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//  Ruby syntax parser with inline tokenizer & incremental outline.
//  Keeps original features: %r/%Q/%q/%w/%W/%i/%I/%s/%S/%x/%X, heredoc, regex,
//  keyword highlighting via KSkeletonStringInUTF8.matchesKeyword, outline, completion.
//
//  Created by KARINO Masatsugu, consolidated 2025-10.
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {
    
    // MARK: - 内部構造体・状態
    
    private struct _OutlineSpan {
        let start: Int
        var end: Int?
        var item: KOutlineItem
        var parentIndex: Int?
    }
    
    private struct LineInfo {
        var endState: EndState = .neutral
        var spans: [KAttributedSpan] = []
        var dirty: Bool = true
    }
    
    // 行末継続状態（文字列/ヒアドキュメント/%リテラル/正規表現）
    private indirect enum EndState: Equatable {
        case neutral
        case inMultiComment
        case inStringSingle
        case inStringDouble
        case inPercentLiteral(closing: UInt8)
        case inInterpolation(ret: EndState, depth: Int, outerClosing: UInt8) // 予約
        case inHereDoc(term: [UInt8], allowIndent: Bool, interpolation: Bool)
        case inRegexSlash
    }
    
    // MARK: - プロパティ
    
    private var _outlineSpans: [_OutlineSpan] = []
    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []
    private var _needsRebuild = true
    private var _completionLexicon: [Data] = []
    private var _tmpSpans: [KAttributedSpan] = []
    
    private let _enableStringInterpolationColoring = false // 現状オフ（将来ON対応）
    
    // 配色（前回指定踏襲）
    private let _colorBase     = NSColor.black
    private let _colorString   = NSColor(hexString: "#860300") ?? .black
    private let _colorComment  = NSColor(hexString: "#0B5A00") ?? .black
    private let _colorKeyword  = NSColor(hexString: "#070093") ?? .black
    private let _colorNumber   = NSColor(hexString: "#070093") ?? .black
    private let _colorVariable = NSColor(hexString: "#7A4E00") ?? .black
    
    // キーワード（KSkeletonString.matchesKeyword で判定するため長さ別に保持）
    private static let _kw2: [[UInt8]] = [Array("do".utf8), Array("in".utf8), Array("or".utf8), Array("if".utf8)]
    private static let _kw3: [[UInt8]] = [Array("end".utf8), Array("and".utf8), Array("for".utf8), Array("def".utf8), Array("nil".utf8), Array("not".utf8)]
    private static let _kw4: [[UInt8]] = [Array("then".utf8), Array("true".utf8), Array("next".utf8), Array("redo".utf8), Array("case".utf8), Array("else".utf8), Array("self".utf8), Array("when".utf8), Array("retry".utf8)]
    private static let _kw5: [[UInt8]] = [Array("class".utf8), Array("false".utf8), Array("yield".utf8), Array("until".utf8), Array("super".utf8), Array("while".utf8), Array("break".utf8), Array("alias".utf8), Array("begin".utf8), Array("undef".utf8), Array("elsif".utf8)]
    private static let _kw6: [[UInt8]] = [Array("module".utf8), Array("ensure".utf8), Array("unless".utf8), Array("return".utf8), Array("rescue".utf8)]
    private static let _kw7: [[UInt8]] = [Array("defined?".utf8)]
    
    // 直後が /regex/ になりやすい導入語（slash 直前の単語）
    private let _regexLeaderWords: Set<String> = [
        "if","elsif","while","until","when","case","then","and","or","not","return"
    ]
    
    // ストレージ（必須：プロトコル）
    let storage: KTextStorageReadable
    init(storage: KTextStorageReadable) { self.storage = storage }
    
    // コメント接頭辞・基本色（プロトコル）
    var lineCommentPrefix: String? { "#" }
    var baseTextColor: NSColor { _colorBase }
    
    // MARK: - プロトコル：基本IF
    
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        // 行開始テーブルが壊れるため再構築フラグ
        _needsRebuild = true
    }
    
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
    
    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
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
        
        var result: [KAttributedSpan] = []
        result.reserveCapacity(32)
        
        for li in li0...li1 {
            for span in _lines[li].spans {
                if span.range.upperBound <= range.lowerBound { continue }
                if span.range.lowerBound >= range.upperBound { break }
                let a = max(span.range.lowerBound, range.lowerBound)
                let b = min(span.range.upperBound, range.upperBound)
                if a < b {
                    result.append(KAttributedSpan(range: a..<b, attributes: span.attributes))
                }
            }
        }
        return result
    }
    
    // MARK: - 行テーブル再構築
    
    private func rebuildIfNeeded() {
        guard _needsRebuild else { return }
        _needsRebuild = false
        
        // KSkeleton を信頼：lineStartIndices は [0] + LF+1
        _lineStarts = storage.skeletonString.lineStartIndices
        let n = max(0, _lineStarts.count - 1)
        _lines = Array(repeating: LineInfo(), count: n)
        
        // 初回は全域パース（anchorは0）
        parseLines(in: 0..<n)
    }
    
    private func lineIndex(at offset: Int) -> Int {
        // _lineStarts は “各行の先頭”。indexを含む行＝最大の start ≤ offset
        var lo = 0, hi = max(0, _lineStarts.count - 1)
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if _lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
    
    private func lineRangeCovering(_ charRange: Range<Int>, pad: Int) -> Range<Int> {
        let n = max(0, _lineStarts.count - 1)
        guard n > 0 else { return 0..<0 }
        let lo = lineIndex(at: charRange.lowerBound)
        let hi = lineIndex(at: max(charRange.upperBound - 1, 0))
        let lo2 = max(0, lo - pad)
        let hi2 = min(n, hi + 1 + pad)
        return lo2..<hi2
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
    
    // MARK: - 行パース
    
    private func parseLines(in rangeCandidates: Range<Int>) {
        let lineCount = max(0, _lineStarts.count - 1)
        if _lines.count != lineCount {
            _lines = Array(repeating: LineInfo(), count: lineCount)
        }
        if lineCount == 0 { return }
        
        // 範囲をクランプ
        let lo = max(0, min(rangeCandidates.lowerBound, lineCount))
        let hi = max(lo, min(rangeCandidates.upperBound, lineCount))
        if lo >= hi { return }
        
        let skel = storage.skeletonString
        var state: EndState = (lo > 0) ? _lines[lo - 1].endState : .neutral
        
        skel.bytes.withUnsafeBufferPointer { whole in
            let baseAll = whole.baseAddress!
            
            for li in lo..<hi {
                if !_lines[li].dirty && _lines[li].endState == state {
                    state = _lines[li].endState
                    continue
                }
                
                let startOff = _lineStarts[li]
                let endOff   = _lineStarts[li + 1]
                let count    = endOff - startOff
                let linePtr  = baseAll + startOff
                
                let (newState, spans) = lexLine(base: linePtr, count: count, startOffset: startOff, initial: state)
                _lines[li].endState = newState
                _lines[li].spans    = spans
                _lines[li].dirty    = false
                state               = newState
            }
        }
    }
    
    // MARK: - 1行字句解析（本体）
    
    private func lexLine(base: UnsafePointer<UInt8>, count: Int, startOffset: Int, initial: EndState)
    -> (EndState, [KAttributedSpan]) {
        _tmpSpans.removeAll(keepingCapacity: true)
        let skel = storage.skeletonString
        var state = initial
        var i = 0
        let n = count
        
        // --- 継続状態の前処理 ---
        if state == .inMultiComment {
            if matchLineHead(base, n, token: "=end") {
                appendSpan(startOffset, 0, n, _colorComment)
                return (.neutral, _tmpSpans)
            } else {
                appendSpan(startOffset, 0, n, _colorComment)
                return (.inMultiComment, _tmpSpans)
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
            case .closed(let end):
                appendSpan(startOffset, 0, end, _colorString); i = end; state = .neutral
            case .eof(let end):
                appendSpan(startOffset, 0, end, _colorString); return (.inPercentLiteral(closing: closing), _tmpSpans)
            case .interp:
                return (.inPercentLiteral(closing: closing), _tmpSpans)
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
        
        // --- 通常走査 ---
        while i < n {
            let c = base[i]
            
            // 行コメント #
            if c == FuncChar.numeric {
                appendSpan(startOffset, i, n, _colorComment)
                break
            }
            
            // '...' / "..."
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
            
            // heredoc ヘッダ
            if c == FuncChar.lt, i + 1 < n, base[i + 1] == FuncChar.lt {
                let (ok, _, term, allowIndent, interp) = parseHereDocHead(base, n, from: i)
                if ok {
                    appendSpan(startOffset, i, n, _colorString)
                    return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interp), _tmpSpans)
                }
            }
            
            // % 系リテラル
            if c == FuncChar.percent, i + 2 < n {
                let t = base[i + 1]                                 // 種別
                let tl = (t >= 0x41 && t <= 0x5A) ? (t &+ 0x20) : t // 小文字化
                let delim = base[i + 2]
                let isRegex = (tl == 0x72) // 'r'
                let isStringLike = (tl == 0x71 || tl == 0x77 || tl == 0x69 || tl == 0x73 || tl == 0x78) // q,w,i,s,x
                
                if isRegex || isStringLike {
                    let (_, close) = pairedDelims(for: delim)
                    let closing: UInt8 = (close == 0) ? delim : close
                    let startBody = i + 3
                    let r = scanUntilOrInterp(base, n, from: startBody, closing: closing)
                    switch r {
                    case .closed(let end): appendSpan(startOffset, i, end, _colorString); i = end; continue
                    case .eof(let end):    appendSpan(startOffset, i, end, _colorString); return (.inPercentLiteral(closing: closing), _tmpSpans)
                    case .interp:          return (.inPercentLiteral(closing: closing), _tmpSpans)
                    }
                }
            }
            
            // /regex/
            if c == FuncChar.slash,
               isRegexLikelyAfterSlash(base, n, at: i, skel: skel, docStartOffset: startOffset) {
                let r = scanRegexSlash(base, n, from: i)
                appendSpan(startOffset, i, r.closedTo, _colorString)
                i = r.closedTo
                if r.closed { continue } else { return (.inRegexSlash, _tmpSpans) }
            }
            
            // 変数
            if c == FuncChar.dollar {
                let end = scanGlobalVar(base, n, from: i)
                appendSpan(startOffset, i, end, _colorVariable)
                i = end; continue
            }
            if c == FuncChar.at {
                let end = scanAtVar(base, n, from: i)
                if end > i { appendSpan(startOffset, i, end, _colorVariable); i = end; continue }
            }
            
            // "::" はスキップ
            if c == FuncChar.colon, i + 1 < n, base[i + 1] == FuncChar.colon { i += 2; continue }
            
            // :symbol / :"..." / :'...'
            if c == FuncChar.colon {
                let end = scanSymbolLiteral(base, n, from: i)
                if end > i { appendSpan(startOffset, i, end, _colorString); i = end; continue }
            }
            
            // 数値
            if c == FuncChar.minus || isDigit(c) {
                let end = scanNumber(base, n, from: i)
                appendSpan(startOffset, i, end, _colorNumber)
                i = end; continue
            }
            
            // 識別子/キーワード
            if isIdentStart(c) {
                let end = scanIdentEnd(base, n, from: i)
                if isKeywordToken(base, n, start: i, end: end, skel: skel, docStartOffset: startOffset) {
                    appendSpan(startOffset, i, end, _colorKeyword)
                }
                i = end; continue
            }
            
            i += 1
        }
        
        return (state, _tmpSpans)
    }
    
    // MARK: - キーワード判定（KSkeletonStringInUTF8 を利用）
    
    private func isKeywordToken(_ base: UnsafePointer<UInt8>, _ n: Int,
                                start: Int, end: Int,
                                skel: KSkeletonStringInUTF8, docStartOffset: Int) -> Bool {
        if end < n && !isDelimiter(base[end]) { return false }
        let len = end - start
        if len < 2 || len > 7 { return false }
        let pos = docStartOffset + start
        switch len {
        case 2:  for w in Self._kw2 { if skel.matchesKeyword(at: pos, word: w) { return true } }
        case 3:  for w in Self._kw3 { if skel.matchesKeyword(at: pos, word: w) { return true } }
        case 4:  for w in Self._kw4 { if skel.matchesKeyword(at: pos, word: w) { return true } }
        case 5:  for w in Self._kw5 { if skel.matchesKeyword(at: pos, word: w) { return true } }
        case 6:  for w in Self._kw6 { if skel.matchesKeyword(at: pos, word: w) { return true } }
        case 7:  for w in Self._kw7 { if skel.matchesKeyword(at: pos, word: w) { return true } }
        default: break
        }
        return false
    }
    
    // MARK: - 補助（区切り・識別子・数値）
    
    private func isDelimiter(_ c: UInt8) -> Bool {
        if c == FuncChar.space || c == FuncChar.tab { return true }
        switch c {
        case FuncChar.lf, FuncChar.cr,
            FuncChar.leftParen, FuncChar.rightParen,
            FuncChar.leftBracket, FuncChar.rightBracket,
            FuncChar.leftBrace, FuncChar.rightBrace,
            FuncChar.comma, FuncChar.period, FuncChar.colon, FuncChar.semicolon,
            FuncChar.plus, FuncChar.minus, FuncChar.asterisk, FuncChar.slash,
            FuncChar.equals, FuncChar.pipe, FuncChar.caret, FuncChar.ampersand,
            FuncChar.exclamation, FuncChar.question, FuncChar.lt, FuncChar.gt:
            return true
        default: return false
        }
    }
    
    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    
    private func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore
    }
    
    private func isIdentPart(_ c: UInt8) -> Bool {
        isIdentStart(c) || isDigit(c) || c == FuncChar.question || c == FuncChar.exclamation
    }
    
    // MARK: - スキャナ群
    
    private enum ScanRI { case closed(Int), interp, eof(Int) } // interpは将来用
    
    private func matchLineHead(_ base: UnsafePointer<UInt8>, _ n: Int, token: String) -> Bool {
        if n == 0 { return false }
        let u = Array(token.utf8)
        if n < u.count { return false }
        for k in 0..<u.count where base[k] != u[k] { return false }
        return true
    }
    
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
    
    private struct RegexScanResult { let closed: Bool; let closedTo: Int }
    
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
                    // フラグ（i,m,x,o,n,e,u,s,d…）をざっくり許容
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
    
    private func pairedDelims(for c: UInt8) -> (UInt8, UInt8) {
        switch c {
        case FuncChar.leftParen:   return (FuncChar.leftParen,   FuncChar.rightParen)
        case FuncChar.leftBracket: return (FuncChar.leftBracket, FuncChar.rightBracket)
        case FuncChar.leftBrace:   return (FuncChar.leftBrace,   FuncChar.rightBrace)
        case FuncChar.lt:          return (FuncChar.lt,          FuncChar.gt)
        default: return (0, 0) // 同一文字で閉じる
        }
    }
    
    private func matchHereDocTerm(_ base: UnsafePointer<UInt8>, _ n: Int, term: [UInt8], allowIndent: Bool) -> Int {
        var e = n
        if e > 0, base[e - 1] == FuncChar.lf { e -= 1 }
        if e > 0, base[e - 1] == FuncChar.cr { e -= 1 }
        
        var i = 0
        if allowIndent {
            while i < e, (base[i] == FuncChar.space || base[i] == FuncChar.tab) { i += 1 }
        }
        if i + term.count > e { return -1 }
        for k in 0..<term.count { if base[i + k] != term[k] { return -1 } }
        
        var p = i + term.count
        while p < e, (base[p] == FuncChar.space || base[p] == FuncChar.tab) { p += 1 }
        if p < e, base[p] == FuncChar.numeric { return e }
        if p < e, base[p] == FuncChar.semicolon { return e }
        return (p == e) ? e : -1
    }
    
    private func parseHereDocHead(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int)
    -> (Bool, Int, [UInt8], Bool, Bool) {
        var i = from
        guard i + 1 < n, base[i] == FuncChar.lt, base[i + 1] == FuncChar.lt else {
            return (false, i, [], false, false)
        }
        i += 2
        
        var allowIndent = false
        if i < n, (base[i] == FuncChar.minus || base[i] == FuncChar.tilde) { allowIndent = true; i += 1 }
        
        while i < n, (base[i] == FuncChar.space || base[i] == FuncChar.tab) { i += 1 }
        if i >= n { return (false, from, [], false, false) }
        
        let c0 = base[i]
        let isQuoted = (c0 == FuncChar.singleQuote || c0 == FuncChar.doubleQuote)
        let isIdent0 = (c0 >= 0x41 && c0 <= 0x5A) || (c0 >= 0x61 && c0 <= 0x7A) || c0 == FuncChar.underscore
        if !(isIdent0 || isQuoted) { return (false, from, [], false, false) }
        
        var interpolation = true
        var term: [UInt8] = []
        
        if isQuoted {
            let q = base[i]; interpolation = (q == FuncChar.doubleQuote); i += 1
            let s = i
            while i < n, base[i] != q { i += 1 }
            if i >= n { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + s, count: i - s))
            i += 1
            if !isIdentWord(term) { return (false, from, [], false, false) }
        } else {
            let s = i
            while i < n {
                let c = base[i]
                let isAZ09_ = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
                (c >= 0x30 && c <= 0x39) || c == FuncChar.underscore
                if !isAZ09_ { break }
                i += 1
            }
            if i == s { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + s, count: i - s))
            
            var hasUpper = false, allUpper = true
            for b in term {
                if b >= 0x41 && b <= 0x5A { hasUpper = true }
                if !((b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == FuncChar.underscore) {
                    allUpper = false; break
                }
            }
            if !(hasUpper && allUpper) { return (false, from, [], false, false) }
        }
        
        var j = i
        while j < n, (base[j] == FuncChar.space || base[j] == FuncChar.tab) { j += 1 }
        var e = n
        if e > 0, base[e - 1] == FuncChar.lf { e -= 1 }
        if e > 0, base[e - 1] == FuncChar.cr { e -= 1 }
        if j >= e { return (true, i, term, allowIndent, interpolation) }
        if base[j] == FuncChar.numeric || base[j] == FuncChar.semicolon {
            return (true, i, term, allowIndent, interpolation)
        }
        return (false, from, [], false, false)
    }
    
    private func isIdentWord(_ bs: [UInt8]) -> Bool {
        guard let f = bs.first else { return false }
        let isHead = (f >= 0x41 && f <= 0x5A) || (f >= 0x61 && f <= 0x7A) || f == FuncChar.underscore
        if !isHead { return false }
        for b in bs.dropFirst() {
            let ok = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) ||
            (b >= 0x30 && b <= 0x39) || b == FuncChar.underscore
            if !ok { return false }
        }
        return true
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
            var j = i + 1
            while j < n, isIdentPart(base[j]) { j += 1 }
            return j
        }
        return from
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
    
    // MARK: - /regex/ 文脈推定
    
    private func isRegexLikelyAfterSlash(_ base: UnsafePointer<UInt8>, _ n: Int,
                                         at i: Int,
                                         skel: KSkeletonStringInUTF8,
                                         docStartOffset: Int) -> Bool {
        var j = i - 1
        while j >= 0, (base[j] == FuncChar.space || base[j] == FuncChar.tab) { j -= 1 }
        if j < 0 { return true }
        
        switch base[j] {
        case FuncChar.equals, FuncChar.plus, FuncChar.asterisk, FuncChar.percent,
            FuncChar.caret, FuncChar.pipe, FuncChar.ampersand, FuncChar.minus,
            FuncChar.exclamation, FuncChar.question, FuncChar.colon, FuncChar.semicolon,
            FuncChar.comma, FuncChar.leftParen, FuncChar.leftBracket, FuncChar.leftBrace,
            FuncChar.lt, FuncChar.gt:
            return true
        default: break
        }
        
        if isIdentPart(base[j]) {
            var k = j
            while k >= 0, isIdentPart(base[k]) { k -= 1 }
            let start = k + 1
            let len   = j - start + 1
            if len <= 0 { return false }
            let pos = docStartOffset + start
            switch len {
            case 2:
                return skel.matchesKeyword(at: pos, word: [0x69,0x66]) /*if*/ ||
                skel.matchesKeyword(at: pos, word: [0x6F,0x72]) /*or*/
            case 3:
                return skel.matchesKeyword(at: pos, word: [0x61,0x6E,0x64]) /*and*/ ||
                skel.matchesKeyword(at: pos, word: [0x6E,0x6F,0x74]) /*not*/
            case 4:
                return skel.matchesKeyword(at: pos, word: [0x74,0x68,0x65,0x6E]) /*then*/ ||
                skel.matchesKeyword(at: pos, word: [0x77,0x68,0x65,0x6E]) /*when*/ ||
                skel.matchesKeyword(at: pos, word: [0x63,0x61,0x73,0x65]) /*case*/
            case 5:
                return skel.matchesKeyword(at: pos, word: [0x77,0x68,0x69,0x6C,0x65]) /*while*/ ||
                skel.matchesKeyword(at: pos, word: [0x75,0x6E,0x74,0x69,0x6C]) /*until*/ ||
                skel.matchesKeyword(at: pos, word: [0x65,0x6C,0x73,0x69,0x66]) /*elsif*/
            case 6:
                return skel.matchesKeyword(at: pos, word: [0x72,0x65,0x74,0x75,0x72,0x6E]) /*return*/
            default:
                return false
            }
        }
        
        if base[j] == FuncChar.rightParen || base[j] == FuncChar.rightBracket || base[j] == FuncChar.rightBrace { return false }
        if isDigit(base[j]) { return false }
        return true
    }

    // MARK: - wordRange（旧版の仕様を維持）

    func wordRange(at index: Int) -> Range<Int>? {
        let n = storage.count
        if n == 0 { return nil }

        var i = max(0, min(index, n - 1))
        let skel = storage.skeletonString

        return skel.bytes.withUnsafeBufferPointer { whole -> Range<Int>? in
            let base = whole.baseAddress!

            @inline(__always) func at(_ p: Int) -> UInt8 { base[p] }
            @inline(__always) func inBounds(_ p: Int) -> Bool { p >= 0 && p < n }

            func isWordish(_ c: UInt8) -> Bool {
                return c == FuncChar.dollar || c == FuncChar.at || c == FuncChar.colon ||
                       c == FuncChar.minus || (c >= 0x41 && c <= 0x5A) ||
                       (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == FuncChar.underscore
            }
            func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
            func isIdentStart(_ c: UInt8) -> Bool {
                (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore
            }
            func isIdentPart(_ c: UInt8) -> Bool {
                isIdentStart(c) || isDigit(c) || c == FuncChar.question || c == FuncChar.exclamation
            }

            if !isWordish(at(i)) && i > 0 && isWordish(at(i - 1)) { i -= 1 }
            if !isWordish(at(i)) { return nil }

            // "::" は演算子だけ選択
            if at(i) == FuncChar.colon || (i > 0 && at(i - 1) == FuncChar.colon) {
                let firstColon = (at(i) == FuncChar.colon && i > 0 && at(i - 1) == FuncChar.colon) ? (i - 1) : i
                if firstColon + 1 < n, at(firstColon) == FuncChar.colon, at(firstColon + 1) == FuncChar.colon {
                    return firstColon ..< (firstColon + 2)
                }
            }

            func expandIdentifier(from pivot: Int) -> (lo: Int, hi: Int) {
                var lo = pivot, hi = pivot
                if !isIdentPart(at(pivot)) && inBounds(pivot + 1) && isIdentPart(at(pivot + 1)) {
                    lo = pivot + 1; hi = lo
                }
                while inBounds(lo - 1), isIdentPart(at(lo - 1)) { lo -= 1 }
                while inBounds(hi), isIdentPart(at(hi)) { hi += 1 }
                if inBounds(hi), (at(hi) == FuncChar.question || at(hi) == FuncChar.exclamation) { hi += 1 }
                return (lo, hi)
            }

            // 数値（-含む）
            func expandNumber(from pivot: Int) -> (lo: Int, hi: Int)? {
                var lo = pivot, hi = pivot
                if !isDigit(at(pivot)) {
                    if inBounds(pivot + 1), isDigit(at(pivot + 1)) {
                        lo = pivot + 1; hi = lo
                    } else if at(pivot) == FuncChar.minus, inBounds(pivot + 1), isDigit(at(pivot + 1)) {
                        lo = pivot; hi = pivot + 1
                    } else { return nil }
                }
                while inBounds(lo - 1), isDigit(at(lo - 1)) { lo -= 1 }
                if inBounds(lo - 1),
                   at(lo - 1) == FuncChar.minus,
                   !(inBounds(lo - 2) && (isDigit(at(lo - 2)) || isIdentPart(at(lo - 2)))) {
                    lo -= 1
                }
                while inBounds(hi) {
                    let c = at(hi)
                    if isDigit(c) || c == FuncChar.period ||
                       (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
                        hi += 1
                    } else { break }
                }
                return (lo, hi)
            }
            if let nr = expandNumber(from: i) { return nr.lo..<nr.hi }

            // 識別子（@/@@/$ 前置や :symbol 対称性を維持）
            if isIdentPart(at(i)) || isIdentStart(at(i)) {
                var (lo, hi) = expandIdentifier(from: i)
                if lo >= 2, at(lo - 2) == FuncChar.at, at(lo - 1) == FuncChar.at { lo -= 2 }
                else if lo >= 1, at(lo - 1) == FuncChar.at { lo -= 1 }
                else if lo >= 1, at(lo - 1) == FuncChar.dollar { lo -= 1 }
                if lo >= 1, at(lo - 1) == FuncChar.colon,
                   !(lo >= 2 && at(lo - 2) == FuncChar.colon) {
                    lo -= 1
                }
                return lo..<hi
            }

            return nil
        }
    }

    // MARK: - アウトライン（class/module/def）

    func outline(in range: Range<Int>? = nil) -> [KOutlineItem] {
        rebuildIfNeeded()
        _buildOutlineAll()
        guard let r = range else { return _outlineSpans.map { $0.item } }
        return _outlineSpans.compactMap {
            let a = $0.item.nameRange.lowerBound
            let b = $0.item.nameRange.upperBound
            return (b <= r.lowerBound || a >= r.upperBound) ? nil : $0.item
        }
    }

    func currentContext(at index: Int) -> [KOutlineItem] {
        rebuildIfNeeded()
        _buildOutlineAll()

        var bestIdx: Int? = nil
        for (i, sp) in _outlineSpans.enumerated() {
            let e = sp.end ?? Int.max
            if sp.start <= index && index < e {
                if let b = bestIdx {
                    let bS = _outlineSpans[b].start
                    let bE = _outlineSpans[b].end ?? Int.max
                    let deeper = (sp.start >= bS) && (e <= bE)
                    if deeper { bestIdx = i }
                } else {
                    bestIdx = i
                }
            }
        }
        guard let leaf = bestIdx else { return [] }

        var chain: [KOutlineItem] = []
        var cur: Int? = leaf
        while let i = cur {
            chain.append(_outlineSpans[i].item)
            cur = _outlineSpans[i].parentIndex
        }
        return chain.reversed()
    }

    private func _buildOutlineAll() {
        _outlineSpans.removeAll(keepingCapacity: true)
        let nLines = max(0, _lineStarts.count - 1)
        if nLines == 0 { return }

        let skel = storage.skeletonString
        skel.bytes.withUnsafeBufferPointer { whole in
            let base = whole.baseAddress!

            struct Frame {
                let kind: KOutlineItem.Kind
                let spanIndex: Int
                let parent: Int?
            }

            var stack: [Frame] = []

            for li in 0..<nLines {
                let lo = _lineStarts[li]
                let hi = _lineStarts[li + 1]
                let len = hi - lo
                if len <= 0 { continue }

                let line = base + lo

                // 行頭の空白スキップ
                var i = 0
                while i < len, (line[i] == FuncChar.space || line[i] == FuncChar.tab) { i += 1 }
                if i >= len { continue }

                // 行コメントは無視
                if line[i] == FuncChar.numeric { continue }

                // =begin/=end はアウトラインの対象外
                if matchLineHead(line + i, len - i, token: "=begin") { continue }
                if matchLineHead(line + i, len - i, token: "=end") {
                    _ = stack.popLast()
                    continue
                }

                // class/module/def の簡易検出
                if i + 3 <= len, matchLineHead(line + i, len - i, token: "def") {
                    let name = extractName(line + i + 3, len - (i + 3), baseOffset: lo + i + 3)
                    let item = KOutlineItem(kind: .method, name: name.text, containerPath: [],
                                            nameRange: name.range, headerRange: lo..<hi,
                                            bodyRange: nil, lineIndex: li, level: stack.count,
                                            isSingleton: false)
                    let idx = _outlineSpans.count
                    _outlineSpans.append(_OutlineSpan(start: lo + i, end: nil, item: item, parentIndex: stack.last?.spanIndex))
                    stack.append(Frame(kind: .method, spanIndex: idx, parent: stack.last?.spanIndex))
                    continue
                }

                if i + 5 <= len, matchLineHead(line + i, len - i, token: "class") {
                    let name = extractName(line + i + 5, len - (i + 5), baseOffset: lo + i + 5)
                    let item = KOutlineItem(kind: .class, name: name.text, containerPath: [],
                                            nameRange: name.range, headerRange: lo..<hi,
                                            bodyRange: nil, lineIndex: li, level: stack.count,
                                            isSingleton: false)
                    let idx = _outlineSpans.count
                    _outlineSpans.append(_OutlineSpan(start: lo + i, end: nil, item: item, parentIndex: stack.last?.spanIndex))
                    stack.append(Frame(kind: .class, spanIndex: idx, parent: stack.last?.spanIndex))
                    continue
                }

                if i + 6 <= len, matchLineHead(line + i, len - i, token: "module") {
                    let name = extractName(line + i + 6, len - (i + 6), baseOffset: lo + i + 6)
                    let item = KOutlineItem(kind: .module, name: name.text, containerPath: [],
                                            nameRange: name.range, headerRange: lo..<hi,
                                            bodyRange: nil, lineIndex: li, level: stack.count,
                                            isSingleton: false)
                    let idx = _outlineSpans.count
                    _outlineSpans.append(_OutlineSpan(start: lo + i, end: nil, item: item, parentIndex: stack.last?.spanIndex))
                    stack.append(Frame(kind: .module, spanIndex: idx, parent: stack.last?.spanIndex))
                    continue
                }

                // "end" による閉じ
                if i + 3 <= len, matchLineHead(line + i, len - i, token: "end") {
                    if let top = stack.popLast() {
                        // ここで bodyRange を確定して詰め替え（必要なら）
                        // 簡易実装のため bodyRange は未設定のままでもOK
                        _outlineSpans[top.spanIndex].end = lo + i
                    }
                    continue
                }
            }
        }
    }

    // 行内の “名前” を簡易抽出して表示名とRangeを返す
    private func extractName(_ line: UnsafePointer<UInt8>, _ len: Int, baseOffset: Int)
    -> (text: String, range: Range<Int>) {
        var i = 0
        while i < len, (line[i] == FuncChar.space || line[i] == FuncChar.tab) { i += 1 }
        let start = i
        while i < len, !isDelimiter(line[i]) { i += 1 }
        let s = String(decoding: UnsafeBufferPointer(start: line + start, count: i - start), as: UTF8.self)
        return (s, baseOffset + start ..< baseOffset + i)
    }

    // MARK: - Completion（語彙スナップショット）

    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?) {
        let bytes = storage.skeletonString.bytes
        let unique = _scanRubyIdentifiers(from: bytes)
        _completionLexicon = unique.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry] {
        guard !prefix.isEmpty, let prefixData = prefix.data(using: .utf8) else { return [] }
        let lower = _lowerBound(in: _completionLexicon, forPrefix: prefixData)
        let upper = _upperBound(in: _completionLexicon, forPrefix: prefixData)
        if upper <= lower { return [] }

        var results: [KCompletionEntry] = []
        results.reserveCapacity(min(limit, upper - lower))

        var i = lower
        var emitted = 0
        while i < upper && emitted < limit {
            let d = _completionLexicon[i]
            if d != prefixData, let s = String(data: d, encoding: .utf8) {
                results.append(KCompletionEntry(text: s, kind: .keyword, detail: nil, score: 0))
                emitted += 1
            }
            i += 1
        }
        return results
    }

    private func _scanRubyIdentifiers(from bytes: [UInt8]) -> Set<Data> {
        var out = Set<Data>()
        var i = 0
        let n = bytes.count
        @inline(__always) func isHead(_ b: UInt8) -> Bool {
            b == 0x40 || b == 0x24 || b == 0x5F ||
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        @inline(__always) func isBody(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || b == 0x5F ||
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        while i < n {
            let b = bytes[i]
            if isHead(b) {
                let s = i; i += 1
                while i < n, isBody(bytes[i]) { i += 1 }
                if i < n, (bytes[i] == 0x21 || bytes[i] == 0x3F) { i += 1 } // !?
                out.insert(Data(bytes[s..<i]))
            } else {
                i += 1
            }
        }
        return out
    }

    private func _lowerBound(in haystack: [Data], forPrefix prefix: Data) -> Int {
        var lo = 0, hi = haystack.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if haystack[mid].lexicographicallyPrecedes(prefix) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func _upperBound(in haystack: [Data], forPrefix prefix: Data) -> Int {
        var lo = 0, hi = haystack.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if prefix.lexicographicallyPrecedes(haystack[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    // MARK: - スパン追加ヘルパ

    private func appendSpan(_ baseOff: Int, _ lo: Int, _ hi: Int, _ color: NSColor) {
        if lo < hi {
            _tmpSpans.append(KAttributedSpan(range: baseOff + lo ..< baseOff + hi,
                                             attributes: [.foregroundColor: color]))
        }
    }
}
