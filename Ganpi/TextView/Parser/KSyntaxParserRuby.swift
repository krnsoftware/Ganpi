//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//  Ruby用シンタックスパーサ（skeleton直読み・ゼロコピー版、安定重視）
//  - コメント: #, =begin/=end（行頭）
//  - 文字列: '..."'（式展開 #{...} はデフォルトでは無効 = 漏れゼロ）
//  - 正規表現: /.../（文脈ヒューリスティック）, %r..., %q/%Q/%w/%W/%s/%x/%i/%I
//  - 数値（-付き）/ キーワード（青）
//  - ※ 将来 #{...} を有効化する場合は _enableStringInterpolationColoring を true に
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // MARK: 公開
    let storage: KTextStorageReadable

    // MARK: 内部型
    private struct LineInfo {
        var endState: EndState = .neutral
        var spans: [AttributedSpan] = []
        var dirty: Bool = true
    }

    // 再帰保持があるため indirect
    private indirect enum EndState: Equatable {
        case neutral
        case inMultiComment
        case inStringSingle
        case inStringDouble
        case inPercentLiteral(closing: UInt8)     // %系 or /…/ 継続（closing に '/' も使う）
        case inInterpolation(ret: EndState, depth: Int, outerClosing: UInt8)
    }

    // MARK: フラグ（ここを真にすると #{...} の色分けを再有効化）
    private let _enableStringInterpolationColoring = false

    // MARK: 内部状態
    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []
    private var _needsRebuild = true

    // 色（前回踏襲）
    private let _colorString  = NSColor(hexString: "#860300") ?? .black   // 文字列/regex/%系
    private let _colorComment = NSColor(hexString: "#0B5A00") ?? .black   // コメント
    private let _colorKeyword = NSColor(hexString: "#070093") ?? .black   // キーワード
    private let _colorNumber  = NSColor(hexString: "#070093") ?? .black   // 数値

    // キーワード
    private let _keywords: Set<String> = [
        "BEGIN","END","alias","and","begin","break","case","class","def","defined?",
        "do","else","elsif","end","ensure","false","for","if","in","module","next",
        "nil","not","or","redo","rescue","retry","return","self","super","then",
        "true","undef","unless","until","when","while","yield"
    ]

    // / の直前に来たら regex を許可しやすいキーワード（小文字セット）
    private let _regexFriendlyKeywords: Set<String> = [
        "if","elsif","while","until","when","case","return","then","and","or","not"
    ]

    // 一時配列（再利用）
    private var _tmpSpans: [AttributedSpan] = []

    // MARK: 初期化
    init(storage: KTextStorageReadable) { self.storage = storage }

    // MARK: 更新通知
    func noteEdit(oldRange: Range<Int>, newCount: Int) { _needsRebuild = true }

    // MARK: 同期
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

    // MARK: 属性取得
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

        let lo = range.lowerBound
        let hi = range.upperBound

        for li in li0...li1 {
            for span in _lines[li].spans {
                if span.range.upperBound <= lo { continue }
                if span.range.lowerBound >= hi { break }
                let a = max(span.range.lowerBound, lo)
                let b = min(span.range.upperBound, hi)
                if a < b {
                    result.append(AttributedSpan(range: a..<b, attributes: span.attributes))
                }
            }
        }
        return result
    }

    // 無限ループ回避（後日実装）
    func wordRange(at index: Int) -> Range<Int>? { nil }

    // MARK: 行管理
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

    // neutral 既知行へ巻き戻し
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

    // MARK: 解析本体
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

    // MARK: 字句解析
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
            let (closed, end) = scanQuoted(base, n, from: 0, quote: FuncChar.singleQuote)
            appendSpan(startOffset, 0, end, _colorString)
            if closed { i = end; state = .neutral } else { return (.inStringSingle, _tmpSpans) }
        }

        if state == .inStringDouble {
            if !_enableStringInterpolationColoring {
                let (closed, end) = scanQuotedNoInterp(base, n, from: 0, quote: FuncChar.doubleQuote)
                appendSpan(startOffset, 0, end, _colorString)
                if closed { i = end; state = .neutral } else { return (.inStringDouble, _tmpSpans) }
            } else {
                let r = scanQuotedOrInterpCont(base, n, from: 0, quote: FuncChar.doubleQuote)
                switch r {
                case .closed(let end):
                    appendSpan(startOffset, 0, end, _colorString); i = end; state = .neutral
                case .interp(let open):
                    appendSpan(startOffset, 0, open + 2, _colorString)
                    return (.inInterpolation(ret: .inStringDouble, depth: 1, outerClosing: FuncChar.doubleQuote), _tmpSpans)
                case .eof(let end):
                    appendSpan(startOffset, 0, end, _colorString)
                    return (.inStringDouble, _tmpSpans)
                }
            }
        }

        if case let .inPercentLiteral(closing) = state {
            if closing == FuncChar.slash {
                let r = scanSlashRegexOrInterp(base, n, from: 0)
                switch r {
                case .closed(let end):
                    appendSpan(startOffset, 0, end, _colorString); i = end; state = .neutral
                case .interp(let open):
                    if _enableStringInterpolationColoring {
                        appendSpan(startOffset, 0, open + 2, _colorString)
                        return (.inInterpolation(ret: .inPercentLiteral(closing: FuncChar.slash), depth: 1, outerClosing: FuncChar.slash), _tmpSpans)
                    } else {
                        appendSpan(startOffset, 0, open + 2, _colorString)
                        return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans)
                    }
                case .eof(let end):
                    appendSpan(startOffset, 0, end, _colorString)
                    return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans)
                }
            } else {
                let r = scanUntilOrInterp(base, n, from: 0, closing: closing)
                switch r {
                case .closed(let end):
                    appendSpan(startOffset, 0, end, _colorString); i = end; state = .neutral
                case .interp(let open):
                    if _enableStringInterpolationColoring {
                        appendSpan(startOffset, 0, open + 2, _colorString)
                        return (.inInterpolation(ret: .inPercentLiteral(closing: closing), depth: 1, outerClosing: closing), _tmpSpans)
                    } else {
                        appendSpan(startOffset, 0, open + 2, _colorString)
                        return (.inPercentLiteral(closing: closing), _tmpSpans)
                    }
                case .eof(let end):
                    appendSpan(startOffset, 0, end, _colorString)
                    return (.inPercentLiteral(closing: closing), _tmpSpans)
                }
            }
        }

        // 行頭の =begin
        if matchLineHead(base, n, token: "=begin") {
            appendSpan(startOffset, 0, n, _colorComment)
            return (.inMultiComment, _tmpSpans)
        }

        // --- 空白行 fast path ---
        if state == .neutral && i == 0 && isWhitespaceOnly(base, n) {
            return (.neutral, _tmpSpans)
        }

        // --- 通常走査 ---
        while i < n {
            let c = base[i]

            // 行コメント
            if c == FuncChar.numeric {
                appendSpan(startOffset, i, n, _colorComment)
                break
            }

            // 文字列
            if c == FuncChar.singleQuote {
                let (closed, end) = scanQuoted(base, n, from: i, quote: FuncChar.singleQuote)
                appendSpan(startOffset, i, end, _colorString)
                if closed { i = end } else { return (.inStringSingle, _tmpSpans) }
                continue
            }

            if c == FuncChar.doubleQuote {
                if !_enableStringInterpolationColoring {
                    let (closed, end) = scanQuotedNoInterp(base, n, from: i, quote: FuncChar.doubleQuote)
                    appendSpan(startOffset, i, end, _colorString)
                    if closed { i = end } else { return (.inStringDouble, _tmpSpans) }
                    continue
                } else {
                    // 高度版（式展開対応）: 必要になったらフラグを true に
                    var cur = i
                    var first = true
                    func nextScan(from pos: Int, first: Bool) -> ScanRI {
                        return first
                        ? scanQuotedOrInterp(base, n, from: pos, quote: FuncChar.doubleQuote)
                        : scanQuotedOrInterpCont(base, n, from: pos, quote: FuncChar.doubleQuote)
                    }
                    while true {
                        let r = nextScan(from: cur, first: first); first = false
                        switch r {
                        case .closed(let end):
                            appendSpan(startOffset, cur, end, _colorString)
                            i = end
                        case .interp(let open):
                            appendSpan(startOffset, cur, open + 2, _colorString)
                            let (done, j, _) = scanInterpolatedBlock(base, n, from: open + 2, depth: 1)
                            if done { cur = j; continue }
                            else {
                                return (.inInterpolation(ret: .inStringDouble, depth: 1, outerClosing: FuncChar.doubleQuote), _tmpSpans)
                            }
                        case .eof(let end):
                            appendSpan(startOffset, cur, end, _colorString)
                            return (.inStringDouble, _tmpSpans)
                        }
                        break
                    }
                    continue
                }
            }

            // %系
            if c == FuncChar.percent, i + 1 < n {
                let (closing, offset) = determinePercentClosing(base, n, from: i + 1)
                if closing == FuncChar.slash {
                    let r = scanSlashRegexOrInterp(base, n, from: offset - 1)
                    switch r {
                    case .closed(let end):
                        appendSpan(startOffset, i, end, _colorString); i = end
                    case .interp(let open):
                        appendSpan(startOffset, i, open + 2, _colorString)
                        if _enableStringInterpolationColoring {
                            i = open + 2
                            return (.inInterpolation(ret: .inPercentLiteral(closing: FuncChar.slash), depth: 1, outerClosing: FuncChar.slash), _tmpSpans)
                        } else {
                            return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans)
                        }
                    case .eof(let end):
                        appendSpan(startOffset, i, end, _colorString)
                        return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans)
                    }
                } else {
                    let r = scanUntilOrInterp(base, n, from: offset, closing: closing)
                    switch r {
                    case .closed(let end):
                        appendSpan(startOffset, i, end, _colorString); i = end
                    case .interp(let open):
                        appendSpan(startOffset, i, open + 2, _colorString)
                        if _enableStringInterpolationColoring {
                            i = open + 2
                            return (.inInterpolation(ret: .inPercentLiteral(closing: closing), depth: 1, outerClosing: closing), _tmpSpans)
                        } else {
                            return (.inPercentLiteral(closing: closing), _tmpSpans)
                        }
                    case .eof(let end):
                        appendSpan(startOffset, i, end, _colorString)
                        return (.inPercentLiteral(closing: closing), _tmpSpans)
                    }
                }
                continue
            }

            // /…/ 正規表現（文脈ヒューリスティック）
            if c == FuncChar.slash {
                if contextAllowsRegexBeforeSlash(base, i) {
                    let r = scanSlashRegexOrInterp(base, n, from: i)
                    switch r {
                    case .closed(let end):
                        appendSpan(startOffset, i, end, _colorString); i = end
                    case .interp(let open):
                        appendSpan(startOffset, i, open + 2, _colorString)
                        if _enableStringInterpolationColoring {
                            i = open + 2
                            return (.inInterpolation(ret: .inPercentLiteral(closing: FuncChar.slash), depth: 1, outerClosing: FuncChar.slash), _tmpSpans)
                        } else {
                            return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans)
                        }
                    case .eof(let end):
                        appendSpan(startOffset, i, end, _colorString)
                        return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans)
                    }
                } else {
                    i += 1 // 除算
                }
                continue
            }

            // 数値（マイナス付き）
            if c == FuncChar.minus || isDigit(c) {
                let end = scanNumber(base, n, from: i)
                appendSpan(startOffset, i, end, _colorNumber)
                i = end
                continue
            }

            // キーワード / 識別子
            if isIdentStart(c) {
                let end = scanIdentEnd(base, n, from: i)
                let buf = UnsafeBufferPointer(start: base + i, count: end - i)
                let text = String(decoding: buf, as: UTF8.self)
                let color = _keywords.contains(text) ? _colorKeyword : .black
                appendSpan(startOffset, i, end, color)
                i = end
                continue
            }

            i += 1
        }

        return (state, _tmpSpans)
    }

    // MARK: 補助

    // 行頭の "=begin"/"=end" 判定（先頭空白不可）
    private func matchLineHead(_ base: UnsafePointer<UInt8>, _ n: Int, token: String) -> Bool {
        if n == 0 { return false }
        let c0 = base[0]
        if c0 == FuncChar.space || c0 == FuncChar.tab { return false }
        let u = Array(token.utf8)
        if n < u.count { return false }
        for k in 0..<u.count where base[k] != u[k] { return false }
        return true
    }

    private func isWhitespaceOnly(_ base: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        while i < n {
            let c = base[i]
            if c != FuncChar.space && c != FuncChar.tab { return false }
            i += 1
        }
        return true
    }

    private enum ScanRI { case closed(Int), interp(Int), eof(Int) } // endIndex / openIndex / endIndex

    // クォート（式展開なし）
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

    // クォート（式展開なしの片方）
    private func scanQuoted(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, quote: UInt8) -> (Bool, Int) {
        return scanQuotedNoInterp(base, n, from: from, quote: quote)
    }

    // ダブルクォート/式展開あり（開き位置から）※有効化時のみ使用
    private func scanQuotedOrInterp(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, quote: UInt8) -> ScanRI {
        var i = from + 1
        while i < n {
            let c = base[i]
            if _enableStringInterpolationColoring,
               c == FuncChar.numeric, i + 1 < n, base[i + 1] == FuncChar.leftBrace {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .interp(i) }
            }
            if c == quote {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .closed(i + 1) }
            }
            i += 1
        }
        return .eof(n)
    }

    // ダブルクォート/式展開あり（途中位置からの継続）※有効化時のみ使用
    private func scanQuotedOrInterpCont(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, quote: UInt8) -> ScanRI {
        var i = from
        while i < n {
            let c = base[i]
            if _enableStringInterpolationColoring,
               c == FuncChar.numeric, i + 1 < n, base[i + 1] == FuncChar.leftBrace {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .interp(i) }
            }
            if c == quote {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .closed(i + 1) }
            }
            i += 1
        }
        return .eof(n)
    }

    // %系（式展開はフラグで）
    private func scanUntilOrInterp(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, closing: UInt8) -> ScanRI {
        var i = from
        while i < n {
            let c = base[i]
            if _enableStringInterpolationColoring,
               c == FuncChar.numeric, i + 1 < n, base[i + 1] == FuncChar.leftBrace {
                return .interp(i)
            }
            if c == closing {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .closed(i + 1) }
            }
            i += 1
        }
        return .eof(n)
    }

    // /…/（式展開はフラグで）
    private func scanSlashRegexOrInterp(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> ScanRI {
        var i = from + 1
        while i < n {
            let c = base[i]
            if _enableStringInterpolationColoring,
               c == FuncChar.numeric, i + 1 < n, base[i + 1] == FuncChar.leftBrace {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return .interp(i) }
            }
            if c == FuncChar.slash {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 {
                    i += 1
                    while i < n, (base[i] >= 0x61 && base[i] <= 0x7A) { i += 1 } // フラグ a..z
                    return .closed(i)
                }
            }
            i += 1
        }
        return .eof(n)
    }

    // --- 式展開ブロック（有効化時のみ使用）
    private func scanInterpolatedBlock(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, depth: Int) -> (Bool, Int, Int) {
        var i = from
        var d = depth
        while i < n {
            let c = base[i]
            if c == FuncChar.numeric { return (false, n, d) } // 行コメントで打ち切り

            if c == FuncChar.singleQuote {
                let (_, end) = scanQuoted(base, n, from: i, quote: FuncChar.singleQuote)
                i = end; continue
            }
            if c == FuncChar.doubleQuote {
                let r = scanQuotedOrInterp(base, n, from: i, quote: FuncChar.doubleQuote)
                switch r {
                case .closed(let end): i = end
                case .interp(let open): i = open + 2; d += 1
                case .eof(let end): return (false, end, d)
                }
                continue
            }

            if c == FuncChar.percent, i + 1 < n {
                let (closing, offset) = determinePercentClosing(base, n, from: i + 1)
                let r = scanUntilOrInterp(base, n, from: offset, closing: closing)
                switch r {
                case .closed(let end): i = end
                case .interp(let open): i = open + 2; d += 1
                case .eof(let end): return (false, end, d)
                }
                continue
            }

            if c == FuncChar.slash {
                if contextAllowsRegexBeforeSlash(base, i) {
                    let r = scanSlashRegexOrInterp(base, n, from: i)
                    switch r {
                    case .closed(let end): i = end
                    case .interp(let open): i = open + 2; d += 1
                    case .eof(let end): return (false, end, d)
                    }
                    continue
                }
            }

            if c == FuncChar.leftBrace { d += 1; i += 1; continue }
            if c == FuncChar.rightBrace {
                d -= 1
                if d == 0 { return (true, i, d) }
                i += 1; continue
            }

            i += 1
        }
        return (false, n, d)
    }

    // --- そのほか補助 ---

    private func determinePercentClosing(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> (UInt8, Int) {
        var i = from
        if i < n {
            i += 1 // 種別文字を読み飛ばし
            if i < n {
                let opener = base[i]
                switch opener {
                case FuncChar.leftBrace:   return (FuncChar.rightBrace, i + 1)
                case FuncChar.leftBracket: return (FuncChar.rightBracket, i + 1)
                case FuncChar.leftParen:   return (FuncChar.rightParen, i + 1)
                case FuncChar.lt:          return (FuncChar.gt, i + 1)
                default:                   return (opener, i + 1) // 単一記号
                }
            }
        }
        return (UInt8(ascii: "}"), from)
    }

    private func previousNonSpaceIndex(_ base: UnsafePointer<UInt8>, _ i: Int) -> (idx: Int, hadGap: Bool)? {
        var k = i - 1
        var gap = false
        while k >= 0 {
            let c = base[k]
            if c == FuncChar.space || c == FuncChar.tab { gap = true; k -= 1; continue }
            return (k, gap)
        }
        return nil
    }

    private func trailingWord(at k: Int, base: UnsafePointer<UInt8>) -> (start: Int, end: Int)? {
        var s = k
        while s >= 0 {
            let c = base[s]
            let isAZ = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore
            if !isAZ { break }
            s -= 1
        }
        s += 1
        return (s <= k) ? (s, k + 1) : nil
    }

    // 小文字化で簡素に判定（十分高速）
    private func isRegexFriendlyKeyword(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        let buf = UnsafeBufferPointer(start: base + start, count: end - start)
        let text = String(decoding: buf, as: UTF8.self).lowercased()
        return _regexFriendlyKeywords.contains(text)
    }

    private func contextAllowsRegexBeforeSlash(_ base: UnsafePointer<UInt8>, _ i: Int) -> Bool {
        guard let (k, gap) = previousNonSpaceIndex(base, i) else { return true } // 行頭 → OK
        let c = base[k]
        if allowsRegexAfter(c) { return true }
        if gap, let (s, e) = trailingWord(at: k, base: base) {
            return isRegexFriendlyKeyword(base, s, e)
        }
        return false
    }

    private func allowsRegexAfter(_ c: UInt8) -> Bool {
        switch c {
        case FuncChar.equals, FuncChar.plus, FuncChar.minus, FuncChar.asterisk, FuncChar.percent,
             FuncChar.caret, FuncChar.pipe, FuncChar.ampersand, FuncChar.exclamation,
             FuncChar.colon, FuncChar.semicolon, FuncChar.comma,
             FuncChar.leftParen, FuncChar.leftBracket, FuncChar.leftBrace,
             FuncChar.question, FuncChar.lt, FuncChar.gt:
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

    private func appendSpan(_ baseOffset: Int, _ a: Int, _ b: Int, _ color: NSColor) {
        if a < b {
            _tmpSpans.append(AttributedSpan(range: (baseOffset + a)..<(baseOffset + b),
                                            attributes: [.foregroundColor: color]))
        }
    }
}
