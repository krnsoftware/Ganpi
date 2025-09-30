//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//  Ruby用シンタックスパーサ
//  コメント・文字列・正規表現・数値・キーワード・%系リテラルに対応
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // MARK: - 公開
    let storage: KTextStorageReadable

    // MARK: - 内部型
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
        case inPercentLiteral(closing: UInt8) // %系や /…/ の継続
    }

    // MARK: - 内部状態
    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []
    private var _needsRebuild = true

    // 色
    private let _colorString  = NSColor(hexString: "#860300") ?? .black   // 文字列/regex/%系
    private let _colorComment = NSColor(hexString: "#0B5A00") ?? .black   // コメント
    private let _colorKeyword = NSColor(hexString: "#070093") ?? .black   // キーワード
    private let _colorNumber  = NSColor(hexString: "#070093") ?? .black   // 数値

    // キーワードセット（必要に応じて追加）
    private let _keywords: Set<String> = [
        "BEGIN","END","alias","and","begin","break","case","class","def","defined?",
        "do","else","elsif","end","ensure","false","for","if","in","module","next",
        "nil","not","or","redo","rescue","retry","return","self","super","then",
        "true","undef","unless","until","when","while","yield"
    ]

    // MARK: - 初期化
    init(storage: KTextStorageReadable) {
        self.storage = storage
    }

    // MARK: - プロトコル準拠
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        _needsRebuild = true
    }

    func ensureUpToDate(for range: Range<Int>) {
        rebuildIfNeeded()
        let need = lineRangeCovering(range, pad: 2)
        let anchor = anchorLine(before: need.lowerBound)   // neutral な既知行へ巻き戻し
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
        let loOff = max(0, min(range.lowerBound, textCount == 0 ? 0 : textCount - 1))
        let hiProbe = max(0, min(max(range.upperBound - 1, 0), textCount == 0 ? 0 : textCount - 1))

        var li0 = lineIndex(at: loOff)
        var li1 = lineIndex(at: hiProbe)
        li0 = max(0, min(li0, lineCount - 1))
        li1 = max(0, min(li1, lineCount - 1))
        if li0 > li1 { return [] }

        var result: [AttributedSpan] = []
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
        storage.wordRange(at: index)
    }

    // MARK: - 行管理
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

    // neutral な既知行（dirty でなく endState が .neutral）まで上へ巻き戻す
    private func anchorLine(before line: Int) -> Int {
        guard !_lines.isEmpty else { return 0 }
        var i = max(0, min(line, _lines.count - 1))
        i = max(0, i - 1)
        while i > 0 {
            if _lines[i].endState == .neutral && !_lines[i].dirty { return i }
            i -= 1
        }
        return 0
    }

    // MARK: - 行解析
    private func parseLines(in range: Range<Int>) {
        guard !_lines.isEmpty else { return }
        var state: EndState = (range.lowerBound > 0) ? _lines[range.lowerBound - 1].endState : .neutral
        let skel = storage.skeletonString
        for li in range {
            if !_lines[li].dirty && _lines[li].endState == state {
                state = _lines[li].endState
                continue
            }
            let lo = _lineStarts[li]
            let hi = _lineStarts[li + 1]
            let bytes = Array(skel.bytes(in: lo..<hi))
            let (newState, spans) = lexLine(bytes: bytes, base: lo, initial: state)
            _lines[li].endState = newState
            _lines[li].spans = spans
            _lines[li].dirty = false
            state = newState
        }
    }

    // MARK: - 字句解析
    private func lexLine(bytes: [UInt8], base: Int, initial: EndState) -> (EndState, [AttributedSpan]) {
        var spans: [AttributedSpan] = []
        var state = initial
        let n = bytes.count
        var i = 0

        // --- 継続状態の先頭処理 ---
        if state == .inMultiComment {
            if matchLineHead(bytes, token: "=end") {
                spans.append(span(base..<base+n, color: _colorComment))
                return (.neutral, spans)
            } else {
                spans.append(span(base..<base+n, color: _colorComment))
                return (.inMultiComment, spans)
            }
        }

        if state == .inStringSingle {
            let (closed, end) = scanQuoted(bytes, from: 0, quote: FuncChar.singleQuote)
            spans.append(span(base..<base+end, color: _colorString))
            if closed { i = end; state = .neutral } else { return (.inStringSingle, spans) }
        }

        if state == .inStringDouble {
            let (closed, end) = scanQuoted(bytes, from: 0, quote: FuncChar.doubleQuote)
            spans.append(span(base..<base+end, color: _colorString))
            if closed { i = end; state = .neutral } else { return (.inStringDouble, spans) }
        }

        if case let .inPercentLiteral(closing) = state {
            if closing == FuncChar.slash {
                let (closed, end) = scanSlashRegex(bytes, from: 0)
                spans.append(span(base..<base+end, color: _colorString))
                if closed { i = end; state = .neutral } else { return (.inPercentLiteral(closing: closing), spans) }
            } else {
                let (closed, end) = scanUntil(bytes, from: 0, closing: closing)
                spans.append(span(base..<base+end, color: _colorString))
                if closed { i = end; state = .neutral } else { return (.inPercentLiteral(closing: closing), spans) }
            }
        }

        // 行頭の =begin
        if matchLineHead(bytes, token: "=begin") {
            spans.append(span(base..<base+n, color: _colorComment))
            return (.inMultiComment, spans)
        }

        // --- 通常走査 ---
        while i < n {
            let c = bytes[i]

            // 行コメント
            if c == FuncChar.numeric {
                spans.append(span((base+i)..<base+n, color: _colorComment))
                break
            }

            // 文字列（' / "）
            if c == FuncChar.singleQuote {
                let (closed, end) = scanQuoted(bytes, from: i, quote: FuncChar.singleQuote)
                spans.append(span((base+i)..<base+end, color: _colorString))
                if closed { i = end } else { return (.inStringSingle, spans) }
                continue
            }
            if c == FuncChar.doubleQuote {
                let (closed, end) = scanQuoted(bytes, from: i, quote: FuncChar.doubleQuote)
                spans.append(span((base+i)..<base+end, color: _colorString))
                if closed { i = end } else { return (.inStringDouble, spans) }
                continue
            }

            // %系（%q/%Q/%w/%W/%s/%x/%i/%I/%r など）
            if c == FuncChar.percent, i + 1 < n {
                let (closing, offset) = determinePercentLiteralClosing(bytes, from: i+1)
                if closing == FuncChar.slash {
                    // 単一区切りが / の場合（%r/ ... /）
                    let (closed, end) = scanSlashRegex(bytes, from: offset - 1)
                    spans.append(span((base+i)..<base+end, color: _colorString))
                    if closed { i = end } else { return (.inPercentLiteral(closing: FuncChar.slash), spans) }
                    continue
                } else {
                    let (closed, end) = scanUntil(bytes, from: offset, closing: closing)
                    spans.append(span((base+i)..<base+end, color: _colorString))
                    if closed { i = end } else { return (.inPercentLiteral(closing: closing), spans) }
                    continue
                }
            }

            // 素の /…/ 正規表現
            if c == FuncChar.slash {
                let (closed, end) = scanSlashRegex(bytes, from: i)
                spans.append(span((base+i)..<base+end, color: _colorString))
                if closed { i = end } else { return (.inPercentLiteral(closing: FuncChar.slash), spans) }
                continue
            }

            // 数値（マイナス付き対応）
            if c == FuncChar.minus || isDigit(c) {
                let (end, _) = scanNumber(bytes, from: i)
                spans.append(span((base+i)..<base+end, color: _colorNumber))
                i = end
                continue
            }

            // キーワード / 識別子
            if isIdentStart(c) {
                let (end, token) = scanIdent(bytes, from: i)
                let text = String(decoding: token, as: UTF8.self)
                let color = _keywords.contains(text) ? _colorKeyword : .black
                spans.append(span((base+i)..<base+end, color: color))
                i = end
                continue
            }

            i += 1
        }

        return (state, spans)
    }

    // MARK: - 補助
    private func matchLineHead(_ bytes: [UInt8], token: String) -> Bool {
        guard !bytes.isEmpty else { return false }
        if bytes[0] == FuncChar.space || bytes[0] == FuncChar.tab { return false }
        let t = Array(token.utf8)
        if bytes.count < t.count { return false }
        for i in 0..<t.count where bytes[i] != t[i] { return false }
        return true
    }

    private func scanQuoted(_ bytes: [UInt8], from: Int, quote: UInt8) -> (Bool, Int) {
        var i = from + 1
        let n = bytes.count
        while i < n {
            if bytes[i] == quote {
                var esc = 0, k = i - 1
                while k >= 0, bytes[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return (true, i+1) }
            }
            i += 1
        }
        return (false, n)
    }

    private func scanUntil(_ bytes: [UInt8], from: Int, closing: UInt8) -> (Bool, Int) {
        var i = from
        let n = bytes.count
        while i < n {
            if bytes[i] == closing {
                var esc = 0, k = i - 1
                while k >= 0, bytes[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return (true, i+1) }
            }
            i += 1
        }
        return (false, n)
    }

    private func determinePercentLiteralClosing(_ bytes: [UInt8], from: Int) -> (UInt8, Int) {
        let n = bytes.count
        var i = from
        if i < n {
            i += 1 // 種別文字を読み飛ばし
            if i < n {
                let opener = bytes[i]
                switch opener {
                case FuncChar.leftBrace:   return (FuncChar.rightBrace, i+1)
                case FuncChar.leftBracket: return (FuncChar.rightBracket, i+1)
                case FuncChar.leftParen:   return (FuncChar.rightParen, i+1)
                case FuncChar.lt:          return (FuncChar.gt, i+1)
                default:                   return (opener, i+1) // 単一記号
                }
            }
        }
        // フォールバック（異常系）
        return (UInt8(ascii: "}"), from)
    }

    private func scanSlashRegex(_ bytes: [UInt8], from: Int) -> (Bool, Int) {
        var i = from + 1
        let n = bytes.count
        while i < n {
            if bytes[i] == FuncChar.slash {
                var esc = 0, k = i - 1
                while k >= 0, bytes[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 {
                    i += 1
                    // オプションフラグ（a〜z）
                    while i < n, (bytes[i] >= 0x61 && bytes[i] <= 0x7A) {
                        i += 1
                    }
                    return (true, i)
                }
            }
            i += 1
        }
        return (false, n)
    }

    private func scanNumber(_ bytes: [UInt8], from: Int) -> (Int, [UInt8]) {
        var i = from
        let n = bytes.count
        if i < n, bytes[i] == FuncChar.minus {
            i += 1
        }
        while i < n {
            let c = bytes[i]
            if !isDigit(c) && c != FuncChar.period &&
               !(c >= 0x61 && c <= 0x7A) && !(c >= 0x41 && c <= 0x5A) {
                break
            }
            i += 1
        }
        return (i, Array(bytes[from..<i]))
    }

    private func scanIdent(_ bytes: [UInt8], from: Int) -> (Int, [UInt8]) {
        var i = from
        let n = bytes.count
        while i < n {
            let c = bytes[i]
            if !isIdentPart(c) { break }
            i += 1
        }
        return (i, Array(bytes[from..<i]))
    }

    private func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == FuncChar.underscore
    }

    private func isIdentPart(_ c: UInt8) -> Bool {
        isIdentStart(c) || isDigit(c) || c == FuncChar.question || c == FuncChar.exclamation
    }

    private func span(_ range: Range<Int>, color: NSColor) -> AttributedSpan {
        AttributedSpan(range: range, attributes: [.foregroundColor: color])
    }
}
