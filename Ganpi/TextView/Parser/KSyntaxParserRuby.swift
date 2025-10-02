//
//  KSyntaxParserRuby.swift
//  Ganpi
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {
    
    // 1行分の結果キャッシュ
    private struct LineInfo {
        var endState: EndState = .neutral
        var spans: [AttributedSpan] = []
        var dirty: Bool = true
    }
    
    // 行末での継続状態
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
    
    // #{...} の中身カラーリングは安定版では無効
    private let _enableStringInterpolationColoring = false
    
    // 行先頭オフセット一覧（最後にテキスト末尾も入れる）
    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []
    private var _needsRebuild = true
    
    // 配色（前回踏襲）＋変数用の茶色
    private let _colorString   = NSColor(hexString: "#860300") ?? .black
    private let _colorComment  = NSColor(hexString: "#0B5A00") ?? .black
    private let _colorKeyword  = NSColor(hexString: "#070093") ?? .black
    private let _colorNumber   = NSColor(hexString: "#070093") ?? .black
    private let _colorVariable = NSColor(hexString: "#7A4E00") ?? .black
    
    // Rubyキーワード
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
    
    // 作業用
    private var _tmpSpans: [AttributedSpan] = []
    
    // ストレージ
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
    
    // MARK: - 字句解析本体

    private func lexLine(base: UnsafePointer<UInt8>, count: Int, startOffset: Int, initial: EndState) -> (EndState, [AttributedSpan]) {
        _tmpSpans.removeAll(keepingCapacity: true)

        var state = initial
        var i = 0
        let n = count

        // --- 継続状態の処理 ---
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

        // --- 通常走査 ---
        while i < n {
            let c = base[i]

            // 行コメント #
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

            // ヒアドキュメント開始（<<[-~]? の直後の空白は許可／識別子orクォート以外は不採用）
            if c == FuncChar.lt, i + 1 < n, base[i + 1] == FuncChar.lt {
                let (ok, nextI, term, allowIndent, interp) = parseHereDocHead(base, n, from: i)
                if ok {
                    // ヘッダ行も赤で塗る（検出が一目で分かる）
                    appendSpan(startOffset, i, n, _colorString)
                    return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interp), _tmpSpans)
                }
            }

            // %系リテラル（%r は正規表現、その他は文字列系として同色）
            if c == FuncChar.percent, i + 2 < n {
                let t = base[i + 1]                      // 種別文字
                let tl = (t >= 0x41 && t <= 0x5A) ? t + 0x20 : t  // 小文字化
                let delim = base[i + 2]

                // 許可される %種別
                let isRegex = (tl == 0x72) // 'r'
                let isStringLike =
                    (tl == 0x71 /*q*/ || tl == 0x77 /*w*/ || tl == 0x69 /*i*/ ||
                     tl == 0x73 /*s*/ || tl == 0x78 /*x*/ || tl == 0x71 /*q*/ )

                // 上の isStringLike は 'Q','W','I','S','X' も含む（tl化で対応）
                if isRegex || isStringLike {
                    let (_, close) = pairedDelims(for: delim)
                    // 括弧類は対になる終端、その他は同一文字で閉じる
                    let closing: UInt8 = (close == 0) ? delim : close
                    let start = i + 3

                    if isRegex {
                        // %r は既存と同様に「文字列色」で強調
                        let r = scanUntilOrInterp(base, n, from: start, closing: closing)
                        switch r {
                        case .closed(let end):
                            appendSpan(startOffset, i, end, _colorString)
                            i = end
                            continue
                        case .eof(let end):
                            appendSpan(startOffset, i, end, _colorString)
                            return (.inPercentLiteral(closing: closing), _tmpSpans)
                        case .interp:
                            return (.inPercentLiteral(closing: closing), _tmpSpans)
                        }
                    } else {
                        // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X は「文字列系」として同色にする
                        let r = scanUntilOrInterp(base, n, from: start, closing: closing)
                        switch r {
                        case .closed(let end):
                            appendSpan(startOffset, i, end, _colorString)
                            i = end
                            continue
                        case .eof(let end):
                            appendSpan(startOffset, i, end, _colorString)
                            return (.inPercentLiteral(closing: closing), _tmpSpans)
                        case .interp:
                            // 現行は補間の中身カラー復帰は無効化しているため、そのまま継続状態へ
                            return (.inPercentLiteral(closing: closing), _tmpSpans)
                        }
                    }
                }
            }

            // /.../ regex（除算と区別）
            if c == FuncChar.slash, isRegexLikelyAfterSlash(base, n, at: i, startOfLine: (i == 0)) {
                let r = scanRegexSlash(base, n, from: i)
                appendSpan(startOffset, i, r.closedTo, _colorString)
                i = r.closedTo
                if r.closed { continue } else { return (.inRegexSlash, _tmpSpans) }
            }

            // 変数系（茶色）
            if c == FuncChar.dollar {
                let end = scanGlobalVar(base, n, from: i)
                appendSpan(startOffset, i, end, _colorVariable)
                i = end; continue
            }
            if c == FuncChar.at {
                let end = scanAtVar(base, n, from: i)
                if end > i { appendSpan(startOffset, i, end, _colorVariable); i = end; continue }
            }

            // :: はスコープ演算子なのでスキップ（:symbol 誤認防止）
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

    // スパン追加
    private func appendSpan(_ baseOff: Int, _ lo: Int, _ hi: Int, _ color: NSColor) {
        if lo < hi {
            _tmpSpans.append(AttributedSpan(range: baseOff + lo ..< baseOff + hi,
                                            attributes: [.foregroundColor: color]))
        }
    }

    // 行頭での "=begin" / "=end" 判定（完全一致）
    private func matchLineHead(_ base: UnsafePointer<UInt8>, _ n: Int, token: String) -> Bool {
        if n == 0 { return false }
        let u = Array(token.utf8)
        if n < u.count { return false }
        for k in 0..<u.count where base[k] != u[k] { return false }
        return true
    }

    // 任意デリミタまで（%r などの内部用）
    private enum ScanRI { case closed(Int), interp(Int), eof(Int) }

    // 文字列（式展開なし）
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

    // --- heredoc ヘッダ解析 ---
    // 仕様: <<[-~]? の直後の空白は許可。
    //   ・クォート付き: 内容が [A-Za-z_][A-Za-z0-9_]* のときだけ採用
    //   ・裸の終端語:   ^[A-Z][A-Z0-9_]*$ のときだけ採用
    // 終端語の後は 空白/タブ/';'/ '#…' のみ許容（それ以外が来たら演算子 <<）
    private func parseHereDocHead(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int)
    -> (Bool, Int, [UInt8], Bool, Bool) {
        var i = from
        guard i + 1 < n, base[i] == FuncChar.lt, base[i + 1] == FuncChar.lt else {
            return (false, i, [], false, false)
        }
        i += 2

        var allowIndent = false
        if i < n, (base[i] == FuncChar.minus || base[i] == FuncChar.tilde) {
            allowIndent = true; i += 1
        }

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

            // ★ クォート付きは識別子っぽい単語だけ許可（"<li>" 等を排除）
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

            // ★ 裸は ALL UPPER のスネークのみ採用
            var hasUpper = false, allUpper = true
            for b in term {
                if b >= 0x41 && b <= 0x5A { hasUpper = true }
                if !((b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == FuncChar.underscore) {
                    allUpper = false; break
                }
            }
            if !(hasUpper && allUpper) { return (false, from, [], false, false) }
        }

        // 終端語の後ろチェック
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

    // ヒアドキュメント終端判定（末尾の改行 \n / \r\n を無視。空白・;・#コメント許容）
    private func matchHereDocTerm(_ base: UnsafePointer<UInt8>, _ n: Int, term: [UInt8], allowIndent: Bool) -> Int {
        // 実効行末（末尾の \n / \r\n を除外）
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
        // 空白許容
        while p < e, (base[p] == FuncChar.space || base[p] == FuncChar.tab) { p += 1 }
        // コメント開始ならOK（#の後ろに何があっても終端扱い）
        if p < e, base[p] == FuncChar.numeric { return e }
        // セミコロンも許容
        if p < e, base[p] == FuncChar.semicolon { return e }
        // 何もなければ実効行末のみOK
        return (p == e) ? e : -1
    }

    // $グローバル等
    private func scanGlobalVar(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from + 1
        if i >= n { return from + 1 }
        let c = base[i]

        if c == FuncChar.minus { // $-K
            if i + 1 < n { i += 2; return i }
            return i + 1
        }
        if c >= 0x30 && c <= 0x39 { // $1, $10...
            i += 1
            while i < n, (base[i] >= 0x30 && base[i] <= 0x39) { i += 1 }
            return i
        }
        if isIdentStart(c) { // $stdout, $KCODE...
            i += 1
            while i < n, isIdentPart(base[i]) { i += 1 }
            return i
        }
        // 記号1文字の特殊 ($~, $!, $? など)
        return i + 1
    }

    // @ / @@ 変数
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

    // :symbol / :"..." / :'...'
    private func scanSymbolLiteral(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        guard base[i] == FuncChar.colon else { return from }
        i += 1
        if i >= n { return from + 1 }

        let c = base[i]
        if c == FuncChar.singleQuote || c == FuncChar.doubleQuote {
            let quote = c
            let (closed, end) = scanQuotedNoInterp(base, n, from: i, quote: quote)
            return closed ? end : n
        } else if isIdentStart(c) {
            var j = i + 1
            while j < n, isIdentPart(base[j]) { j += 1 }
            return j
        }
        return from
    }

    // 文字クラス
    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore
    }

    private func isIdentPart(_ c: UInt8) -> Bool {
        isIdentStart(c) || isDigit(c) || c == FuncChar.question || c == FuncChar.exclamation
    }

    // 数値（-や小数点もざっくり許容）
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

    // --- /.../ regex サポート ---

    // 直前トークンから “ここは/でregexが来やすい文脈か” を推定
    private func isRegexLikelyAfterSlash(_ base: UnsafePointer<UInt8>, _ n: Int, at i: Int, startOfLine: Bool) -> Bool {
        var j = i - 1
        while j >= 0, (base[j] == FuncChar.space || base[j] == FuncChar.tab) { j -= 1 }
        if j < 0 { return true } // 行頭なら regex の可能性が高い

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

        // 直前が識別子 → 単語を取り出して導入語なら regex
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

    // /.../ の本体スキャン（[...] 内の / は終端にしない。エスケープ対応）
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
    
    // 補助関数（private関数群のところへ追加）
    // クォート付き終端語の中身が [A-Za-z_][A-Za-z0-9_]* かどうか
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
}
