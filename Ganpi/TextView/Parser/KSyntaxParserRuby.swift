//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//  Ruby syntax parser with incremental diff parsing (3/3 分割の第1部)
//  - 可視行のみ attributes を生成（クリック遅延の軽減）
//  - 多行要素（=begin…=end / ヒアドキュメント / 複数行文字列）と /regex/ を「恒久スパン」として保持
//  - 単行の数値/キーワード/行コメント/単行クォート/%文字列は表示要求時にオンデマンドで付与
//  - private の var/let は _ で始める。private func は _ で始めない（規約遵守）
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // MARK: - 内部モデル

    private struct OutlineSpan {
        let startOffset: Int
        var endOffset: Int?
        var item: KOutlineItem
        var parentIndex: Int?
    }

    private struct LineInfo {
        var endState: EndState = .neutral
        var persistentSpans: [KAttributedSpan] = []   // 恒久スパンのみ
        var isDirty: Bool = true
    }

    // 複数行にまたがる継続状態
    private indirect enum EndState: Equatable {
        case neutral
        case inMultiComment               // =begin … =end
        case inStringSingle               // ' ... (継続)
        case inStringDouble               // " ... (継続)
        case inPercentLiteral(closing: UInt8) // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X（必要部分）
        case inHereDoc(term: [UInt8], allowIndent: Bool, interpolation: Bool)
        case inRegexSlash                 // / ... /flags
    }

    // MARK: - プロパティ

    private var _lineStarts: [Int] = []
    private var _lines: [LineInfo] = []

    private var _outlineSpans: [OutlineSpan] = []
    private var _completionLexicon: [Data] = []

    // 一時バッファ（恒久スパン構築用）
    private var _scratchSpans: [KAttributedSpan] = []

    // 配色（仮。テーマ注入可）
    private let _colorBase       = NSColor.labelColor
    private let _colorString     = NSColor.systemRed
    private let _colorComment    = NSColor.systemGreen
    private let _colorKeyword    = NSColor.systemBlue
    private let _colorNumber     = NSColor.systemBlue
    private let _colorVariable   = NSColor.systemBrown

    // キーワード（長さ別）
    private static let _keywordsLen2: [[UInt8]] = [Array("do".utf8), Array("in".utf8), Array("or".utf8), Array("if".utf8)]
    private static let _keywordsLen3: [[UInt8]] = [Array("end".utf8), Array("and".utf8), Array("for".utf8), Array("def".utf8), Array("nil".utf8), Array("not".utf8)]
    private static let _keywordsLen4: [[UInt8]] = [Array("then".utf8), Array("true".utf8), Array("next".utf8), Array("redo".utf8), Array("case".utf8), Array("else".utf8), Array("self".utf8), Array("when".utf8), Array("retry".utf8)]
    private static let _keywordsLen5: [[UInt8]] = [Array("class".utf8), Array("false".utf8), Array("yield".utf8), Array("until".utf8), Array("super".utf8), Array("while".utf8), Array("break".utf8), Array("alias".utf8), Array("begin".utf8), Array("undef".utf8), Array("elsif".utf8)]
    private static let _keywordsLen6: [[UInt8]] = [Array("module".utf8), Array("ensure".utf8), Array("unless".utf8), Array("return".utf8), Array("rescue".utf8)]
    private static let _keywordsLen7: [[UInt8]] = [Array("defined?".utf8)]

    // ストレージ
    let storage: KTextStorageReadable
    init(storage: KTextStorageReadable) { self.storage = storage }

    // MARK: - Protocol basics

    var lineCommentPrefix: String? { "#" }
    var baseTextColor: NSColor { _colorBase }

    // MARK: - ASCII 判定ヘルパ（関数名は説明的に）

    @inline(__always) private func isAsciiDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) private func isAsciiUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    @inline(__always) private func isAsciiLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
    @inline(__always) private func isAsciiAlpha(_ b: UInt8) -> Bool { isAsciiUpper(b) || isAsciiLower(b) }
    @inline(__always) private func isIdentStartAZ_(_ b: UInt8) -> Bool { isAsciiAlpha(b) || b == FuncChar.underscore }
    @inline(__always) private func isIdentPartAZ09_(_ b: UInt8) -> Bool { isIdentStartAZ_(b) || isAsciiDigit(b) }

    // MARK: - 編集通知（差分行だけ dirty に）

    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        let newLineStarts = storage.skeletonString.lineStartIndices
        let newLineCount = max(0, newLineStarts.count - 1)

        if _lineStarts.isEmpty {
            _lineStarts = newLineStarts
            _lines = Array(repeating: LineInfo(), count: newLineCount)
            return
        }

        let oldLineCount = max(0, _lineStarts.count - 1)
        let deltaLines = newLineCount - oldLineCount
        let startLineInNew = lineIndex(in: newLineStarts, atOffset: oldRange.lowerBound)

        if deltaLines > 0 {
            let insertAt = min(max(0, startLineInNew), _lines.count)
            _lines.insert(contentsOf: Array(repeating: LineInfo(), count: deltaLines), at: insertAt)
        } else if deltaLines < 0 {
            let removeAt = min(max(0, startLineInNew), _lines.count)
            let removeCount = min(-deltaLines, max(0, _lines.count - removeAt))
            if removeCount > 0 { _lines.removeSubrange(removeAt ..< removeAt + removeCount) }
        }

        _lineStarts = newLineStarts

        let newUpper = oldRange.lowerBound + max(0, newCount)
        let endLineInNew = lineIndex(in: newLineStarts, atOffset: max(0, min(newUpper, max(storage.count - 1, 0))))
        let loLine = max(0, startLineInNew - 1)
        let hiLine = min(_lines.count, endLineInNew + 2)
        if loLine < hiLine {
            for line in loLine..<hiLine { _lines[line].isDirty = true }
        }
    }

    // MARK: - ensure / parse

    func ensureUpToDate(for range: Range<Int>) {
        syncLineTableIfNeeded()
        let needLines = lineRangeCoveringCharacters(range, paddingLines: 2)
        let anchor = anchorLine(before: needLines.lowerBound)
        parseLines(in: anchor..<needLines.upperBound)
    }

    func parse(range: Range<Int>) {
        syncLineTableIfNeeded()
        let needLines = lineRangeCoveringCharacters(range, paddingLines: 0)
        let anchor = anchorLine(before: needLines.lowerBound)
        parseLines(in: anchor..<needLines.upperBound)
    }

    // MARK: - attributes（恒久スパン + 単行オンデマンド、可視行限定）

    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        if range.isEmpty { return [] }
        ensureUpToDate(for: range)

        let textCount = storage.count
        let lineCount = max(0, _lineStarts.count - 1)
        if textCount == 0 || lineCount == 0 { return [] }

        let loChar = max(0, min(range.lowerBound, textCount - 1))
        let hiProbe = max(0, min(max(range.upperBound - 1, 0), textCount - 1))
        var firstLine = lineIndex(atOffset: loChar)
        var lastLine  = lineIndex(atOffset: hiProbe)
        firstLine = max(0, min(firstLine, lineCount - 1))
        lastLine  = max(0, min(lastLine, lineCount - 1))
        if firstLine > lastLine { return [] }

        var result: [KAttributedSpan] = []
        result.reserveCapacity(64)

        // 1) 恒久スパン
        for li in firstLine...lastLine {
            for span in _lines[li].persistentSpans {
                if span.range.upperBound <= range.lowerBound { continue }
                if span.range.lowerBound >= range.upperBound { break }
                let a = max(span.range.lowerBound, range.lowerBound)
                let b = min(span.range.upperBound, range.upperBound)
                if a < b { result.append(KAttributedSpan(range: a..<b, attributes: span.attributes)) }
            }
        }

        // 2) 単行オンデマンド（恒久スパン除外）
        let skel = storage.skeletonString
        skel.bytes.withUnsafeBufferPointer { whole in
            for li in firstLine...lastLine {
                let start = _lineStarts[li], end = _lineStarts[li + 1]
                let len = end - start
                if len <= 0 { continue }
                let base = whole.baseAddress! + start
                let excluded = _lines[li].persistentSpans.map { $0.range }
                appendOnDemandSingleLine(lineBase: base,
                                         length: len,
                                         documentStartOffset: start,
                                         clip: range,
                                         excluded: excluded,
                                         out: &result)
            }
        }
        return result
    }

    // MARK: - 行テーブル同期・検索

    private func syncLineTableIfNeeded() {
        let currentStarts = storage.skeletonString.lineStartIndices
        let currentCount = max(0, currentStarts.count - 1)
        if _lineStarts.isEmpty {
            _lineStarts = currentStarts
            _lines = Array(repeating: LineInfo(), count: currentCount)
            return
        }
        if currentCount != _lines.count {
            if currentCount > _lines.count {
                _lines.append(contentsOf: Array(repeating: LineInfo(), count: currentCount - _lines.count))
            } else {
                _lines.removeLast(_lines.count - currentCount)
            }
            // 先頭数行は安全側で dirty
            for i in 0..<min(_lines.count, 2) { _lines[i].isDirty = true }
        }
        _lineStarts = currentStarts
    }

    private func lineIndex(atOffset offset: Int) -> Int {
        return lineIndex(in: _lineStarts, atOffset: offset)
    }

    private func lineIndex(in starts: [Int], atOffset offset: Int) -> Int {
        var low = 0, high = max(0, starts.count - 1)
        while low < high {
            let mid = (low + high + 1) >> 1
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func lineRangeCoveringCharacters(_ charRange: Range<Int>, paddingLines: Int) -> Range<Int> {
        let lineTotal = max(0, _lineStarts.count - 1)
        guard lineTotal > 0 else { return 0..<0 }
        let first = lineIndex(atOffset: charRange.lowerBound)
        let last  = lineIndex(atOffset: max(charRange.upperBound - 1, 0))
        let paddedFirst = max(0, first - paddingLines)
        let paddedLast  = min(lineTotal, last + 1 + paddingLines)
        return paddedFirst..<paddedLast
    }

    private func anchorLine(before lineIndex: Int) -> Int {
        guard !_lines.isEmpty else { return 0 }
        var probe = max(0, min(lineIndex, _lines.count - 1))
        probe = max(0, probe - 1)
        while probe > 0 {
            if _lines[probe].endState == .neutral && !_lines[probe].isDirty { return probe }
            if _lines[probe].endState == .neutral && _lines[probe].persistentSpans.isEmpty { return probe }
            probe -= 1
        }
        return 0
    }

}

// === KSyntaxParserRuby.swift 第2部（クラス定義の続き） ===

extension KSyntaxParserRuby {

    // MARK: - 行パース（dirty 行を優先）

    fileprivate func parseLines(in candidateLines: Range<Int>) {
        let lineCount = max(0, _lineStarts.count - 1)
        if _lines.count != lineCount {
            _lines = Array(repeating: LineInfo(), count: lineCount)
        }
        if lineCount == 0 { return }

        let lo = max(0, min(candidateLines.lowerBound, lineCount))
        let hi = max(lo, min(candidateLines.upperBound, lineCount))
        if lo >= hi { return }

        let skeleton = storage.skeletonString
        var carryState: EndState = (lo > 0) ? _lines[lo - 1].endState : .neutral

        skeleton.bytes.withUnsafeBufferPointer { whole in
            let documentBytes = whole.baseAddress!
            for lineIndex in lo..<hi {
                if !_lines[lineIndex].isDirty && _lines[lineIndex].endState == carryState {
                    carryState = _lines[lineIndex].endState
                    continue
                }

                let startOffset = _lineStarts[lineIndex]
                let endOffset   = _lineStarts[lineIndex + 1]
                let length      = endOffset - startOffset
                let lineBase    = documentBytes + startOffset

                let (newState, spans) = lexOneLine(base: lineBase,
                                                   count: length,
                                                   startOffset: startOffset,
                                                   initial: carryState)
                _lines[lineIndex].endState       = newState
                _lines[lineIndex].persistentSpans = spans
                _lines[lineIndex].isDirty        = false
                carryState = newState
            }
        }
    }

    // MARK: - 1行字句解析（恒久スパン：複数行 + /regex/）

    private func lexOneLine(base: UnsafePointer<UInt8>, count: Int, startOffset: Int, initial: EndState)
    -> (EndState, [KAttributedSpan]) {
        _scratchSpans.removeAll(keepingCapacity: true)
        var state = initial
        var indexInLine = 0
        let lineLength = count

        // --- 継続状態の処理（行頭） ---
        if state == .inMultiComment {
            if matchLineHead(base, lineLength, token: "=end") {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: lineLength, color: _colorComment)
                return (.neutral, _scratchSpans)
            } else {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: lineLength, color: _colorComment)
                return (.inMultiComment, _scratchSpans)
            }
        }
        if state == .inStringSingle {
            let (closed, localEnd) = scanQuotedNoInterpolation(base, lineLength, from: 0, quote: FuncChar.singleQuote)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: localEnd, color: _colorString)
            if closed { indexInLine = localEnd; state = .neutral } else { return (.inStringSingle, _scratchSpans) }
        }
        if state == .inStringDouble {
            let (closed, localEnd) = scanQuotedNoInterpolation(base, lineLength, from: 0, quote: FuncChar.doubleQuote)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: localEnd, color: _colorString)
            if closed { indexInLine = localEnd; state = .neutral } else { return (.inStringDouble, _scratchSpans) }
        }
        if case let .inPercentLiteral(closing) = state {
            let scan = scanUntil(base, lineLength, from: 0, closing: closing)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: scan.end, color: _colorString)
            if scan.closed { indexInLine = scan.end; state = .neutral } else { return (.inPercentLiteral(closing: closing), _scratchSpans) }
        }
        if case let .inHereDoc(term, allowIndent, interpolation) = state {
            let endAt = matchHereDocTerm(base, lineLength, term: term, allowIndent: allowIndent)
            if endAt >= 0 {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: endAt, color: _colorString)
                indexInLine = endAt; state = .neutral
            } else {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: lineLength, color: _colorString)
                return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interpolation), _scratchSpans)
            }
        }
        if state == .inRegexSlash {
            let rx = scanRegexSlash(base, lineLength, from: 0)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: rx.closedTo, color: _colorString)
            if rx.closed { state = .neutral; indexInLine = rx.closedTo } else { return (.inRegexSlash, _scratchSpans) }
        }

        // "=begin" 行頭
        if matchLineHead(base, lineLength, token: "=begin") {
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: lineLength, color: _colorComment)
            return (.inMultiComment, _scratchSpans)
        }

        // --- 通常走査 ---
        while indexInLine < lineLength {
            let ch = base[indexInLine]

            // 行コメント（#以降はオンデマンドでも塗るが、恒久では保持しない）
            if ch == FuncChar.numeric { break }

            // 単引号 / 双引号（恒久扱い：改行で閉じない場合があるため）
            if ch == FuncChar.singleQuote {
                let (closed, endLocal) = scanQuotedNoInterpolation(base, lineLength, from: indexInLine, quote: FuncChar.singleQuote)
                appendSpan(documentStart: startOffset, fromLocal: indexInLine, toLocal: endLocal, color: _colorString)
                if closed { indexInLine = endLocal; continue } else { return (.inStringSingle, _scratchSpans) }
            }
            if ch == FuncChar.doubleQuote {
                let (closed, endLocal) = scanQuotedNoInterpolation(base, lineLength, from: indexInLine, quote: FuncChar.doubleQuote)
                appendSpan(documentStart: startOffset, fromLocal: indexInLine, toLocal: endLocal, color: _colorString)
                if closed { indexInLine = endLocal; continue } else { return (.inStringDouble, _scratchSpans) }
            }

            // heredoc ヘッダ
            if ch == FuncChar.lt, indexInLine + 1 < lineLength, base[indexInLine + 1] == FuncChar.lt {
                let (ok, _, term, allowIndent, interp) = parseHereDocHead(base, lineLength, from: indexInLine)
                if ok {
                    appendSpan(documentStart: startOffset, fromLocal: indexInLine, toLocal: lineLength, color: _colorString)
                    return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interp), _scratchSpans)
                }
            }

            // % 系（regex を含む）
            if ch == FuncChar.percent, indexInLine + 2 < lineLength {
                let typeCode = base[indexInLine + 1]
                let typeLower = isAsciiUpper(typeCode) ? (typeCode &+ 0x20) : typeCode
                let delimiter = base[indexInLine + 2]
                let isRegex = (typeLower == 0x72) // 'r'
                let isStringLike = (typeLower == 0x71 || typeLower == 0x77 || typeLower == 0x69 ||
                                    typeLower == 0x73 || typeLower == 0x78) // q,w,i,s,x
                if isRegex || isStringLike {
                    let closing = pairedClosing(for: delimiter)
                    let scan = scanUntil(base, lineLength, from: indexInLine + 3, closing: closing)
                    appendSpan(documentStart: startOffset, fromLocal: indexInLine, toLocal: scan.end, color: _colorString)
                    if scan.closed { indexInLine = scan.end; continue }
                    return (.inPercentLiteral(closing: closing), _scratchSpans)
                }
            }

            // /regex/ 文脈
            if ch == FuncChar.slash, isRegexLikelyAfterSlash(base, lineLength, at: indexInLine) {
                let rx = scanRegexSlash(base, lineLength, from: indexInLine)
                appendSpan(documentStart: startOffset, fromLocal: indexInLine, toLocal: rx.closedTo, color: _colorString)
                indexInLine = rx.closedTo
                if rx.closed { continue } else { return (.inRegexSlash, _scratchSpans) }
            }

            // 以下は恒久スパンは作らず、字句境界だけ進める（オンデマンドで塗る）
            if ch == FuncChar.dollar { let end = scanGlobalVar(base, lineLength, from: indexInLine); indexInLine = end; continue }
            if ch == FuncChar.at {
                let end = scanAtVar(base, lineLength, from: indexInLine)
                if end > indexInLine { indexInLine = end; continue }
            }
            if ch == FuncChar.colon {
                let end = scanSymbolLiteral(base, lineLength, from: indexInLine)
                if end > indexInLine {
                    // :symbol / :"..." は文字列色（ただし恒久保持はしない）
                    appendSpan(documentStart: startOffset, fromLocal: indexInLine, toLocal: end, color: _colorString)
                    indexInLine = end; continue
                }
            }
            if ch == FuncChar.minus || isAsciiDigit(ch) {
                let end = scanNumber(base, lineLength, from: indexInLine)
                indexInLine = end; continue
            }
            if isIdentStartAZ_(ch) {
                let end = scanIdentEnd(base, lineLength, from: indexInLine)
                indexInLine = end; continue
            }

            indexInLine += 1
        }

        return (state, _scratchSpans)
    }

    // MARK: - 単行オンデマンド着色

    // 単行オンデマンド着色：恒久スパン(excluded)上は一切塗らない
    fileprivate func appendOnDemandSingleLine(lineBase: UnsafePointer<UInt8>,
                                              length: Int,
                                              documentStartOffset: Int,
                                              clip: Range<Int>,
                                              excluded: [Range<Int>],
                                              out: inout [KAttributedSpan]) {
        var localIndex = 0
        let lineEnd = length

        // 除外区間（恒久スパン）をマージ
        let mergedExcluded: [Range<Int>] = {
            if excluded.isEmpty { return [] }
            let sorted = excluded.sorted { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            var cur = sorted[0]
            for r in sorted.dropFirst() {
                if r.lowerBound <= cur.upperBound { cur = cur.lowerBound ..< max(cur.upperBound, r.upperBound) }
                else { merged.append(cur); cur = r }
            }
            merged.append(cur)
            return merged
        }()

        @inline(__always) func skipIfExcluded(absPos: Int) -> Int? {
            for r in mergedExcluded {
                if absPos < r.lowerBound { break }
                if r.contains(absPos) { return r.upperBound - documentStartOffset }
            }
            return nil
        }

        @inline(__always) func clipped(_ a: Int, _ b: Int) -> Range<Int>? {
            let lo = max(a, clip.lowerBound)
            let hi = min(b, clip.upperBound)
            return (lo < hi) ? (lo..<hi) : nil
        }

        while localIndex < lineEnd {
            // 恒久スパン上はスキップ
            if let jump = skipIfExcluded(absPos: documentStartOffset + localIndex) {
                localIndex = max(localIndex, jump)
                continue
            }

            let ch = lineBase[localIndex]

            // 行コメント：'#' は恒久スパン外でのみ有効
            if ch == FuncChar.numeric {
                let absStart = documentStartOffset + localIndex
                var absEnd = documentStartOffset + lineEnd
                for r in mergedExcluded where r.lowerBound >= absStart {
                    absEnd = r.lowerBound
                    break
                }
                if absEnd > absStart, let rng = clipped(absStart, absEnd) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: _colorComment]))
                }
                break
            }

            // 単行の '...' / "..."
            if ch == FuncChar.singleQuote || ch == FuncChar.doubleQuote {
                let (closed, endLocal) = scanQuotedNoInterpolation(lineBase, lineEnd, from: localIndex, quote: ch)
                if closed, let rng = clipped(documentStartOffset + localIndex, documentStartOffset + endLocal) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: _colorString]))
                    localIndex = endLocal; continue
                }
            }

            // 単行の %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X（regex %r は恒久スパン側で処理）
            if ch == FuncChar.percent, localIndex + 2 < lineEnd {
                let typeCode = lineBase[localIndex + 1]
                let typeLower = isAsciiUpper(typeCode) ? (typeCode &+ 0x20) : typeCode
                let delim = lineBase[localIndex + 2]
                let isStringLike = (typeLower == 0x71 || typeLower == 0x77 || typeLower == 0x69 ||
                                    typeLower == 0x73 || typeLower == 0x78)
                if isStringLike {
                    let closing = pairedClosing(for: delim)
                    let scan = scanUntil(lineBase, lineEnd, from: localIndex + 3, closing: closing)
                    if scan.closed, let rr = clipped(documentStartOffset + localIndex, documentStartOffset + scan.end) {
                        out.append(KAttributedSpan(range: rr, attributes: [.foregroundColor: _colorString]))
                        localIndex = scan.end; continue
                    }
                }
            }

            // 数値
            if ch == FuncChar.minus || isAsciiDigit(ch) {
                let end = scanNumber(lineBase, lineEnd, from: localIndex)
                if end > localIndex, let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: _colorNumber]))
                }
                localIndex = max(end, localIndex + 1); continue
            }

            // キーワード（左境界チェック付き）
            if isIdentStartAZ_(ch) {
                let end = scanIdentEnd(lineBase, lineEnd, from: localIndex)
                if end > localIndex,
                   isKeywordToken(lineBase, lineEnd, start: localIndex, end: end, documentStart: documentStartOffset),
                   let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: _colorKeyword]))
                }
                localIndex = end; continue
            }

            localIndex += 1
        }
    }

    // MARK: - 低レベルスキャナ群

    @inline(__always) private func matchLineHead(_ base: UnsafePointer<UInt8>, _ n: Int, token: String) -> Bool {
        if n == 0 { return false }
        let u = Array(token.utf8)
        if n < u.count { return false }
        for i in 0..<u.count where base[i] != u[i] { return false }
        return true
    }

    private struct ScanUntilResult { let closed: Bool; let end: Int }

    @inline(__always) private func scanUntil(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, closing: UInt8) -> ScanUntilResult {
        var i = from
        while i < n {
            if base[i] == closing {
                var esc = 0, k = i - 1
                while k >= 0, base[k] == FuncChar.backSlash { esc += 1; k -= 1 }
                if esc % 2 == 0 { return ScanUntilResult(closed: true, end: i + 1) }
            }
            i += 1
        }
        return ScanUntilResult(closed: false, end: n)
    }

    @inline(__always) private func scanQuotedNoInterpolation(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int, quote: UInt8) -> (Bool, Int) {
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
                    // フラグ（i,m,x,o,n,e,u,s,d…）をざっくり読み飛ばす
                    while i < n {
                        let f = base[i]
                        if isAsciiAlpha(f) { i += 1 } else { break }
                    }
                    return RegexScanResult(closed: true, closedTo: i)
                }
            }
            i += 1
        }
        return RegexScanResult(closed: false, closedTo: n)
    }

    @inline(__always) private func pairedClosing(for c: UInt8) -> UInt8 {
        switch c {
        case FuncChar.leftParen:   return FuncChar.rightParen
        case FuncChar.leftBracket: return FuncChar.rightBracket
        case FuncChar.leftBrace:   return FuncChar.rightBrace
        case FuncChar.lt:          return FuncChar.gt
        default:                   return c
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

        let head = base[i]
        let isQuoted = (head == FuncChar.singleQuote || head == FuncChar.doubleQuote)
        let isIdent0 = (head == FuncChar.underscore) || isAsciiAlpha(head)
        if !(isIdent0 || isQuoted) { return (false, from, [], false, false) }

        var interpolation = true
        var term: [UInt8] = []

        if isQuoted {
            let q = base[i]; interpolation = (q == FuncChar.doubleQuote); i += 1
            let start = i
            while i < n, base[i] != q { i += 1 }
            if i >= n { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + start, count: i - start))
            i += 1
            for b in term {
                let ok = (b == FuncChar.underscore) || isAsciiAlpha(b) || isAsciiDigit(b)
                if !ok { return (false, from, [], false, false) }
            }
        } else {
            let start = i
            while i < n {
                let c = base[i]
                let ok = (c == FuncChar.underscore) || isAsciiAlpha(c) || isAsciiDigit(c)
                if !ok { break }
                i += 1
            }
            if i == start { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + start, count: i - start))

            var hasUpper = false, allUpperAZ09_ = true
            for b in term {
                if isAsciiUpper(b) { hasUpper = true }
                if !(isAsciiUpper(b) || isAsciiDigit(b) || b == FuncChar.underscore) {
                    allUpperAZ09_ = false; break
                }
            }
            if !(hasUpper && allUpperAZ09_) { return (false, from, [], false, false) }
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

    // 区切り・キーワード

    @inline(__always) private func isDelimiter(_ c: UInt8) -> Bool {
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

    // キーワード判定：左境界もチェックし、コロン直後は無効化
    private func isKeywordToken(_ base: UnsafePointer<UInt8>, _ n: Int,
                                start: Int, end: Int, documentStart: Int) -> Bool {
        // 右側は非単語であること（既存）
        if end < n && !isDelimiter(base[end]) { return false }

        // 左側：先頭でないなら「非単語 or 改行」かつ「直前が ':' ではない」ことを要求
        if start > 0 {
            let prev = base[start - 1]
            // 区切りでなければ（例: foo.then）アウト
            if !isDelimiter(prev) { return false }
            // コロン直後（:then / ::end など）はアウト
            if prev == FuncChar.colon { return false }
        }

        let tokenLength = end - start
        if tokenLength < 2 || tokenLength > 7 { return false }

        let pos = documentStart + start
        let skel = storage.skeletonString

        @inline(__always) func match(_ pool: [[UInt8]]) -> Bool {
            for w in pool { if skel.matchesKeyword(at: pos, word: w) { return true } }
            return false
        }

        switch tokenLength {
        case 2:  return match(Self._keywordsLen2)
        case 3:  return match(Self._keywordsLen3)
        case 4:  return match(Self._keywordsLen4)
        case 5:  return match(Self._keywordsLen5)
        case 6:  return match(Self._keywordsLen6)
        case 7:  return match(Self._keywordsLen7)
        default: return false
        }
    }

    // 変数・数値・識別子スキャナ

    private func scanGlobalVar(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from + 1
        if i >= n { return from + 1 }
        let c = base[i]
        if c == FuncChar.minus {
            if i + 1 < n { i += 2; return i }
            return i + 1
        }
        if isAsciiDigit(c) {
            i += 1
            while i < n, isAsciiDigit(base[i]) { i += 1 }
            return i
        }
        if isIdentStartAZ_(c) {
            i += 1
            while i < n {
                let b = base[i]
                if isIdentStartAZ_(b) || isAsciiDigit(b) || b == FuncChar.question || b == FuncChar.exclamation { i += 1 } else { break }
            }
            return i
        }
        return i + 1
    }

    private func scanAtVar(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        if i + 1 < n, base[i] == FuncChar.at, base[i + 1] == FuncChar.at {
            i += 2
            if i < n, isIdentStartAZ_(base[i]) {
                i += 1
                while i < n {
                    let b = base[i]
                    if isIdentStartAZ_(b) || isAsciiDigit(b) || b == FuncChar.question || b == FuncChar.exclamation { i += 1 } else { break }
                }
                return i
            }
            return from
        } else if base[i] == FuncChar.at {
            i += 1
            if i < n, isIdentStartAZ_(base[i]) {
                i += 1
                while i < n {
                    let b = base[i]
                    if isIdentStartAZ_(b) || isAsciiDigit(b) || b == FuncChar.question || b == FuncChar.exclamation { i += 1 } else { break }
                }
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
            let (closed, end) = scanQuotedNoInterpolation(base, n, from: i, quote: c)
            return closed ? end : n
        } else if isIdentStartAZ_(c) {
            var j = i + 1
            while j < n {
                let b = base[j]
                if isIdentStartAZ_(b) || isAsciiDigit(b) || b == FuncChar.question || b == FuncChar.exclamation { j += 1 } else { break }
            }
            return j
        }
        return from
    }

    private func scanNumber(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        if i < n, base[i] == FuncChar.minus { i += 1 }
        while i < n {
            let c = base[i]
            if !(isAsciiDigit(c) || c == FuncChar.period || isAsciiAlpha(c)) { break }
            i += 1
        }
        return i
    }

    private func scanIdentEnd(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        while i < n {
            let c = base[i]
            let alpha = isAsciiAlpha(c) || c == FuncChar.underscore
            let digit = isAsciiDigit(c)
            if !(alpha || digit || c == FuncChar.exclamation || c == FuncChar.question) { break }
            i += 1
        }
        return i
    }

    // /regex/ の直前文脈（超簡易）
    private func isRegexLikelyAfterSlash(_ base: UnsafePointer<UInt8>, _ n: Int, at i: Int) -> Bool {
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
        if isIdentStartAZ_(base[j]) || isAsciiDigit(base[j]) { return false }
        if base[j] == FuncChar.rightParen || base[j] == FuncChar.rightBracket || base[j] == FuncChar.rightBrace { return false }
        return true
    }

    // スパン追加（恒久スパン用）
    private func appendSpan(documentStart start: Int, fromLocal lo: Int, toLocal hi: Int, color: NSColor) {
        if lo < hi {
            _scratchSpans.append(KAttributedSpan(range: start + lo ..< start + hi,
                                                 attributes: [.foregroundColor: color]))
        }
    }
}

// === KSyntaxParserRuby.swift 第3部（クラス定義の続き） ===

extension KSyntaxParserRuby {

    // MARK: - wordRange（Ruby らしい拡張：@/@@/$, :symbol, 数値の - 接頭 等）

    func wordRange(at index: Int) -> Range<Int>? {
        let total = storage.count
        if total == 0 { return nil }

        let skeleton = storage.skeletonString
        return skeleton.bytes.withUnsafeBufferPointer { whole -> Range<Int>? in
            let base = whole.baseAddress!
            var pivot = max(0, min(index, total - 1))

            func isWordish(_ c: UInt8) -> Bool {
                c == FuncChar.dollar || c == FuncChar.at || c == FuncChar.colon ||
                c == FuncChar.minus || isAsciiAlpha(c) || isAsciiDigit(c) || c == FuncChar.underscore
            }
            if !isWordish(base[pivot]) && pivot > 0 && isWordish(base[pivot - 1]) { pivot -= 1 }
            if !isWordish(base[pivot]) { return nil }

            // "::" 単体
            if base[pivot] == FuncChar.colon || (pivot > 0 && base[pivot - 1] == FuncChar.colon) {
                let first = (base[pivot] == FuncChar.colon && pivot > 0 && base[pivot - 1] == FuncChar.colon) ? (pivot - 1) : pivot
                if first + 1 < total, base[first] == FuncChar.colon, base[first + 1] == FuncChar.colon {
                    return first..<(first + 2)
                }
            }

            // 数値（- 接頭と小数・指数表記の断片を大雑把に）
            func expandNumber(from p: Int) -> Range<Int>? {
                var lo = p, hi = p
                if !isAsciiDigit(base[p]) {
                    if p + 1 < total, isAsciiDigit(base[p + 1]) { lo = p + 1; hi = lo }
                    else if base[p] == FuncChar.minus, p + 1 < total, isAsciiDigit(base[p + 1]) { lo = p; hi = p + 1 }
                    else { return nil }
                }
                while lo > 0, isAsciiDigit(base[lo - 1]) { lo -= 1 }
                if lo > 1, base[lo - 1] == FuncChar.minus,
                   !((lo - 2) >= 0 && (isAsciiDigit(base[lo - 2]) || isAsciiAlpha(base[lo - 2]) || base[lo - 2] == FuncChar.underscore)) {
                    lo -= 1
                }
                while hi < total {
                    let c = base[hi]
                    if isAsciiDigit(c) || c == FuncChar.period || isAsciiAlpha(c) { hi += 1 } else { break }
                }
                return lo..<hi
            }
            if let number = expandNumber(from: pivot) { return number }

            // 識別子
            func isIdentPartRuby(_ c: UInt8) -> Bool {
                isIdentStartAZ_(c) || isAsciiDigit(c) || c == FuncChar.question || c == FuncChar.exclamation
            }
            var lo = pivot, hi = pivot
            if !isIdentPartRuby(base[pivot]) && pivot + 1 < total && isIdentPartRuby(base[pivot + 1]) {
                lo = pivot + 1; hi = lo
            }
            while lo > 0, isIdentPartRuby(base[lo - 1]) { lo -= 1 }
            while hi < total, isIdentPartRuby(base[hi]) { hi += 1 }
            if hi < total, (base[hi] == FuncChar.question || base[hi] == FuncChar.exclamation) { hi += 1 }

            // 前置 @/@@/$ と :symbol の先頭コロン（単コロンのみ）
            if lo >= 2, base[lo - 2] == FuncChar.at, base[lo - 1] == FuncChar.at { lo -= 2 }
            else if lo >= 1, base[lo - 1] == FuncChar.at { lo -= 1 }
            else if lo >= 1, base[lo - 1] == FuncChar.dollar { lo -= 1 }
            if lo >= 1, base[lo - 1] == FuncChar.colon, !(lo >= 2 && base[lo - 2] == FuncChar.colon) { lo -= 1 }

            return lo..<hi
        }
    }

    // MARK: - アウトライン（簡易：class/module/def + end）

    func outline(in range: Range<Int>? = nil) -> [KOutlineItem] {
        buildOutlineAll()
        guard let r = range else { return _outlineSpans.map { $0.item } }
        return _outlineSpans.compactMap {
            let a = $0.item.nameRange.lowerBound
            let b = $0.item.nameRange.upperBound
            return (b <= r.lowerBound || a >= r.upperBound) ? nil : $0.item
        }
    }

    func currentContext(at index: Int) -> [KOutlineItem] {
        buildOutlineAll()
        var best: Int? = nil
        for (i, sp) in _outlineSpans.enumerated() {
            let e = sp.endOffset ?? Int.max
            if sp.startOffset <= index && index < e {
                if let b = best {
                    let bS = _outlineSpans[b].startOffset
                    let bE = _outlineSpans[b].endOffset ?? Int.max
                    if (sp.startOffset >= bS) && (e <= bE) { best = i }
                } else { best = i }
            }
        }
        guard let leaf = best else { return [] }
        var chain: [KOutlineItem] = []
        var cur: Int? = leaf
        while let i = cur {
            chain.append(_outlineSpans[i].item)
            cur = _outlineSpans[i].parentIndex
        }
        return chain.reversed()
    }

    private func buildOutlineAll() {
        _outlineSpans.removeAll(keepingCapacity: true)
        let nLines = max(0, _lineStarts.count - 1)
        if nLines == 0 { return }

        let skeleton = storage.skeletonString
        skeleton.bytes.withUnsafeBufferPointer { whole in
            let base = whole.baseAddress!

            struct Frame { let kind: KOutlineItem.Kind; let spanIndex: Int; let parent: Int? }
            var stack: [Frame] = []

            for lineIndex in 0..<nLines {
                let lo = _lineStarts[lineIndex]
                let hi = _lineStarts[lineIndex + 1]
                let len = hi - lo
                if len <= 0 { continue }
                let line = base + lo

                var head = 0
                while head < len, (line[head] == FuncChar.space || line[head] == FuncChar.tab) { head += 1 }
                if head >= len { continue }
                if line[head] == FuncChar.numeric { continue }
                if matchLineHead(line + head, len - head, token: "=begin") { continue }
                if matchLineHead(line + head, len - head, token: "=end") {
                    _ = stack.popLast()
                    continue
                }

                func extractName(_ from: Int, _ L: Int, baseOffset: Int) -> (text: String, range: Range<Int>) {
                    var i = from
                    while i < L, (line[i] == FuncChar.space || line[i] == FuncChar.tab) { i += 1 }
                    let start = i
                    while i < L, !isDelimiter(line[i]) { i += 1 }
                    let text = String(decoding: UnsafeBufferPointer(start: line + start, count: i - start), as: UTF8.self)
                    return (text, baseOffset + start ..< baseOffset + i)
                }

                // def
                if head + 3 <= len, matchLineHead(line + head, len - head, token: "def") {
                    let name = extractName(head + 3, len, baseOffset: lo + head + 3)
                    let item = KOutlineItem(kind: .method, name: name.text, containerPath: [],
                                            nameRange: name.range, headerRange: lo..<hi,
                                            bodyRange: nil, lineIndex: lineIndex, level: stack.count, isSingleton: false)
                    let idx = _outlineSpans.count
                    _outlineSpans.append(OutlineSpan(startOffset: lo + head, endOffset: nil, item: item, parentIndex: stack.last?.spanIndex))
                    stack.append(Frame(kind: .method, spanIndex: idx, parent: stack.last?.spanIndex))
                    continue
                }

                // class
                if head + 5 <= len, matchLineHead(line + head, len - head, token: "class") {
                    let name = extractName(head + 5, len, baseOffset: lo + head + 5)
                    let item = KOutlineItem(kind: .class, name: name.text, containerPath: [],
                                            nameRange: name.range, headerRange: lo..<hi,
                                            bodyRange: nil, lineIndex: lineIndex, level: stack.count, isSingleton: false)
                    let idx = _outlineSpans.count
                    _outlineSpans.append(OutlineSpan(startOffset: lo + head, endOffset: nil, item: item, parentIndex: stack.last?.spanIndex))
                    stack.append(Frame(kind: .class, spanIndex: idx, parent: stack.last?.spanIndex))
                    continue
                }

                // module
                if head + 6 <= len, matchLineHead(line + head, len - head, token: "module") {
                    let name = extractName(head + 6, len, baseOffset: lo + head + 6)
                    let item = KOutlineItem(kind: .module, name: name.text, containerPath: [],
                                            nameRange: name.range, headerRange: lo..<hi,
                                            bodyRange: nil, lineIndex: lineIndex, level: stack.count, isSingleton: false)
                    let idx = _outlineSpans.count
                    _outlineSpans.append(OutlineSpan(startOffset: lo + head, endOffset: nil, item: item, parentIndex: stack.last?.spanIndex))
                    stack.append(Frame(kind: .module, spanIndex: idx, parent: stack.last?.spanIndex))
                    continue
                }

                // end
                if head + 3 <= len, matchLineHead(line + head, len - head, token: "end") {
                    if let top = stack.popLast() {
                        _outlineSpans[top.spanIndex].endOffset = lo + head
                    }
                    continue
                }
            }
        }
    }

    // MARK: - Completion（語彙のスナップショット）

    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?) {
        let bytes = storage.skeletonString.bytes
        var unique = Set<Data>()
        var i = 0
        let n = bytes.count

        @inline(__always) func isHead(_ b: UInt8) -> Bool { b == FuncChar.at || b == FuncChar.dollar || b == FuncChar.underscore || isAsciiAlpha(b) }
        @inline(__always) func isBody(_ b: UInt8) -> Bool { isAsciiDigit(b) || b == FuncChar.underscore || isAsciiAlpha(b) }

        while i < n {
            let b = bytes[i]
            if isHead(b) {
                let s = i; i += 1
                while i < n, isBody(bytes[i]) { i += 1 }
                if i < n, (bytes[i] == FuncChar.exclamation || bytes[i] == FuncChar.question) { i += 1 }
                unique.insert(Data(bytes[s..<i]))
            } else { i += 1 }
        }
        _completionLexicon = unique.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry] {
        guard !prefix.isEmpty, let key = prefix.data(using: .utf8) else { return [] }

        func lowerBound(_ a: [Data], _ k: Data) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if a[mid].lexicographicallyPrecedes(k) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func upperBound(_ a: [Data], _ k: Data) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if k.lexicographicallyPrecedes(a[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }

        let lo = lowerBound(_completionLexicon, key)
        let hi = upperBound(_completionLexicon, key)
        if lo >= hi { return [] }

        var out: [KCompletionEntry] = []
        var i = lo
        while i < hi && out.count < limit {
            if let s = String(data: _completionLexicon[i], encoding: .utf8), s != prefix {
                out.append(KCompletionEntry(text: s, kind: .keyword, detail: nil, score: 0))
            }
            i += 1
        }
        return out
    }
}
