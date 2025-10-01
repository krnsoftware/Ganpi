//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//  Ruby用シンタックスパーサ（skeleton直読み・ゼロコピー版）
//  - コメント: #, =begin/=end（行頭）
//  - 文字列: '..."'
//  - 正規表現: /.../（除算と文脈で判定）, %r..., %q/%Q/%w/%W/%s/%x/%i/%I
//  - 数値（-付きも一括）
//  - キーワード
//  - 高速化: 特別文字FastPath, ゼロコピー, 最小割当
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

    private enum EndState: Equatable {
        case neutral
        case inMultiComment
        case inStringSingle
        case inStringDouble
        case inPercentLiteral(closing: UInt8) // %系や /…/ 継続（closing に '/' も使う）
    }

    // MARK: 内部状態
    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []
    private var _needsRebuild = true

    // 色
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

    // 一時配列（再利用）
    private var _tmpSpans: [AttributedSpan] = []

    // MARK: 初期化
    init(storage: KTextStorageReadable) {
        self.storage = storage
    }

    // MARK: 更新通知
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        _needsRebuild = true
    }

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

    func wordRange(at index: Int) -> Range<Int>? {
        //storage.wordRange(at: index)
        return nil
    }

    // MARK: 行管理
    private func rebuildIfNeeded() {
        guard _needsRebuild else { return }
        _needsRebuild = false

        let skel = storage.skeletonString
        let lf = skel.newlineIndices()

        _lineStarts.removeAll(keepingCapacity: true)
        _lineStarts.append(0)
        for p in lf { _lineStarts.append(p + 1) }
        if _lineStarts.last! != storage.count {
            _lineStarts.append(storage.count)
        }

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
            // spansが空なら“安全アンカー”として採用
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

        // skeleton.bytes をゼロコピーで読む
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

    // MARK: 字句解析（ゼロコピー）
    private func lexLine(base: UnsafePointer<UInt8>, count: Int, startOffset: Int, initial: EndState) -> (EndState, [AttributedSpan]) {
        _tmpSpans.removeAll(keepingCapacity: true)

        var state = initial
        var i = 0
        let n = count

        // --- 継続状態の処理 ---
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
            let (closed, end) = scanQuoted(base, n, from: 0, quote: FuncChar.singleQuote)
            appendSpan(startOffset, 0, end, _colorString)
            if closed { i = end; state = .neutral } else { return (.inStringSingle, _tmpSpans) }
        }

        if state == .inStringDouble {
            let (closed, end) = scanQuoted(base, n, from: 0, quote: FuncChar.doubleQuote)
            appendSpan(startOffset, 0, end, _colorString)
            if closed { i = end; state = .neutral } else { return (.inStringDouble, _tmpSpans) }
        }

        if case let .inPercentLiteral(closing) = state {
            if closing == FuncChar.slash {
                let (closed, end) = scanSlashRegex(base, n, from: 0)
                appendSpan(startOffset, 0, end, _colorString)
                if closed { i = end; state = .neutral } else { return (.inPercentLiteral(closing: closing), _tmpSpans) }
            } else {
                let (closed, end) = scanUntil(base, n, from: 0, closing: closing)
                appendSpan(startOffset, 0, end, _colorString)
                if closed { i = end; state = .neutral } else { return (.inPercentLiteral(closing: closing), _tmpSpans) }
            }
        }

        // =begin は行頭のみ
        if matchLineHead(base, n, token: "=begin") {
            appendSpan(startOffset, 0, n, _colorComment)
            return (.inMultiComment, _tmpSpans)
        }

        // --- Fast Path ---
        if state == .neutral && i == 0 && !hasSpecialToken(base, n) {
            // 特別文字が無い行は解析不要
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
                let (closed, end) = scanQuoted(base, n, from: i, quote: FuncChar.doubleQuote)
                appendSpan(startOffset, i, end, _colorString)
                if closed { i = end } else { return (.inStringDouble, _tmpSpans) }
                continue
            }

            // %系
            if c == FuncChar.percent, i + 1 < n {
                let (closing, offset) = determinePercentClosing(base, n, from: i + 1)
                if closing == FuncChar.slash {
                    let (closed, end) = scanSlashRegex(base, n, from: offset - 1)
                    appendSpan(startOffset, i, end, _colorString)
                    if closed { i = end } else { return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans) }
                    continue
                } else {
                    let (closed, end) = scanUntil(base, n, from: offset, closing: closing)
                    appendSpan(startOffset, i, end, _colorString)
                    if closed { i = end } else { return (.inPercentLiteral(closing: closing), _tmpSpans) }
                    continue
                }
            }

            // /…/ 正規表現（除算誤判定の抑止）
            if c == FuncChar.slash {
                if let p = previousNonSpace(base, i) {
                    if looksLikeOperandTail(p) && !allowsRegexAfter(p) {
                        // 除算とみなす：スキップして次へ
                        i += 1
                    } else {
                        let (closed, end) = scanSlashRegex(base, n, from: i)
                        appendSpan(startOffset, i, end, _colorString)
                        if closed { i = end } else { return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans) }
                    }
                } else {
                    // 行頭の '/'
                    let (closed, end) = scanSlashRegex(base, n, from: i)
                    appendSpan(startOffset, i, end, _colorString)
                    if closed { i = end } else { return (.inPercentLiteral(closing: FuncChar.slash), _tmpSpans) }
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
                // バイト列→String化はここだけ（短い＆必要時のみ）
                let text = String(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + i),
                                  length: end - i,
                                  encoding: .utf8,
                                  freeWhenDone: false) ?? ""
                let color = _keywords.contains(text) ? _colorKeyword : .black
                appendSpan(startOffset, i, end, color)
                i = end
                continue
            }

            i += 1
        }

        return (state, _tmpSpans)
    }

    // MARK: 補助（ゼロコピー版）

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

    private func scanQuoted(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, quote: UInt8) -> (Bool, Int) {
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

    private func scanSlashRegex(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> (Bool, Int) {
        var i = from + 1
        while i < n {
            if base[i] == FuncChar.slash {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 {
                    i += 1
                    // フラグ（a〜z）
                    while i < n, (base[i] >= 0x61 && base[i] <= 0x7A) { i += 1 }
                    return (true, i)
                }
            }
            i += 1
        }
        return (false, n)
    }

    private func scanUntil(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, closing: UInt8) -> (Bool, Int) {
        var i = from
        while i < n {
            if base[i] == closing {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return (true, i + 1) }
            }
            i += 1
        }
        return (false, n)
    }

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

    private func previousNonSpace(_ base: UnsafePointer<UInt8>, _ i: Int) -> UInt8? {
        var k = i - 1
        while k >= 0 {
            let c = base[k]
            if c != FuncChar.space && c != FuncChar.tab { return c }
            k -= 1
        }
        return nil
    }

    private func allowsRegexAfter(_ c: UInt8) -> Bool {
        switch c {
        case FuncChar.equals, FuncChar.plus, FuncChar.minus, FuncChar.asterisk, FuncChar.percent,
             FuncChar.caret, FuncChar.pipe, FuncChar.ampersand, FuncChar.exclamation,
             FuncChar.colon, FuncChar.semicolon, FuncChar.comma,
             FuncChar.leftParen, FuncChar.leftBracket, FuncChar.leftBrace,
             FuncChar.question, FuncChar.lt, FuncChar.gt:
            return true
        default:
            return false
        }
    }

    private func looksLikeOperandTail(_ c: UInt8) -> Bool {
        if (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
            return true
        }
        switch c {
        case FuncChar.underscore, FuncChar.singleQuote, FuncChar.doubleQuote,
             FuncChar.rightParen, FuncChar.rightBracket, FuncChar.rightBrace,
             FuncChar.period, FuncChar.dollar, FuncChar.at:
            return true
        default:
            return false
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

    private func hasSpecialToken(_ base: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        // ざっくり：コメント/引用/正規表現/%/=/=begin等で使い得るトリガ
        var i = 0
        while i < n {
            switch base[i] {
            case FuncChar.numeric, FuncChar.singleQuote, FuncChar.doubleQuote,
                 FuncChar.percent, FuncChar.slash, FuncChar.equals:
                return true
            default:
                i += 1
            }
        }
        return false
    }

    private func appendSpan(_ baseOffset: Int, _ a: Int, _ b: Int, _ color: NSColor) {
        if a < b {
            _tmpSpans.append(AttributedSpan(range: (baseOffset + a)..<(baseOffset + b),
                                            attributes: [.foregroundColor: color]))
        }
    }
}
