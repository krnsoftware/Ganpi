//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParser {

    private enum EndState: Equatable {
        case neutral
        case inMultiComment
    }

    private struct LineInfo {
        var endState: EndState
    }

    private var _lines: [LineInfo] = []

    private let _commentBeginBytes = Array("=begin".utf8)
    private let _commentEndBytes   = Array("=end".utf8)

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .ruby)
    }

    override func ensureUpToDate(for range: Range<Int>) {
        syncLineBuffer(lines: &_lines) { LineInfo(endState: .neutral) }
        guard !_lines.isEmpty else { return }

        let skeleton = storage.skeletonString
        let firstLine = skeleton.lineIndex(at: range.lowerBound)

        // 直前行から再評価（=begin の影響を拾う）
        let startLine = max(0, firstLine - 1)
        scanFrom(line: startLine)
    }

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        // 前提：range は必ず 1 行内
        let skeleton = storage.skeletonString
        syncLineBuffer(lines: &_lines) { LineInfo(endState: .neutral) }
        guard !_lines.isEmpty else { return [] }

        let lineIndex = skeleton.lineIndex(at: range.lowerBound)
        if lineIndex < 0 || lineIndex >= _lines.count { return [] }

        let lineRange = skeleton.lineRange(at: lineIndex)

        let localRange =
            max(range.lowerBound, lineRange.lowerBound)
            ..< min(range.upperBound, lineRange.upperBound)

        if localRange.isEmpty { return [] }

        let stateAtLineStart: EndState =
            (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral

        let isBegin = isLineHeadDirective(_commentBeginBytes, lineRange: lineRange, skeleton: skeleton)

        if stateAtLineStart == .inMultiComment || isBegin {
            return [
                KAttributedSpan(
                    range: localRange,
                    attributes: [.foregroundColor: color(.comment)]
                )
            ]
        }

        return []
    }

    // MARK: - Private

    private func scanFrom(line startLine: Int) {
        let skeleton = storage.skeletonString

        var state: EndState =
            (startLine > 0) ? _lines[startLine - 1].endState : .neutral

        for line in startLine..<_lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let newState = scanOneLine(lineRange: lineRange, initial: state, skeleton: skeleton)

            if _lines[line].endState == newState {
                // 状態が変わらないなら以降も変わらない前提で打ち切り
                break
            }

            _lines[line].endState = newState
            state = newState
        }
    }

    private func scanOneLine(
        lineRange: Range<Int>,
        initial: EndState,
        skeleton: KSkeletonStringInUTF8
    ) -> EndState {

        switch initial {
        case .inMultiComment:
            // =end 行自体はコメント色、endState は neutral に戻す
            if isLineHeadDirective(_commentEndBytes, lineRange: lineRange, skeleton: skeleton) {
                return .neutral
            }
            return .inMultiComment

        case .neutral:
            if isLineHeadDirective(_commentBeginBytes, lineRange: lineRange, skeleton: skeleton) {
                return .inMultiComment
            }
            return .neutral
        }
    }

    // token が「行頭にあり、かつ token 直後が空白(tab含む) または行末」なら true
    // (=beginx などの誤検出を避けるための最小判定)
    private func isLineHeadDirective(
        _ token: [UInt8],
        lineRange: Range<Int>,
        skeleton: KSkeletonStringInUTF8
    ) -> Bool {
        let start = lineRange.lowerBound
        let end = start + token.count
        if end > lineRange.upperBound { return false }

        if !skeleton.matchesPrefix(token, at: start) { return false }

        if end == lineRange.upperBound { return true }

        let next = skeleton[end]
        return next == FuncChar.space || next == FuncChar.tab
    }
}






/*
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
        var persistentSpans: [KAttributedSpan] = []   // 恒久スパン（色つき）
        var persistentRanges: [Range<Int>] = []       // ↑のrangeだけキャッシュ
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
    private var _completionLexicon: [[UInt8]] = []
    
    // 一時バッファ（恒久スパン構築用）
    private var _scratchSpans: [KAttributedSpan] = []

    // 配色
    private var _theme: [KFunctionalColor: NSColor] = [:]
    @inline(__always) private func color(_ role: KFunctionalColor) -> NSColor {
        _theme[role] ?? _theme[.base] ?? NSColor.labelColor
    }

    // ソート済みのキーワード（UTF-8バイト列）。辞書は使わずフラット配列だけを持つ。
    private var _keywordsFlat: [[UInt8]] = []

    // デフォルト語彙（[String] で内装し、自分で setKeywords() で取り込む）
    private static let _defaultKeywords: [String] = [
        "do","in","or","if",
        "end","and","for","def","nil","not",
        "then","true","next","redo","case","else","self","when","retry",
        "class","false","yield","until","super","while","break","alias","begin","undef","elsif",
        "module","ensure","unless","return","rescue",
        "defined?"
    ]

    // ストレージ
    let storage: KTextStorageReadable
    
    
    var type: KSyntaxType { .ruby }
    
    init(storage: KTextStorageReadable) {
        self.storage = storage
        setKeywords(Self._defaultKeywords)
        
        reloadTheme()
    }
    
    func reloadTheme() {
        let prefs = KPreference.shared
        var theme:[KFunctionalColor: NSColor] = [:]
        theme[.base] = prefs.color(.parserColorText, lang: .ruby)
        theme[.background] = prefs.color(.parserColorBackground, lang: .ruby)
        theme[.comment] = prefs.color(.parserColorComment, lang: .ruby)
        theme[.string] = prefs.color(.parserColorLiteral, lang: .ruby)
        theme[.keyword] = prefs.color(.parserColorKeyword, lang: .ruby)
        theme[.variable] = prefs.color(.parserColorVariable, lang: .ruby)
        theme[.number] = prefs.color(.parserColorNumeric, lang: .ruby)
        setTheme(theme)
    }

    // MARK: - Protocol basics

    var lineCommentPrefix: String? { "#" }
    var baseTextColor: NSColor { color(.base) }
    var backgroundColor: NSColor { color(.background) }

    // MARK: - ASCII 判定ヘルパ（関数名は説明的に）
/*
    @inline(__always) private func isAsciiDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) private func isAsciiUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    @inline(__always) private func isAsciiLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
    @inline(__always) private func isAsciiAlpha(_ b: UInt8) -> Bool { isAsciiUpper(b) || isAsciiLower(b) }
    @inline(__always) private func isIdentStartAZ_(_ b: UInt8) -> Bool { isAsciiAlpha(b) || b == FuncChar.underscore }
    @inline(__always) private func isIdentPartAZ09_(_ b: UInt8) -> Bool { isIdentStartAZ_(b) || isAsciiDigit(b) }*/

    // MARK: - 編集通知（差分行だけ dirty に）

    // 編集通知：後続の恒久スパン位置をΔだけ即時補正し、編集行以降をdirty化
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        let delta = newCount - (oldRange.upperBound - oldRange.lowerBound)

        let newLineStarts = storage.skeletonString.lineStartIndices
        let newLineCount = max(0, newLineStarts.count - 1)

        if _lines.count != newLineCount {
            var resized = Array(repeating: LineInfo(), count: newLineCount)
            let keep = min(_lines.count, newLineCount)
            if keep > 0 { resized.replaceSubrange(0..<keep, with: _lines[0..<keep]) }
            _lines = resized
        }

        _lineStarts = newLineStarts
        if newLineCount == 0 { return }

        let affectedChar = max(0, min(oldRange.lowerBound, storage.count))
        var firstLine = lineIndex(atOffset: affectedChar)
        if firstLine > 0 { firstLine -= 1 }

        let editStartLine = lineIndex(atOffset: oldRange.lowerBound)

        for li in firstLine..<_lines.count {
            if li == editStartLine {
                _lines[li].persistentSpans.removeAll(keepingCapacity: false)
                _lines[li].persistentRanges.removeAll(keepingCapacity: false)
                _lines[li].isDirty = true
                continue
            }

            guard delta != 0 else {
                _lines[li].isDirty = true
                continue
            }

            if !_lines[li].persistentSpans.isEmpty {
                var shifted: [KAttributedSpan] = []
                shifted.reserveCapacity(_lines[li].persistentSpans.count)
                for span in _lines[li].persistentSpans {
                    if span.range.upperBound <= affectedChar {
                        shifted.append(span)
                    } else {
                        let newLo = max(0, span.range.lowerBound + delta)
                        let newHi = max(newLo, span.range.upperBound + delta)
                        shifted.append(KAttributedSpan(range: newLo..<newHi, attributes: span.attributes))
                    }
                }
                _lines[li].persistentSpans = shifted

                var ranges: [Range<Int>] = []
                ranges.reserveCapacity(shifted.count)
                for s in shifted { ranges.append(s.range) }
                _lines[li].persistentRanges = ranges
            }

            _lines[li].isDirty = true
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
                let excluded = _lines[li].persistentRanges   // ← map をやめてキャッシュ利用
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

    // === 置換対象：KSyntaxParserRuby.parseLines(in:) ===
    fileprivate func parseLines(in candidateLines: Range<Int>) {
        // 現在の行数に _lines 配列を合わせる
        let totalLineCount = max(0, _lineStarts.count - 1)
        if _lines.count != totalLineCount {
            _lines = Array(repeating: LineInfo(), count: totalLineCount)
        }
        if totalLineCount == 0 { return }

        // 解析対象の行範囲をクランプ
        let clampedLower = max(0, min(candidateLines.lowerBound, totalLineCount))
        let clampedUpper = max(clampedLower, min(candidateLines.upperBound, totalLineCount))
        if clampedLower >= clampedUpper { return }

        // 直前行の継続状態を引き継いでスタート
        var carryState: EndState = (clampedLower > 0) ? _lines[clampedLower - 1].endState : .neutral

        let skeleton = storage.skeletonString
        skeleton.bytes.withUnsafeBufferPointer { whole in
            let docBytes = whole.baseAddress!

            for lineIndex in clampedLower..<clampedUpper {
                // すでに clean で、かつ前行からの継続状態と一致していればスキップ
                if !_lines[lineIndex].isDirty && _lines[lineIndex].endState == carryState {
                    carryState = _lines[lineIndex].endState
                    continue
                }

                // 行のオフセット計算
                let startOffset = _lineStarts[lineIndex]
                let endOffset   = _lineStarts[lineIndex + 1]
                let length      = endOffset - startOffset
                if length <= 0 {
                    _lines[lineIndex].persistentSpans  = []
                    _lines[lineIndex].persistentRanges = []
                    _lines[lineIndex].endState         = carryState
                    _lines[lineIndex].isDirty          = false
                    continue
                }

                let lineBase = docBytes + startOffset

                // 1行字句解析（恒久スパンのみ構築）
                let (newState, spans) = lexOneLine(base: lineBase,
                                                   count: length,
                                                   startOffset: startOffset,
                                                   initial: carryState)

                // 結果を保存（range キャッシュも同時に構築）
                _lines[lineIndex].endState        = newState
                _lines[lineIndex].persistentSpans = spans
                if spans.isEmpty {
                    _lines[lineIndex].persistentRanges = []
                } else {
                    var onlyRanges: [Range<Int>] = []
                    onlyRanges.reserveCapacity(spans.count)
                    for s in spans { onlyRanges.append(s.range) }
                    _lines[lineIndex].persistentRanges = onlyRanges
                }
                _lines[lineIndex].isDirty = false

                // 次行へ状態を引き継ぎ
                carryState = newState
            }
        }
    }

    // MARK: - 1行字句解析（恒久スパン：複数行 + /regex/）

    // 恒久スパンを構築する 1 行 lexer（複数行リテラル・%系・/regex/・heredoc・=begin/=end）
    private func lexOneLine(base: UnsafePointer<UInt8>,
                            count: Int,
                            startOffset: Int,
                            initial: EndState)
    -> (EndState, [KAttributedSpan]) {
        _scratchSpans.removeAll(keepingCapacity: true)
        var state = initial
        var i = 0
        let n = count

        // --- 行頭：継続状態の前処理 ---
        if state == .inMultiComment {
            if matchLineHead(base, n, token: "=end") {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: n, color: color(.comment))
                return (.neutral, _scratchSpans)
            } else {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: n, color: color(.comment))
                return (.inMultiComment, _scratchSpans)
            }
        }
        if state == .inStringSingle {
            let (closed, end) = scanQuotedNoInterpolation(base, n, from: 0, quote: FuncChar.singleQuote)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: end, color: color(.string))
            if closed { i = end; state = .neutral } else { return (.inStringSingle, _scratchSpans) }
        }
        if state == .inStringDouble {
            let (closed, end) = scanQuotedNoInterpolation(base, n, from: 0, quote: FuncChar.doubleQuote)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: end, color: color(.string))
            if closed { i = end; state = .neutral } else { return (.inStringDouble, _scratchSpans) }
        }
        if case let .inPercentLiteral(closing) = state {
            let res = scanUntil(base, n, from: 0, closing: closing)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: res.end, color: color(.string))
            if res.closed { i = res.end; state = .neutral } else { return (.inPercentLiteral(closing: closing), _scratchSpans) }
        }
        if case let .inHereDoc(term, allowIndent, interpolation) = state {
            let endAt = matchHereDocTerm(base, n, term: term, allowIndent: allowIndent)
            if endAt >= 0 {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: endAt, color: color(.string))
                i = endAt; state = .neutral
            } else {
                appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: n, color: color(.string))
                return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interpolation), _scratchSpans)
            }
        }
        if state == .inRegexSlash {
            let rx = scanRegexSlash(base, n, from: 0)
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: rx.closedTo, color: color(.string))
            if rx.closed { state = .neutral; i = rx.closedTo } else { return (.inRegexSlash, _scratchSpans) }
        }

        // "=begin" 行頭（中に入ったら丸ごとコメント色）
        if matchLineHead(base, n, token: "=begin") {
            appendSpan(documentStart: startOffset, fromLocal: 0, toLocal: n, color: color(.comment))
            return (.inMultiComment, _scratchSpans)
        }

        // --- 通常走査 ---
        while i < n {
            let c = base[i]

            // 行コメント (#) は恒久スパンにしない（オンデマンドで塗る）ので break
            if c == FuncChar.numeric { break }

            // '...' / "..."
            if c == FuncChar.singleQuote {
                let (closed, end) = scanQuotedNoInterpolation(base, n, from: i, quote: FuncChar.singleQuote)
                appendSpan(documentStart: startOffset, fromLocal: i, toLocal: end, color: color(.string))
                if closed { i = end } else { return (.inStringSingle, _scratchSpans) }
                continue
            }
            if c == FuncChar.doubleQuote {
                let (closed, end) = scanQuotedNoInterpolation(base, n, from: i, quote: FuncChar.doubleQuote)
                appendSpan(documentStart: startOffset, fromLocal: i, toLocal: end, color: color(.string))
                if closed { i = end } else { return (.inStringDouble, _scratchSpans) }
                continue
            }

            // heredoc ヘッダ
            if c == FuncChar.lt, i + 1 < n, base[i + 1] == FuncChar.lt {
                let (ok, _, term, allowIndent, interp) = parseHereDocHead(base, n, from: i)
                if ok {
                    appendSpan(documentStart: startOffset, fromLocal: i, toLocal: n, color: color(.string))
                    return (.inHereDoc(term: term, allowIndent: allowIndent, interpolation: interp), _scratchSpans)
                }
            }

            // % 系（%r も含む）
            if c == FuncChar.percent, i + 2 < n {
                let typeCode = base[i + 1]
                let typeLower = (typeCode >= 0x41 && typeCode <= 0x5A) ? (typeCode &+ 0x20) : typeCode
                let delimiter = base[i + 2]
                let isRegex = (typeLower == 0x72) // 'r'
                let isStringLike = (typeLower == 0x71 || typeLower == 0x77 || typeLower == 0x69 ||
                                    typeLower == 0x73 || typeLower == 0x78) // q,w,i,s,x
                if isRegex || isStringLike {
                    let closing = pairedClosing(for: delimiter)
                    let res = scanUntil(base, n, from: i + 3, closing: closing)
                    appendSpan(documentStart: startOffset, fromLocal: i, toLocal: res.end, color: color(.string))
                    if res.closed { i = res.end; continue }
                    return (.inPercentLiteral(closing: closing), _scratchSpans)
                }
            }

            // /regex/（スラッシュ始まり）
            if c == FuncChar.slash, isRegexLikelyAfterSlash(base, n, at: i) {
                let rx = scanRegexSlash(base, n, from: i)
                appendSpan(documentStart: startOffset, fromLocal: i, toLocal: rx.closedTo, color: color(.string))
                i = rx.closedTo
                if rx.closed { continue } else { return (.inRegexSlash, _scratchSpans) }
            }

            // 以降は恒久スパンを作らず、位置だけ前に進める（オンデマンドで色付け）
            if c == FuncChar.dollar { i = scanGlobalVar(base, n, from: i); continue }
            if c == FuncChar.at {
                let end = scanAtVar(base, n, from: i)
                if end > i { i = end; continue }
            }
            if c == FuncChar.colon {
                let end = scanSymbolLiteral(base, n, from: i)
                if end > i {
                    // :"..." / :symbol は“文字列色”だが恒久保持はしないので span 追加はしない
                    i = end; continue
                }
            }
            if c == FuncChar.minus || (c >= 0x30 && c <= 0x39) { i = scanNumber(base, n, from: i); continue }
            if c.isIdentStartAZ_ { i = scanIdentEnd(base, n, from: i); continue }

            i += 1
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
            // グローバル変数（$...）：$[0-9]+ / $! / $~ / $_ / $$ / $-w など含む
            if ch == FuncChar.dollar {
                let end = scanGlobalVar(lineBase, lineEnd, from: localIndex)
                if end > localIndex, let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.variable)]))
                    localIndex = end
                    continue
                }
            }

            // インスタンス/クラス変数（@... / @@...）
            if ch == FuncChar.at {
                let end = scanAtVar(lineBase, lineEnd, from: localIndex)
                if end > localIndex, let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.variable)]))
                    localIndex = end
                    continue
                }
            }
            
            // シンボルリテラル ( :$something / :name )
            if ch == FuncChar.colon {
                // ★ 追加：スコープ演算子 :: は除外（Prefs::DateTimeFormat など）
                if localIndex + 1 < lineEnd, lineBase[localIndex + 1] == FuncChar.colon {
                    localIndex += 2
                    continue
                } else {
                    let next = localIndex + 1
                    if next < lineEnd {
                        let nc = lineBase[next]
                        var end = next
                        if nc == FuncChar.dollar {                    // :$foo
                            end = scanGlobalVar(lineBase, lineEnd, from: next)
                        } else if nc.isIdentStartAZ_ {               // :symbol
                            end = scanIdentEnd(lineBase, lineEnd, from: next)
                        }
                        if end > next,
                           let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                            out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.variable)]))
                            localIndex = end
                            continue
                        }
                    }
                }
            }

            // 行コメント：'#' は恒久スパン外でのみ有効
            if ch == FuncChar.numeric {
                let absStart = documentStartOffset + localIndex
                var absEnd = documentStartOffset + lineEnd
                for r in mergedExcluded where r.lowerBound >= absStart {
                    absEnd = r.lowerBound
                    break
                }
                if absEnd > absStart, let rng = clipped(absStart, absEnd) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.comment)]))
                }
                break
            }

            // 単行の '...' / "..."
            if ch == FuncChar.singleQuote || ch == FuncChar.doubleQuote {
                let (closed, endLocal) = scanQuotedNoInterpolation(lineBase, lineEnd, from: localIndex, quote: ch)
                if closed, let rng = clipped(documentStartOffset + localIndex, documentStartOffset + endLocal) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.string)]))
                    localIndex = endLocal; continue
                }
            }

            // 単行の %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X（regex %r は恒久スパン側で処理）
            if ch == FuncChar.percent, localIndex + 2 < lineEnd {
                let typeCode = lineBase[localIndex + 1]
                let typeLower = typeCode.isAsciiUpper ? (typeCode &+ 0x20) : typeCode
                let delim = lineBase[localIndex + 2]
                let isStringLike = (typeLower == 0x71 || typeLower == 0x77 || typeLower == 0x69 ||
                                    typeLower == 0x73 || typeLower == 0x78)
                if isStringLike {
                    let closing = pairedClosing(for: delim)
                    let scan = scanUntil(lineBase, lineEnd, from: localIndex + 3, closing: closing)
                    if scan.closed, let rr = clipped(documentStartOffset + localIndex, documentStartOffset + scan.end) {
                        out.append(KAttributedSpan(range: rr, attributes: [.foregroundColor: color(.string)]))
                        localIndex = scan.end; continue
                    }
                }
            }

            // 数値
            if ch == FuncChar.minus || ch.isAsciiDigit {
                let end = scanNumber(lineBase, lineEnd, from: localIndex)
                if end > localIndex, let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.number)]))
                }
                localIndex = max(end, localIndex + 1); continue
            }

            // キーワード（左境界チェック付き）
            if ch.isIdentStartAZ_ {
                let end = scanIdentEnd(lineBase, lineEnd, from: localIndex)
                if end > localIndex,
                   isKeywordToken(lineBase, lineEnd, start: localIndex, end: end, documentStart: documentStartOffset),
                   let rng = clipped(documentStartOffset + localIndex, documentStartOffset + end) {
                    out.append(KAttributedSpan(range: rng, attributes: [.foregroundColor: color(.keyword)]))
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
                        if f.isAsciiAlpha { i += 1 } else { break }
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
        let isIdent0 = (head == FuncChar.underscore) || head.isAsciiAlpha
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
                let ok = (b == FuncChar.underscore) || b.isAsciiAlpha || b.isAsciiDigit
                if !ok { return (false, from, [], false, false) }
            }
        } else {
            let start = i
            while i < n {
                let c = base[i]
                let ok = (c == FuncChar.underscore) || c.isAsciiAlpha || c.isAsciiDigit
                if !ok { break }
                i += 1
            }
            if i == start { return (false, from, [], false, false) }
            term = Array(UnsafeBufferPointer(start: base + start, count: i - start))

            var hasUpper = false, allUpperAZ09_ = true
            for b in term {
                if b.isAsciiUpper { hasUpper = true }
                if !(b.isAsciiUpper || b.isAsciiDigit || b == FuncChar.underscore) {
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

    private func isKeywordToken(_ base: UnsafePointer<UInt8>, _ n: Int,
                                start: Int, end: Int, documentStart: Int) -> Bool {
        // 右境界・左境界チェック（既存）
        if end < n && !isDelimiter(base[end]) { return false }
        if start > 0 {
            let prev = base[start - 1]
            if !isDelimiter(prev) { return false }
            if prev == FuncChar.colon { return false }  // :then / ::end などを除外
        }

        let tokenLength = end - start
        if tokenLength <= 0 { return false }

        let pos = documentStart + start
        let firstByte = base[start]
        let skel = storage.skeletonString

        // フラット配列を線形に走査：
        // 1) 長さ一致 2) 先頭バイト一致 3) バイト列一致（matchesKeyword）
        for w in _keywordsFlat {
            if w.count != tokenLength { continue }
            if w[0] != firstByte { continue }
            if skel.matchesKeyword(at: pos, word: w) { return true }
        }
        return false
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
        if c.isAsciiDigit {
            i += 1
            while i < n, base[i].isAsciiDigit { i += 1 }
            return i
        }
        if c.isIdentStartAZ_ {
            i += 1
            while i < n {
                let b = base[i]
                if b.isIdentStartAZ_ || b.isAsciiDigit || b == FuncChar.question || b == FuncChar.exclamation { i += 1 } else { break }
            }
            return i
        }
        return i + 1
    }

    private func scanAtVar(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        if i + 1 < n, base[i] == FuncChar.at, base[i + 1] == FuncChar.at {
            i += 2
            if i < n, base[i].isIdentStartAZ_ {
                i += 1
                while i < n {
                    let b = base[i]
                    if b.isIdentStartAZ_ || b.isAsciiDigit || b == FuncChar.question || b == FuncChar.exclamation { i += 1 } else { break }
                }
                return i
            }
            return from
        } else if base[i] == FuncChar.at {
            i += 1
            if i < n, base[i].isIdentStartAZ_ {
                i += 1
                while i < n {
                    let b = base[i]
                    if b.isIdentStartAZ_ || b.isAsciiDigit || b == FuncChar.question || b == FuncChar.exclamation { i += 1 } else { break }
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
        } else if c.isIdentStartAZ_ {
            var j = i + 1
            while j < n {
                let b = base[j]
                if b.isIdentStartAZ_ || b.isAsciiDigit || b == FuncChar.question || b == FuncChar.exclamation { j += 1 } else { break }
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
            if !(c.isAsciiDigit || c == FuncChar.period || c.isAsciiAlpha) { break }
            i += 1
        }
        return i
    }

    private func scanIdentEnd(_ base: UnsafePointer<UInt8>, _ n: Int, from: Int) -> Int {
        var i = from
        while i < n {
            let c = base[i]
            let alpha = c.isAsciiAlpha || c == FuncChar.underscore
            let digit = c.isAsciiDigit
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

        // ★ 追加：直前の英小文字連続が if / elsif なら regex とみなす（例: `if /.../`, `elsif /.../`）
        if base[j].isAsciiLower {
            var k = j
            while k >= 0, base[k].isAsciiLower { k -= 1 }
            let start = k + 1
            let len = j - start + 1
            if len == 2, base[start] == 0x69, base[start + 1] == 0x66 { // "if"
                return true
            }
            if len == 5,
               base[start] == 0x65, base[start + 1] == 0x6C, base[start + 2] == 0x73,
               base[start + 3] == 0x69, base[start + 4] == 0x66 {       // "elsif"
                return true
            }
        }

        if base[j].isIdentStartAZ_ || base[j].isAsciiDigit { return false }
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
                c == FuncChar.minus || c.isAsciiAlpha || c.isAsciiDigit || c == FuncChar.underscore
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
                if !base[p].isAsciiDigit {
                    if p + 1 < total, base[p + 1].isAsciiDigit { lo = p + 1; hi = lo }
                    else if base[p] == FuncChar.minus, p + 1 < total, base[p + 1].isAsciiDigit { lo = p; hi = p + 1 }
                    else { return nil }
                }
                while lo > 0, base[lo - 1].isAsciiDigit { lo -= 1 }
                if lo > 1, base[lo - 1] == FuncChar.minus,
                   !((lo - 2) >= 0 && (base[lo - 2].isAsciiDigit || base[lo - 2].isAsciiAlpha || base[lo - 2] == FuncChar.underscore)) {
                    lo -= 1
                }
                while hi < total {
                    let c = base[hi]
                    if c.isAsciiDigit || c == FuncChar.period || c.isAsciiAlpha { hi += 1 } else { break }
                }
                return lo..<hi
            }
            if let number = expandNumber(from: pivot) { return number }

            // 識別子
            func isIdentPartRuby(_ c: UInt8) -> Bool {
                c.isIdentStartAZ_ || c.isAsciiDigit || c == FuncChar.question || c == FuncChar.exclamation
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
                    //return (text, baseOffset + start ..< baseOffset + i)
                    return (text, baseOffset + (start - from) ..< baseOffset + (i - from))
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
    
    // MARK: - Keywords
    
    func setKeywords(_ words: [String]) {
        // 重複除去（大文字小文字はそのまま保持）
        var unique = Set<String>()
        unique.reserveCapacity(words.count)
        for w in words where !w.isEmpty {
            unique.insert(w)
        }

        // UTF-8 バイト列に変換してフラット配列化
        var flat: [[UInt8]] = []
        flat.reserveCapacity(unique.count)
        for w in unique {
            flat.append(Array(w.utf8))
        }

        // バイト列として辞書順にソート（1文字目で大半が弾かれる）
        flat.sort { (a, b) -> Bool in
            // 長さより「辞書順の早い判定」を優先（memcmp 相当）
            let n = min(a.count, b.count)
            for i in 0..<n {
                if a[i] != b[i] { return a[i] < b[i] }
            }
            return a.count < b.count
        }

        _keywordsFlat = flat
    }
    
    // MARK: - Theme
    
    func setTheme(_ theme: [KFunctionalColor : NSColor]) {
        _theme = theme
    }

    // MARK: - Completion（語彙のスナップショット）

    // Ganpi: 補完語彙を毎回全文スキャンして再構築
    // - 文書全体＋Rubyキーワードを含む
    // - Data未使用、安全な [UInt8] ベース
    // - case-sensitive 前方一致に対応
    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?) {
        let bytes = storage.skeletonString.bytes
        let n = bytes.count
        if n == 0 {
            _completionLexicon.removeAll(keepingCapacity: false)
            return
        }

        // Ruby的語の定義（!/? 終端許可）
        @inline(__always) func isHead(_ b: UInt8) -> Bool {
            b == FuncChar.at || b == FuncChar.dollar || b == FuncChar.underscore || b.isAsciiAlpha
        }
        @inline(__always) func isBody(_ b: UInt8) -> Bool {
            b.isAsciiDigit || b == FuncChar.underscore || b.isAsciiAlpha
        }

        // 一意化用の Set<[UInt8]>
        var unique = Set<[UInt8]>()
        unique.reserveCapacity(max(64, n >> 4))

        var i = 0
        while i < n {
            let b = bytes[i]
            if isHead(b) {
                let s = i
                i += 1
                while i < n, isBody(bytes[i]) { i += 1 }
                if i < n, (bytes[i] == FuncChar.exclamation || bytes[i] == FuncChar.question) { i += 1 }
                if !bytes[s].isAsciiDigit {
                    if i - s <= 128 {
                        let token = Array(bytes[s..<i])
                        unique.insert(token)
                    }
                }
            } else {
                i += 1
            }
        }

        // Rubyキーワードも補完候補に加える（重複は自動で除外）
        for kw in _keywordsFlat {
            unique.insert(kw)
        }

        // ソート（memcmp相当の辞書順）
        var list = Array(unique)
        list.sort { (a, b) -> Bool in
            let m = min(a.count, b.count)
            for k in 0..<m {
                let x = a[k], y = b[k]
                if x != y { return x < y }
            }
            return a.count < b.count
        }

        _completionLexicon = list
    }
    
    // KSyntaxParserRuby.swift / class KSyntaxParserRuby
    // 辞書順（memcmp 相当）：完全バイト順、case-sensitive
    @inline(__always)
    private func dataLessThan(_ a: Data, _ b: Data) -> Bool {
        let len = min(a.count, b.count)
        return a.withUnsafeBytes { pa in
            return b.withUnsafeBytes { pb in
                guard let paBase = pa.baseAddress, let pbBase = pb.baseAddress else { return false }
                let cmp = memcmp(paBase, pbBase, len)
                return cmp < 0 || (cmp == 0 && a.count < b.count)
            }
        }
    }
    

    // KSyntaxParserRuby.swift / class KSyntaxParserRuby
    // メソッド: completionEntries(prefix:around:limit:policy:)
    // 目的: prefix（UTF-8）を [UInt8] にし、[key, key+0xFF) の範囲を二分探索で取得（安全）

    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry] {
        // 数MB前提: 毎回再構築
        rebuildCompletionsIfNeeded(dirtyRange: nil)

        guard !prefix.isEmpty else { return [] }
        let key: [UInt8] = Array(prefix.utf8)

        @inline(__always)
        func less(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            let m = min(a.count, b.count)
            var i = 0
            while i < m {
                let x = a[i], y = b[i]
                if x != y { return x < y }
                i += 1
            }
            return a.count < b.count
        }

        @inline(__always)
        func lowerBound(_ a: [[UInt8]], _ k: [UInt8]) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if less(a[mid], k) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        // 前方一致レンジ: [ key, key + [0xFF) )
        let lo = lowerBound(_completionLexicon, key)
        var highKey = key; highKey.append(0xFF)
        let hi = lowerBound(_completionLexicon, highKey)

        if lo >= hi { return [] }

        var out: [KCompletionEntry] = []
        out.reserveCapacity(min(limit, 64))

        var i = lo
        while i < hi && out.count < limit {
            let token = _completionLexicon[i]
            // UTF-8前提：不正列はスキップ
            if let s = String(bytes: token, encoding: .utf8), s != prefix {
                out.append(KCompletionEntry(text: s, kind: .keyword, detail: nil, score: 0))
            }
            i += 1
        }
        return out
    }
}
*/
