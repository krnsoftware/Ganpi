//
//  KSyntaxParserRuby.swift
//  Ganpi
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {
    // アウトライン用
    private struct _OutlineSpan {
        let start: Int
        let end: Int?
        let item: KOutlineItem
        let parentIndex: Int?   // 親の _spans インデックス
    }

    private var _outlineSpans: [_OutlineSpan] = []
    
    // 1行分の結果キャッシュ
    private struct LineInfo {
        var endState: EndState = .neutral
        var spans: [KAttributedSpan] = []
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
    
    // 文書から抽出した語彙のスナップショット（ソート済み, 重複なし, UTF-8 Data）
    private var _completionLexicon: [Data] = []
    
    // 配色（前回踏襲）＋変数用の茶色
    private let _colorBase     = NSColor.black
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
    private var _tmpSpans: [KAttributedSpan] = []
    
    // コメント用
    var lineCommentPrefix: String? { "#" }
    
    var baseTextColor: NSColor {
        get { _colorBase }
    }
    
    
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
    
    // 置換版 wordRange: "::" は演算子単体で選択、識別子は単体、:symbol は左右対称でコロン込み
    func wordRange(at index: Int) -> Range<Int>? {
        let n = storage.count
        if n == 0 { return nil }

        var i = max(0, min(index, n - 1))
        let skel = storage.skeletonString

        return skel.bytes.withUnsafeBufferPointer { whole -> Range<Int>? in
            let base = whole.baseAddress!

            @inline(__always) func at(_ p: Int) -> UInt8 { base[p] }
            @inline(__always) func inBounds(_ p: Int) -> Bool { p >= 0 && p < n }

            // 非単語上なら1文字左を試す（単語の末尾クリックを救う）
            if !isWordish(at(i)) && i > 0 && isWordish(at(i - 1)) {
                i -= 1
            }
            if !isWordish(at(i)) { return nil }

            // ---- 1) "::"（スコープ演算子）は演算子だけを選択 ----
            if at(i) == FuncChar.colon || (i > 0 && at(i - 1) == FuncChar.colon) {
                // コロンの先頭位置（2個目の ':' 上を押しても先頭に寄せる）
                let firstColon = (at(i) == FuncChar.colon && i > 0 && at(i - 1) == FuncChar.colon) ? (i - 1) : i
                if firstColon + 1 < n, at(firstColon) == FuncChar.colon, at(firstColon + 1) == FuncChar.colon {
                    return firstColon ..< (firstColon + 2) // "::" だけ
                }
                // ここから先は「:symbol」（シンボル）を扱う
            }

            // ユーティリティ: 識別子を前後に拡張（末尾 ? / ! を1個だけ許容）
            func expandIdentifier(from pivot: Int) -> (lo: Int, hi: Int) {
                var lo = pivot, hi = pivot
                // pivot が識別子内部でなければ右へ寄せる
                if !isIdentPart(at(pivot)) && inBounds(pivot + 1) && isIdentPart(at(pivot + 1)) {
                    lo = pivot + 1; hi = lo
                }
                while inBounds(lo - 1), isIdentPart(at(lo - 1)) { lo -= 1 }
                while inBounds(hi), isIdentPart(at(hi)) { hi += 1 }
                if inBounds(hi), (at(hi) == FuncChar.question || at(hi) == FuncChar.exclamation) { hi += 1 }
                return (lo, hi)
            }

            // ---- 2) $グローバル ----
            if at(i) == FuncChar.dollar || (i > 0 && at(i - 1) == FuncChar.dollar) {
                var lo = i
                if at(i) != FuncChar.dollar { // 右側から入ったら $ を取り込む
                    let id = expandIdentifier(from: i); lo = id.lo
                    if lo > 0 && at(lo - 1) == FuncChar.dollar { lo -= 1 }
                }
                if at(lo) != FuncChar.dollar { return nil }
                var hi = lo + 1
                if hi < n {
                    let d = at(hi)
                    if d == FuncChar.minus {
                        hi += (hi + 1 < n) ? 2 : 1
                    } else if d >= 0x30 && d <= 0x39 {
                        hi += 1
                        while hi < n, (at(hi) >= 0x30 && at(hi) <= 0x39) { hi += 1 }
                    } else if isIdentStart(d) {
                        hi += 1
                        while hi < n, isIdentPart(at(hi)) { hi += 1 }
                    } else {
                        hi += 1 // $~, $!, $? など
                    }
                }
                return lo..<hi
            }

            // ---- 3) @ / @@ 変数 ----
            if at(i) == FuncChar.at || (i > 0 && at(i - 1) == FuncChar.at) {
                let id = expandIdentifier(from: i)
                var lo = id.lo, hi = id.hi
                if lo >= 2, at(lo - 2) == FuncChar.at, at(lo - 1) == FuncChar.at { lo -= 2 }
                else if lo >= 1, at(lo - 1) == FuncChar.at { lo -= 1 }
                else if at(i) == FuncChar.at { return nil } // 単独 @ は非単語
                return lo..<hi
            }

            // ---- 4) :symbol（左右対称：内部をクリックしてもコロン込み）----
            // 「::」は前段で返しているので、ここは単独コロンのみ
            if at(i) == FuncChar.colon || (i > 0 && at(i - 1) != FuncChar.colon && at(i - 1) == FuncChar.colon) {
                let colonPos = (at(i) == FuncChar.colon) ? i : (i - 1)
                let lo = colonPos
                var hi = colonPos + 1
                if hi < n {
                    let d = at(hi)
                    if d == FuncChar.singleQuote || d == FuncChar.doubleQuote {
                        let (closed, end) = scanQuotedNoInterp(base, n, from: hi, quote: d)
                        return (closed ? (lo..<end) : (lo..<n))
                    } else if isIdentStart(d) {
                        hi += 1
                        while hi < n, isIdentPart(at(hi)) { hi += 1 }
                        return lo..<hi
                    }
                }
                return nil
            }

            // ---- 5) 数値（- を必要に応じて取り込む）----
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

            // ---- 6) 識別子（内部クリックでも単語全体）。:symbol対称性のため前置コロンを取り込む ----
            if isIdentPart(at(i)) || isIdentStart(at(i)) {
                var (lo, hi) = expandIdentifier(from: i)

                // 前置 @ / @@ / $ は取り込む（: はここでは取り込まない）
                if lo >= 2, at(lo - 2) == FuncChar.at, at(lo - 1) == FuncChar.at { lo -= 2 }
                else if lo >= 1, at(lo - 1) == FuncChar.at { lo -= 1 }
                else if lo >= 1, at(lo - 1) == FuncChar.dollar { lo -= 1 }

                // :symbol の対称性：直前が単独コロンならコロンも含める（'::' は除外）
                if lo >= 1, at(lo - 1) == FuncChar.colon,
                   !(lo >= 2 && at(lo - 2) == FuncChar.colon) {
                    lo -= 1
                }
                return lo..<hi
            }

            return nil
        }
    }

    // 単語に“なり得る”先頭判定（wordRange用の緩い判定）
    private func isWordish(_ c: UInt8) -> Bool {
        return c == FuncChar.dollar || c == FuncChar.at || c == FuncChar.colon ||
               c == FuncChar.minus || isIdentStart(c) || isDigit(c)
    }
    
    // MARK: - 行テーブル構築
    
    private func rebuildIfNeeded() {
        guard _needsRebuild else { return }
        _needsRebuild = false
        
        let skel = storage.skeletonString
        let lf = skel.newlineIndices
        
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

    private func lexLine(base: UnsafePointer<UInt8>, count: Int, startOffset: Int, initial: EndState) -> (EndState, [KAttributedSpan]) {
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
                let (ok, _, term, allowIndent, interp) = parseHereDocHead(base, n, from: i)
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
                //let color = _keywords.contains(text) ? _colorKeyword : .black
                //appendSpan(startOffset, i, end, color)
                if _keywords.contains(text) {
                    appendSpan(startOffset, i, end, _colorKeyword)
                }
                i = end; continue
            }

            i += 1
        }

        return (state, _tmpSpans)
    }

    // MARK: - Outline (class/module/def)

    func outline(in range: Range<Int>? = nil) -> [KOutlineItem] {
        rebuildIfNeeded()
        // まず全文を走査（初版：毎回再構築。性能要望が出たら差分化）
        _buildOutlineAll()

        guard let r = range else {
            return _outlineSpans.compactMap { $0.item }
        }
        var out: [KOutlineItem] = []
        out.reserveCapacity(_outlineSpans.count)
        for sp in _outlineSpans {
            let a = sp.item.nameRange.lowerBound
            let b = sp.item.nameRange.upperBound
            if b <= r.lowerBound || a >= r.upperBound { continue }
            out.append(sp.item)
        }
        return out
    }

    // 置換：未クローズ span（end == nil）も候補に入れる
    func currentContext(at index: Int) -> [KOutlineItem] {
        rebuildIfNeeded()
        _buildOutlineAll()

        // 最も内側のブロック（start ≤ index < end*）を選ぶ
        var bestIdx: Int? = nil
        for (i, sp) in _outlineSpans.enumerated() {
            let e = sp.end ?? Int.max            // ★ 未クローズは「開いたまま」
            if sp.start <= index && index < e {
                if let b = bestIdx {
                    let bS = _outlineSpans[b].start
                    let bE = _outlineSpans[b].end ?? Int.max
                    // より内側＝開始が大きく、終了が小さい方を優先
                    let thisIsDeeper = (sp.start >= bS) && (e <= bE)
                    if thisIsDeeper { bestIdx = i }
                } else {
                    bestIdx = i
                }
            }
        }
        guard let leaf = bestIdx else { return [] }

        // 親を遡って外→内順に返す
        var chain: [KOutlineItem] = []
        var cur: Int? = leaf
        while let i = cur {
            chain.append(_outlineSpans[i].item)
            cur = _outlineSpans[i].parentIndex
        }
        return chain.reversed()
    }
    
    // MARK: - Completion (Ruby)

    /// 動的語彙の内部情報（辞書はパーサ内に閉じ込める）
    private struct DynamicTokenInfo {
        var kind: KCompletionKind
        var firstPos: Int
        var lastPos: Int
        var freq: Int
        var containerPath: [String] // 表示用に使うことがある
    }
    
    /// 文書全体から「今この瞬間に存在する確定語」だけを収集し、ソート済み配列として保持する。
    /// - 仕様: 大小は常に区別。コメント/文字列はスキップ。ヒアドキュメント等の高度な構文は対象外（最小実装）。
    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?) {
        // TextStorage からスナップショット（UTF-8バイト列）を取得
        // 例: let bytes = textStorage.skeletonString.bytes
        let bytes: [UInt8] = storage.skeletonString.bytes

        // 文書から語彙（UTF-8 Data）を抽出（コメント/文字列は除外）
        let unique = _scanRubyIdentifiers(from: bytes)

        // 辞書順（UTF-8バイト列の昇順）に並べる
        let sorted = unique.sorted { $0.lexicographicallyPrecedes($1) }

        // スナップショット差し替え
        _completionLexicon = sorted
    }
    
    /// 収集済みスナップショットから前方一致で候補を返す。大小は常に区別。アルファベット順。
    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry] {
        // policy は現状未使用（仕様により無視）
        _ = policy

        // 空prefixは返さない
        guard !prefix.isEmpty else { return [] }

        // prefix を UTF-8 Data に変換（大小区別, 正規化なし）
        guard let prefixData = prefix.data(using: .utf8), !prefixData.isEmpty else { return [] }

        // ソート済み _completionLexicon から前方一致範囲を二分探索で抽出
        let lower = _lowerBound(in: _completionLexicon, forPrefix: prefixData)
        if lower == _completionLexicon.count { return [] }

        let upper = _upperBound(in: _completionLexicon, forPrefix: prefixData)
        if upper <= lower { return [] }

        var results: [KCompletionEntry] = []
        results.reserveCapacity(min(limit, upper - lower))

        // 返却時に prefix と完全一致は除外（自己エコー防止）
        let maxCount = min(limit, upper - lower)
        var emitted = 0

        var i = lower
        while i < upper && emitted < maxCount {
            let d = _completionLexicon[i]
            if d != prefixData, let s = String(data: d, encoding: .utf8) {
                // kind / detail / score に既定値を与えて生成
                let entry = KCompletionEntry(
                    text: s,
                    kind: .keyword,     // 通常の語彙を表す識別子として扱う
                    detail: nil,           // 詳細情報なし
                    score: 0               // ソート済みなのでスコアリング不要
                )
                results.append(entry)
                emitted += 1
            }
            i += 1
        }

        return results
    }

    // 内部辞書（動的）
    private var _dynamicMap: [String: DynamicTokenInfo] = [:]
    // 最終更新のテキスト長（簡易な変化検知に使う）
    private var _lastScannedLength: Int = -1
    /*

    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?) {
        // 1) アウトライン由来を反映（class/module/method）
        _ingestOutlineToDynamicMap()

        // 2) 本文から識別子・変数っぽいものを軽く拾う（全走査でも高速）
        //    必要なら dirtyRange ±数行に限定する最適化を後で入れる。
        _scanDocumentForDynamicTokens()

        // 3) 更新記録
        _lastScannedLength = storage.count//textLength // textLength は既存の全文長プロパティ想定
    }

    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry]
    {
        // 0) 前処理
        let normalizedPrefix = prefix.lowercased()

        // 1) 固定語彙（prefix一致）
        var entries: [KCompletionEntry] = []
        if normalizedPrefix.isEmpty {
            // 空prefixなら固定語彙は出し過ぎない。必要なら後段で追加。
        } else {
            for kw in _keywords {
                if kw.hasPrefix(normalizedPrefix) {
                    entries.append(KCompletionEntry(text: kw, kind: .keyword, detail: nil, score: 0))
                }
            }
        }

        // 2) 動的語彙（prefix一致）
        for (text, info) in _dynamicMap {
            if normalizedPrefix.isEmpty || text.lowercased().hasPrefix(normalizedPrefix) {
                // 表示 detail：可能なら containerPath と #/. を組み立て
                var detail: String? = nil
                switch info.kind {
                case .methodInstance:
                    if let last = info.containerPath.last { detail = "\(last) · #\(text)" }
                    else { detail = "#\(text)" }
                case .methodClass:
                    if let last = info.containerPath.last { detail = "\(last) · .\(text)" }
                    else { detail = ".\(text)" }
                case .typeClass, .typeModule:
                    detail = text
                case .constant:
                    detail = text
                case .variableLocal, .variableInstance, .variableClass, .variableGlobal, .symbol:
                    detail = text
                case .keyword:
                    detail = text
                }

                entries.append(KCompletionEntry(text: text, kind: info.kind, detail: detail, score: 0))
            }
        }

        // 3) 並べ替え
        switch policy {
        case .alphabetical:
            entries.sort {
                // textのローカライズ比較。textが同じならkindで安定化。
                let lhs = $0.text
                let rhs = $1.text
                let c = lhs.localizedStandardCompare(rhs)
                if c == .orderedSame {
                    return String(describing: $0.kind) < String(describing: $1.kind)
                }
                return c == .orderedAscending
            }

        case .heuristic(let weights):
            // まだ使わない。将来ここに score 合成を入れる。
            entries.sort {
                if $0.score == $1.score {
                    return $0.text.localizedStandardCompare($1.text) == .orderedAscending
                }
                return $0.score > $1.score
            }
        }

        // 4) 重複除去（text単位でユニーク化）
        var seen = Set<String>()
        var unique: [KCompletionEntry] = []
        unique.reserveCapacity(min(entries.count, limit))
        for e in entries {
            if !seen.contains(e.text) {
                unique.append(e); seen.insert(e.text)
                if unique.count >= limit { break }
            }
        }
        //return unique
        return unique.filter { $0.text != prefix }
    }*/

    // MARK: - 動的語彙の取り込み

    private func _ingestOutlineToDynamicMap() {
        // 既存アウトライン（class/module/method）から流用
        // outline はあなたの実装にある前提。全件（または画面周辺）を取り、Mapに入れる。
        let items = outline(in: nil)
        for it in items {
            switch it.kind {
            case .class:
                _dynamicInsert(text: it.name, kind: .typeClass, pos: it.lineIndex, containerPath: it.containerPath)
            case .module:
                _dynamicInsert(text: it.name, kind: .typeModule, pos: it.lineIndex, containerPath: it.containerPath)
            case .method:
                // 表示名 ".foo" / "#foo" を返している想定なので、textは記号を外す
                let raw = it.name.hasPrefix(".") || it.name.hasPrefix("#") ? String(it.name.dropFirst()) : it.name
                let kind: KCompletionKind = it.isSingleton ? .methodClass : .methodInstance
                _dynamicInsert(text: raw, kind: kind, pos: it.lineIndex, containerPath: it.containerPath)
            }
        }
    }

    private func _dynamicInsert(text: String, kind: KCompletionKind, pos: Int, containerPath: [String]) {
        guard !text.isEmpty else { return }
        if var v = _dynamicMap[text] {
            v.freq += 1
            v.lastPos = max(v.lastPos, pos)
            if v.containerPath.isEmpty { v.containerPath = containerPath }
            _dynamicMap[text] = v
        } else {
            _dynamicMap[text] = DynamicTokenInfo(kind: kind, firstPos: pos, lastPos: pos, freq: 1, containerPath: containerPath)
        }
    }

    /// ざっくり本文スキャン：識別子/変数/定数/シンボルを拾う（軽い・安全）
    private func _scanDocumentForDynamicTokens() {
        // すでに同長ならスキップ（ざっくり検知）
        if _lastScannedLength == storage.count { return }

        let bytes = storage.skeletonString.bytes   // 1:1のUInt8配列（あなたの設計どおり）
        let n = bytes.count
        var i = 0
        while i < n {
            let c = bytes[i]

            // コメント行の # 〜 改行 を飛ばす（超簡易）
            if c == FuncChar.numeric { // #
                i += 1
                while i < n, bytes[i] != FuncChar.lf { i += 1 }
                continue
            }

            // @ivar / @@cvar / $gvar
            if c == FuncChar.at {
                let start = i
                var j = i + 1
                if j < n, bytes[j] == FuncChar.at { j += 1 } // @@
                if j < n, isIdentStart(bytes[j]) {
                    j += 1
                    while j < n, isIdentPart(bytes[j]) { j += 1 }
                    let name = String(decoding: bytes[start..<j], as: UTF8.self)
                    let kind: KCompletionKind = (name.hasPrefix("@@") ? .variableClass : .variableInstance)
                    _dynamicInsert(text: name, kind: kind, pos: start, containerPath: [])
                    i = j; continue
                }
            } else if c == FuncChar.dollar {
                let start = i
                var j = i + 1
                if j < n, isIdentStart(bytes[j]) {
                    j += 1
                    while j < n, isIdentPart(bytes[j]) { j += 1 }
                    let name = String(decoding: bytes[start..<j], as: UTF8.self)
                    _dynamicInsert(text: name, kind: .variableGlobal, pos: start, containerPath: [])
                    i = j; continue
                }
            } else if c == FuncChar.colon {
                // :symbol
                let start = i
                var j = i + 1
                if j < n, isIdentStart(bytes[j]) {
                    j += 1
                    while j < n, isIdentPart(bytes[j]) { j += 1 }
                    let sym = String(decoding: bytes[start..<j], as: UTF8.self)
                    _dynamicInsert(text: sym, kind: .symbol, pos: start, containerPath: [])
                    i = j; continue
                }
            } else if isIdentStart(c) {
                // 識別子（ローカル or 定数）
                let start = i
                i += 1
                while i < n, isIdentPart(bytes[i]) { i += 1 }
                let name = String(decoding: bytes[start..<i], as: UTF8.self)
                if let first = name.utf8.first, first >= 0x41 && first <= 0x5A {
                    _dynamicInsert(text: name, kind: .constant, pos: start, containerPath: [])
                } else {
                    _dynamicInsert(text: name, kind: .variableLocal, pos: start, containerPath: [])
                }
                continue
            }

            i += 1
        }
    }
    
    // MARK: - 補助関数

    // スパン追加
    private func appendSpan(_ baseOff: Int, _ lo: Int, _ hi: Int, _ color: NSColor) {
        if lo < hi {
            _tmpSpans.append(KAttributedSpan(range: baseOff + lo ..< baseOff + hi,
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
    
    // 全文スキャンで class/module/def ... end を抽出（簡易・高速版）
    private func _buildOutlineAll() {
        _outlineSpans.removeAll(keepingCapacity: true)

        let nLines = max(0, _lineStarts.count - 1)
        if nLines == 0 { return }

        let skel = storage.skeletonString
        skel.bytes.withUnsafeBufferPointer { whole in
            let base = whole.baseAddress!

            struct Frame {
                let kind: KOutlineItem.Kind
                let name: String
                let container: [String]
                let startOffset: Int      // ヘッダ先頭
                let nameRange: Range<Int>
                let headerEnd: Int        // 行末
                let lineIndex: Int
                let isSingleton: Bool
                let spanIndex: Int        // _outlineSpans での自分の位置
            }

            var containerPath: [String] = []
            var stack: [Frame] = []

            for li in 0..<nLines {
                let lo = _lineStarts[li]
                let hi = _lineStarts[li + 1]
                let count = hi - lo
                if count <= 0 { continue }

                let line = base + lo
                let lineEnd = hi

                // 行頭の空白を飛ばす
                var i = 0
                while i < count, (line[i] == FuncChar.space || line[i] == FuncChar.tab) { i += 1 }
                if i >= count { continue }

                // 行コメントならスキップ
                if line[i] == FuncChar.numeric { continue }

                // "=begin"/"=end" の行はアウトライン対象外だが、end対応が崩れないように無視
                if matchLineHead(line, count, token: "=begin") || matchLineHead(line, count, token: "=end") {
                    continue
                }

                // ヒアドキュメントの開始行（<<...）はアウトライン無視。あくまで def/class 検出優先。
                // ここでは何もしない（字句パーサ側で色分け済なので誤検出は起こりにくい）。

                // --- class / module / def / end の簡易検出（行頭付近のみ） ---
                if i + 5 <= count {
                    // "class" or "module" or "def" or "end"
                    let c0 = line[i]

                    // end
                    if c0 == 0x65 /*e*/, i + 3 <= count,
                       line[i+1] == 0x6E, line[i+2] == 0x64,
                       (i + 3 == count || isDelimiter(line[i+3])) {
                        // pop
                        if let top = stack.popLast() {
                            // bodyRange を確定
                            let endOff = lo + i // 'end' の先頭を end とする
                            if top.spanIndex < _outlineSpans.count {
                                let old = _outlineSpans[top.spanIndex]
                                let item = KOutlineItem(
                                    kind: old.item.kind,
                                    name: old.item.name,
                                    containerPath: old.item.containerPath,
                                    nameRange: old.item.nameRange,
                                    headerRange: old.item.headerRange,
                                    bodyRange: top.headerEnd ..< endOff,
                                    lineIndex: old.item.lineIndex,
                                    level: old.item.level,
                                    isSingleton: old.item.isSingleton
                                )
                                _outlineSpans[top.spanIndex] = _OutlineSpan(start: old.start, end: endOff, item: item, parentIndex: old.parentIndex)
                            }
                            // class/module なら containerPath を戻す
                            if top.kind == .class || top.kind == .module {
                                if !containerPath.isEmpty { _ = containerPath.popLast() }
                            }
                        }
                        continue
                    }

                    // class / module / def
                    // 先頭トークンのみを拾う（識別子が続くか、区切りで終わるか）
                    if c0 == 0x63 /*c*/ || c0 == 0x6D /*m*/ || c0 == 0x64 /*d*/ {
                        // キーワード抽出
                        let kwStart = i
                        var j = i
                        while j < count, isIdentPart(line[j]) { j += 1 }
                        let kwLen = j - kwStart
                        // 続きが区切りでなければキーワードとみなさない
                        if j < count && !isDelimiter(line[j]) { /* 呼び出し等 */ }
                        else if kwLen == 5 && memeq(line+kwStart, "class") {
                            // class Foo::Bar
                            var nameStart = j
                            while nameStart < count, (line[nameStart] == FuncChar.space || line[nameStart] == FuncChar.tab) { nameStart += 1 }
                            let (fullName, lastName, lastNameRange) = parseConstPath(line, count, from: nameStart, baseOffset: lo)
                            let display = fullName
                            let level = containerPath.count
                            let item = KOutlineItem(
                                kind: .class,
                                name: display,
                                containerPath: containerPath,
                                nameRange: lastNameRange,
                                headerRange: lo + kwStart ..< lineEnd,
                                bodyRange: nil,
                                lineIndex: li,
                                level: level,
                                isSingleton: false
                            )
                            let idx = _outlineSpans.count
                            _outlineSpans.append(_OutlineSpan(start: lo + kwStart, end: nil, item: item, parentIndex: stack.last.map { $0.spanIndex }))
                            // containerPath へ push（Foo::Bar の最後の要素）
                            let pushName = lastName.isEmpty ? display : lastName
                            containerPath.append(pushName)
                            stack.append(Frame(kind: .class, name: pushName, container: containerPath, startOffset: lo + kwStart, nameRange: lastNameRange, headerEnd: lineEnd, lineIndex: li, isSingleton: false, spanIndex: idx))
                            continue
                        }
                        else if kwLen == 6 && memeq(line+kwStart, "module") {
                            var nameStart = j
                            while nameStart < count, (line[nameStart] == FuncChar.space || line[nameStart] == FuncChar.tab) { nameStart += 1 }
                            let (fullName, lastName, lastNameRange) = parseConstPath(line, count, from: nameStart, baseOffset: lo)
                            let display = fullName
                            let level = containerPath.count
                            let item = KOutlineItem(
                                kind: .module,
                                name: display,
                                containerPath: containerPath,
                                nameRange: lastNameRange,
                                headerRange: lo + kwStart ..< lineEnd,
                                bodyRange: nil,
                                lineIndex: li,
                                level: level,
                                isSingleton: false
                            )
                            let idx = _outlineSpans.count
                            _outlineSpans.append(_OutlineSpan(start: lo + kwStart, end: nil, item: item, parentIndex: stack.last.map { $0.spanIndex }))
                            let pushName = lastName.isEmpty ? display : lastName
                            containerPath.append(pushName)
                            stack.append(Frame(kind: .module, name: pushName, container: containerPath, startOffset: lo + kwStart, nameRange: lastNameRange, headerEnd: lineEnd, lineIndex: li, isSingleton: false, spanIndex: idx))
                            continue
                        }
                        else if kwLen == 3 && memeq(line+kwStart, "def") {
                            var nameStart = j
                            while nameStart < count, (line[nameStart] == FuncChar.space || line[nameStart] == FuncChar.tab) { nameStart += 1 }
                            let (disp, isSingleton, nameRange) = parseDefName(line, count, from: nameStart, baseOffset: lo)
                            let level = containerPath.count
                            let item = KOutlineItem(
                                kind: .method,
                                name: disp,
                                containerPath: containerPath,
                                nameRange: nameRange,
                                headerRange: lo + kwStart ..< lineEnd,
                                bodyRange: nil,
                                lineIndex: li,
                                level: level,
                                isSingleton: isSingleton
                            )
                            let idx = _outlineSpans.count
                            _outlineSpans.append(_OutlineSpan(start: lo + kwStart, end: nil, item: item, parentIndex: stack.last.map { $0.spanIndex }))
                            stack.append(Frame(kind: .method, name: disp, container: containerPath, startOffset: lo + kwStart, nameRange: nameRange, headerEnd: lineEnd, lineIndex: li, isSingleton: isSingleton, spanIndex: idx))
                            continue
                        }
                    }
                }
            }

            // ファイル末尾まで来て未閉鎖は end 未確定としてそのまま残す
        }
    }

    // 行内の区切り（識別子が終わる境界）
    private func isDelimiter(_ c: UInt8) -> Bool {
        if c == FuncChar.space || c == FuncChar.tab { return true }
        switch c {
        case FuncChar.lf, FuncChar.cr, FuncChar.leftParen, FuncChar.rightParen,
             FuncChar.leftBracket, FuncChar.rightBracket, FuncChar.leftBrace, FuncChar.rightBrace,
             FuncChar.comma, FuncChar.period, FuncChar.colon, FuncChar.semicolon,
             FuncChar.plus, FuncChar.minus, FuncChar.asterisk, FuncChar.slash,
             FuncChar.equals, FuncChar.pipe, FuncChar.caret, FuncChar.ampersand,
             FuncChar.exclamation, FuncChar.question, FuncChar.lt, FuncChar.gt:
            return true
        default:
            return false
        }
    }

    // "class Foo::Bar" の定数パスを抽出（表示名, 末尾名, 末尾名のRange）
    private func parseConstPath(_ line: UnsafePointer<UInt8>, _ n: Int, from: Int, baseOffset: Int)
    -> (String, String, Range<Int>) {
        var i = from
        var parts: [String] = []
        var lastRange: Range<Int> = baseOffset+from ..< baseOffset+from

        while i < n {
            // A-Z で始まる識別子
            if !(line[i] >= 0x41 && line[i] <= 0x5A) { break }
            let s = i
            i += 1
            while i < n, isIdentPart(line[i]) { i += 1 }
            let part = String(decoding: UnsafeBufferPointer(start: line + s, count: i - s), as: UTF8.self)
            parts.append(part)
            lastRange = baseOffset + s ..< baseOffset + i

            // "::" なら続行
            if i + 1 < n, line[i] == FuncChar.colon, line[i + 1] == FuncChar.colon {
                i += 2
                continue
            }
            break
        }
        let display = parts.joined(separator: "::")
        let last = parts.last ?? ""
        return (display, last, lastRange)
    }

    // def 名の抽出（表示名, isSingleton, nameRange）
    // - def self.foo         → isSingleton = true,  ".foo"
    // - def Klass.foo        → isSingleton = true,  ".foo"
    // - def Klass::foo       → isSingleton = true,  ".foo"
    // - def foo / def []=    → isSingleton = false, "#foo" / "#[]="
    private func parseDefName(_ line: UnsafePointer<UInt8>, _ n: Int, from: Int, baseOffset: Int)
    -> (String, Bool, Range<Int>) {
        var i = from
        var isSingleton = false

        // ユーティリティ
        @inline(__always)
        func skipSpaces(_ p: UnsafePointer<UInt8>, _ n: Int, _ i0: inout Int) {
            while i0 < n, (p[i0] == FuncChar.space || p[i0] == FuncChar.tab) { i0 += 1 }
        }

        skipSpaces(line, n, &i)

        // 1) def self.
        if i + 4 < n, memeq(line + i, "self") {
            var j = i + 4; skipSpaces(line, n, &j)
            if j < n, line[j] == FuncChar.period {
                isSingleton = true
                i = j + 1
            }
        } else {
            // 2) def ConstPath (Const(::Const)*) .|:: method
            var j = i
            var sawConstPath = false

            // 先頭は大文字の定数名
            if j < n, line[j] >= 0x41, line[j] <= 0x5A {
                sawConstPath = true
                j += 1
                while j < n, isIdentPart(line[j]) { j += 1 }
                // "::Const" を辿る
                while true {
                    let jj = j
                    skipSpaces(line, n, &j)
                    guard j + 1 < n, line[j] == FuncChar.colon, line[j + 1] == FuncChar.colon else { break }
                    j += 2
                    skipSpaces(line, n, &j)
                    // 次も定数名（大文字始まり）なら継続
                    guard j < n, line[j] >= 0x41, line[j] <= 0x5A else { j = jj; break }
                    j += 1
                    while j < n, isIdentPart(line[j]) { j += 1 }
                }
            }

            // 直後の区切りが '.' または '::' ならクラスメソッド扱い
            if sawConstPath {
                var k = j
                skipSpaces(line, n, &k)
                if k < n, line[k] == FuncChar.period {
                    isSingleton = true
                    i = k + 1
                } else if k + 1 < n, line[k] == FuncChar.colon, line[k + 1] == FuncChar.colon {
                    isSingleton = true
                    i = k + 2
                }
            }
        }

        skipSpaces(line, n, &i)

        // 3) メソッド名（識別子 / [] / []= / 演算子）
        let nameStart = i
        var nameEnd = i

        if nameStart < n {
            let c = line[nameStart]
            if isIdentStart(c) {
                var k = nameStart + 1
                while k < n, isIdentPart(line[k]) { k += 1 }
                // 末尾の ?, !, = を 1 文字だけ許容
                if k < n, (line[k] == FuncChar.question || line[k] == FuncChar.exclamation || line[k] == FuncChar.equals) {
                    k += 1
                }
                nameEnd = k
            } else if c == FuncChar.leftBracket {
                // [] / []=
                var k = nameStart + 1
                if k < n, line[k] == FuncChar.rightBracket {
                    k += 1
                    if k < n, line[k] == FuncChar.equals { k += 1 }
                    nameEnd = k
                }
            } else {
                // 演算子名（+, -, *, /, %, &, |, ^, <, >, ==, ===, <=, >=, <=> など）
                var k = nameStart + 1
                while k < n, isOperatorChar(line[k]) { k += 1 }
                if k > nameStart { nameEnd = k }
            }
        }

        if nameEnd <= nameStart {
            // 不明時は 1 文字だけ（フォールバック）
            nameEnd = min(n, nameStart + 1)
        }

        let range = baseOffset + nameStart ..< baseOffset + nameEnd
        let raw = String(decoding: UnsafeBufferPointer(start: line + nameStart,
                                                       count: nameEnd - nameStart),
                         as: UTF8.self)
        let display = (isSingleton ? "." : "#") + raw
        return (display, isSingleton, range)
    }

    private func isOperatorChar(_ c: UInt8) -> Bool {
        switch c {
        case FuncChar.plus, FuncChar.minus, FuncChar.asterisk, FuncChar.slash, FuncChar.percent,
             FuncChar.ampersand, FuncChar.pipe, FuncChar.caret, FuncChar.lt, FuncChar.gt,
             FuncChar.equals, FuncChar.exclamation, FuncChar.question, FuncChar.tilde:
            return true
        default:
            return false
        }
    }

    private func memeq(_ p: UnsafePointer<UInt8>, _ s: StaticString) -> Bool {
        // s は英小文字の短いキーワード前提（"def","class","module"）
        let len = s.utf8CodeUnitCount
        let q = s.utf8Start

        for i in 0..<len {
            if p[i] != q[i] { return false }
        }
        return true
    }
    
    // MARK: - Completion helpers

    /// 文書（UTF-8 bytes）から Ruby の「識別子っぽい語」を抽出する（大小区別, コメント/文字列はスキップ）
    /// 最小実装: # 行コメント, =begin/=end ブロック, '...' / "..." 文字列のみ対応（エスケープ考慮）
    /// ヒアドキュメントや %Q/%q, 正規表現等は対象外（必要なら将来拡張）
    private func _scanRubyIdentifiers(from bytes: [UInt8]) -> Set<Data> {
        var out = Set<Data>()

        enum Mode {
            case code
            case lineComment
            case blockComment   // =begin ... =end
            case singleQuoted   // '...'
            case doubleQuoted   // "..."
        }

        var mode: Mode = .code
        let n = bytes.count
        var i = 0

        // ユーティリティ
        @inline(__always) func isIdentHead(_ b: UInt8) -> Bool {
            // @ / $ / _ / A-Z / a-z
            return b == 0x40 || b == 0x24 || b == 0x5F || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        @inline(__always) func isIdentBody(_ b: UInt8) -> Bool {
            // 0-9 / _ / A-Z / a-z
            return (b >= 0x30 && b <= 0x39) || b == 0x5F || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }

        // =begin / =end のシグネチャ
        @inline(__always) func hasPrefix(_ s: StaticString, at pos: Int) -> Bool {
            let cnt = s.utf8CodeUnitCount
            if pos + cnt > n { return false }
            return s.withUTF8Buffer { sig in
                for j in 0..<cnt {
                    if bytes[pos + j] != sig[j] { return false }
                }
                return true
            }
        }

        while i < n {
            let b = bytes[i]

            switch mode {
            case .code:
                // 行コメント開始: '#'
                if b == 0x23 { mode = .lineComment; i += 1; continue }

                // ブロックコメント開始: "=begin"（行頭/空白後限定の厳密性は省略）
                if b == 0x3D, hasPrefix("=begin", at: i) {
                    mode = .blockComment
                    i += 6
                    continue
                }

                // 文字列開始
                if b == 0x27 { mode = .singleQuoted; i += 1; continue } // '
                if b == 0x22 { mode = .doubleQuoted; i += 1; continue } // "

                // 識別子抽出
                if isIdentHead(b) {
                    let start = i
                    i += 1
                    while i < n, isIdentBody(bytes[i]) { i += 1 }
                    // 語尾の ! / ? は Ruby で許容されるため、1 文字だけ認可
                    if i < n, (bytes[i] == 0x21 || bytes[i] == 0x3F) { i += 1 }

                    // ここまでが 1 単語。Data で取り出して Set 化（大小区別のまま）
                    let len = i - start
                    if len > 0 {
                        let d = Data(bytes[start..<i])
                        out.insert(d)
                    }
                    continue
                }

                i += 1

            case .lineComment:
                // 改行で終了
                if b == 0x0A { mode = .code }
                i += 1

            case .blockComment:
                if b == 0x3D, hasPrefix("=end", at: i) {
                    mode = .code
                    i += 4
                } else {
                    i += 1
                }

            case .singleQuoted:
                if b == 0x5C { // backslash
                    i = min(i + 2, n) // エスケープをスキップ
                } else if b == 0x27 { // '
                    mode = .code
                    i += 1
                } else {
                    i += 1
                }

            case .doubleQuoted:
                if b == 0x5C { // backslash
                    i = min(i + 2, n)
                } else if b == 0x22 { // "
                    mode = .code
                    i += 1
                } else {
                    i += 1
                }
            }
        }

        return out
    }

    /// 辞書順ソート済み配列に対し、prefix を持つ最初の位置（lower bound）を返す
    private func _lowerBound(in haystack: [Data], forPrefix prefix: Data) -> Int {
        var lo = 0
        var hi = haystack.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let d = haystack[mid]
            if d.count < prefix.count {
                // 短すぎる場合、先頭 prefix.count バイトがそもそも無い → d < prefix として扱う
                // ただし辞書順としては d < prefix 判定に相当
                if d.lexicographicallyPrecedes(prefix) {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            } else {
                // 比較は prefix 長だけ
                let cmp = d.prefix(prefix.count).lexicographicallyPrecedes(prefix)
                if cmp || d.prefix(prefix.count) == prefix && d.count < prefix.count {
                    // d[0..<prefix] < prefix と判定
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
        }
        return lo
    }

    /// 辞書順ソート済み配列に対し、prefix をもつ最後の位置の次（upper bound）を返す
    private func _upperBound(in haystack: [Data], forPrefix prefix: Data) -> Int {
        var lo = 0
        var hi = haystack.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let d = haystack[mid]
            if d.count < prefix.count {
                // 短い単語は必ず prefix より前なので、右へ
                if d.lexicographicallyPrecedes(prefix) {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            } else {
                let head = d.prefix(prefix.count)
                if head.lexicographicallyPrecedes(prefix) || head == prefix {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
        }
        return lo
    }
}
