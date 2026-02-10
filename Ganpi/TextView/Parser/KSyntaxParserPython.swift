//
//  KSyntaxParserPython.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/02/10,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

final class KSyntaxParserPython: KSyntaxParser {

    // MARK: - Types

    private enum KEndState: Equatable {
        case neutral
        case inTripleSingle(isRaw: Bool)
        case inTripleDouble(isRaw: Bool)
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    // 文字列プレフィックス（r/R/u/U/b/B/f/F）
    private let _stringPrefixLetters: [UInt8] = Array("rRuUbBfF".utf8)

    // outline 用
    private let _tokenAsync: [UInt8] = Array("async".utf8)
    private let _tokenDef:   [UInt8] = Array("def".utf8)
    private let _tokenClass: [UInt8] = Array("class".utf8)

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .python)
    }

    // MARK: - Override

    override var lineCommentPrefix: String? { "#" }

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            let _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        // 行数差分を反映（改行追加/削除）
        if plan.lineDelta != 0 {
            applyLineDelta(lines: &_lines,
                           spliceIndex: plan.spliceIndex,
                           lineDelta: plan.lineDelta) { KLineInfo(endState: .neutral) }
        }

        // 安全弁：それでも合わなければ全再構築
        let rebuilt = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
        if rebuilt { log("Line counts do not match.", from: self) }
        if _lines.isEmpty { return }

        var startLine = plan.startLine
        if plan.lineDelta != 0 {
            startLine = min(startLine, max(0, plan.spliceIndex - 1))
        }

        let maxLine = max(0, _lines.count - 1)
        startLine = max(0, min(startLine, maxLine))

        var minLine = plan.minLine
        minLine = max(0, min(minLine, maxLine))

        scanFrom(line: rebuilt ? 0 : startLine, minLine: minLine)
    }

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        ensureUpToDate(for: range)
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let lineIndex = skeleton.lineIndex(at: range.lowerBound)

        if lineIndex < 0 || lineIndex >= _lines.count { return [] }

        let lineRange = skeleton.lineRange(at: lineIndex)
        let paintRange = range.clamped(to: lineRange)
        if paintRange.isEmpty { return [] }

        let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(16)

        @inline(__always)
        func emitSpan(_ tokenRange: Range<Int>, role: KFunctionalColor) {
            // ここで paintRange にクリップして「必要最小限」だけ返す
            let clipped = tokenRange.clamped(to: paintRange)
            if clipped.isEmpty { return }
            spans.append(makeSpan(range: clipped, role: role))
        }

        let _ = parseLine(lineRange: lineRange,
                          startState: startState,
                          keywords: keywords,
                          emit: emitSpan)

        return spans
    }

    override func wordRange(at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let count = skeleton.count
        if count == 0 { return nil }

        // index は skeleton と同一スケールの前提。安全に clamp。
        var i = index
        if i < 0 { i = 0 }
        if i > count { i = count }

        func isIdentStart(_ b: UInt8) -> Bool { b.isIdentStartAZ_ }
        func isIdentPart(_ b: UInt8) -> Bool { b.isIdentPartAZ09_ }

        // CompletionController は「単語末尾（=区切り文字側）」で呼ばれるので index-1 を基準にする
        if i == 0 { return nil }

        let probe = i - 1
        let b0 = skeleton[probe]
        if !isIdentPart(b0) { return nil }

        // 左へ伸ばす
        var start = probe
        while start > 0 {
            let b = skeleton[start - 1]
            if isIdentPart(b) {
                start -= 1
                continue
            }
            break
        }

        // 先頭が start 条件を満たさないなら無効（例: "9abc" を単語にしない）
        if !isIdentStart(skeleton[start]) { return nil }

        let end = i
        if start >= end { return nil }
        return start..<end
    }

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {   // range is ignored for now.
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return [] }

        // startState（=前行 endState）を参照するため、全文を up-to-date にする
        ensureUpToDate(for: 0..<n)
        if _lines.isEmpty { return [] }

        var items: [KOutlineItem] = []
        items.reserveCapacity(128)

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func skipSpaces(_ i: inout Int, end: Int) {
            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
        }

        @inline(__always)
        func matchBytes(_ target: [UInt8], at index: Int, end: Int) -> Bool {
            if index < 0 { return false }
            if index + target.count > end { return false }
            if target.isEmpty { return true }

            var j = 0
            while j < target.count {
                if bytes[index + j] != target[j] { return false }
                j += 1
            }
            return true
        }

        // ざっくり indent level（スペース4 = 1レベル、TABは4扱い）
        @inline(__always)
        func computeIndentLevel(lineStart: Int, end: Int) -> (level: Int, firstNonWS: Int) {
            var col = 0
            var i = lineStart
            while i < end {
                let b = bytes[i]
                if b == FC.space {
                    col += 1
                    i += 1
                    continue
                }
                if b == FC.tab {
                    col += 4
                    i += 1
                    continue
                }
                break
            }
            return (level: col / 4, firstNonWS: i)
        }

        for lineIndex in 0..<_lines.count {
            let lineRange = skeleton.lineRange(at: lineIndex)
            if lineRange.isEmpty { continue }

            let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral
            if startState != .neutral {
                // 文字列（トリプルクォート）継続中の行はアウトライン対象外にする
                continue
            }

            let end = lineRange.upperBound
            let (level, first) = computeIndentLevel(lineStart: lineRange.lowerBound, end: end)

            var i = first
            if i >= end { continue }

            // コメント行は無視
            if bytes[i] == FC.numeric { continue }

            // async def
            var isAsyncDef = false
            if matchBytes(_tokenAsync, at: i, end: end) {
                let afterAsync = i + _tokenAsync.count
                if afterAsync < end && isSpaceOrTab(bytes[afterAsync]) {
                    i = afterAsync
                    skipSpaces(&i, end: end)
                    isAsyncDef = true
                } else {
                    // "asyncX" などは無視
                    i = first
                }
            }

            // def
            if matchBytes(_tokenDef, at: i, end: end) {
                let afterDef = i + _tokenDef.count
                if afterDef >= end || !isSpaceOrTab(bytes[afterDef]) { continue }

                i = afterDef
                skipSpaces(&i, end: end)
                if i >= end { continue }

                // 関数名
                if !bytes[i].isIdentStartAZ_ { continue }
                let nameStart = i
                i += 1
                while i < end && bytes[i].isIdentPartAZ09_ { i += 1 }
                let nameRange = nameStart..<i
                if nameRange.isEmpty { continue }

                items.append(KOutlineItem(kind: .method,
                                          nameRange: nameRange,
                                          level: level,
                                          isSingleton: false))
                continue
            }

            // class
            if matchBytes(_tokenClass, at: i, end: end) {
                let afterClass = i + _tokenClass.count
                if afterClass >= end || !isSpaceOrTab(bytes[afterClass]) { continue }

                i = afterClass
                skipSpaces(&i, end: end)
                if i >= end { continue }

                // クラス名
                if !bytes[i].isIdentStartAZ_ { continue }
                let nameStart = i
                i += 1
                while i < end && bytes[i].isIdentPartAZ09_ { i += 1 }
                let nameRange = nameStart..<i
                if nameRange.isEmpty { continue }

                items.append(KOutlineItem(kind: .class,
                                          nameRange: nameRange,
                                          level: level,
                                          isSingleton: false))
                continue
            }

            // async だけで def じゃないものは無視
            if isAsyncDef {
                continue
            }
        }

        return items
    }
    
    
    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return (nil, nil) }
        if index < 0 || index > n { return (nil, nil) }

        // index が末尾の場合は直前を参照（lineIndex計算のため）
        let safeIndex = min(max(0, index), max(0, n - 1))
        ensureUpToDate(for: safeIndex..<(safeIndex + 1))

        let caretLine = skeleton.lineIndex(at: safeIndex)
        if _lines.isEmpty { return (nil, nil) }

        let maxBackLines = 1000

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func skipSpaces(_ i: inout Int, end: Int) {
            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
        }

        // スペース4=1レベル、TABは4扱い
        @inline(__always)
        func indentColumn(lineStart: Int, end: Int) -> Int {
            var col = 0
            var i = lineStart
            while i < end {
                let b = bytes[i]
                if b == FC.space {
                    col += 1
                    i += 1
                    continue
                }
                if b == FC.tab {
                    col += 4
                    i += 1
                    continue
                }
                break
            }
            return col
        }

        @inline(__always)
        func matchBytes(_ target: [UInt8], at index: Int, end: Int) -> Bool {
            if index < 0 { return false }
            if index + target.count > end { return false }
            if target.isEmpty { return true }

            var j = 0
            while j < target.count {
                if bytes[index + j] != target[j] { return false }
                j += 1
            }
            return true
        }

        @inline(__always)
        func parseName(afterKeywordAt p: Int, kwLen: Int, end: Int) -> Range<Int>? {
            var i = p + kwLen
            skipSpaces(&i, end: end)
            if i >= end { return nil }

            // name
            if !bytes[i].isIdentStartAZ_ { return nil }
            let nameStart = i
            i += 1
            while i < end && bytes[i].isIdentPartAZ09_ { i += 1 }
            if nameStart >= i { return nil }
            return nameStart..<i
        }

        // caret行の indent を基準に「包含」っぽいものだけ拾う
        let caretLineRange = skeleton.lineRange(at: caretLine)
        let caretIndent = indentColumn(lineStart: caretLineRange.lowerBound, end: caretLineRange.upperBound)

        var innerRange: Range<Int>? = nil
        var outerRange: Range<Int>? = nil

        // まず inner(def) を探すための閾値
        var innerIndentLimit = caretIndent
        // outer(class) は inner が見つかったらさらに浅い indent に絞る
        var outerIndentLimit: Int? = nil

        var line = caretLine
        var scanned = 0

        while line >= 0 && scanned < maxBackLines && (innerRange == nil || outerRange == nil) {
            // 行頭状態：triple-quote 継続中の行はスキップ
            let startState: KEndState = {
                if line == 0 { return .neutral }
                let prev = line - 1
                if prev >= 0 && prev < _lines.count { return _lines[prev].endState }
                return .neutral
            }()

            if startState == .neutral {
                let lr = skeleton.lineRange(at: line)
                let start = lr.lowerBound
                let end = lr.upperBound

                // caret行だけは caret より後を見ない（def/class が後ろにあっても拾わない）
                let limit = (line == caretLine) ? safeIndex : end
                if start < limit {
                    // インデントと行頭トークン
                    let ind = indentColumn(lineStart: start, end: limit)

                    // 閾値に合わないものは候補から外す
                    let allowInner = (innerRange == nil) && (ind <= innerIndentLimit)
                    let allowOuter = (outerRange == nil) && {
                        if let lim = outerIndentLimit { return ind <= lim }
                        return ind <= innerIndentLimit
                    }()

                    var p = start
                    skipSpaces(&p, end: limit)
                    if p < limit {
                        let head = bytes[p]

                        // コメント/デコレータ行は無視
                        if head != FC.numeric && head != FC.at {
                            // async def
                            var q = p
                            var isAsync = false
                            if matchBytes(_tokenAsync, at: q, end: limit) {
                                let afterAsync = q + _tokenAsync.count
                                if afterAsync < limit && isSpaceOrTab(bytes[afterAsync]) {
                                    q = afterAsync
                                    skipSpaces(&q, end: limit)
                                    isAsync = true
                                }
                            }

                            if allowInner && matchBytes(_tokenDef, at: q, end: limit) {
                                let afterDef = q + _tokenDef.count
                                if afterDef < limit && isSpaceOrTab(bytes[afterDef]) {
                                    if let r = parseName(afterKeywordAt: q, kwLen: _tokenDef.count, end: limit) {
                                        innerRange = r
                                        // outer は def より浅い indent に絞る
                                        outerIndentLimit = max(0, ind - 1)
                                        // さらに外側の def を拾わないため limit を更新
                                        innerIndentLimit = max(0, ind - 1)
                                        _ = isAsync // 将来表示を変えたければここで使える
                                    }
                                }
                            } else if allowOuter && matchBytes(_tokenClass, at: p, end: limit) {
                                let afterClass = p + _tokenClass.count
                                if afterClass < limit && isSpaceOrTab(bytes[afterClass]) {
                                    if let r = parseName(afterKeywordAt: p, kwLen: _tokenClass.count, end: limit) {
                                        outerRange = r
                                    }
                                }
                            }
                        }
                    }
                }
            }

            line -= 1
            scanned += 1
        }

        let outer = outerRange.map { storage.string(in: $0) }
        let inner = innerRange.map { storage.string(in: $0) }
        return (outer, inner)
    }

    // MARK: - Private (scan)

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        if _lines.isEmpty { return }

        var state: KEndState = (startLine > 0) ? _lines[startLine - 1].endState : .neutral

        var line = startLine
        while line < _lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let old = _lines[line].endState
            let new = parseLine(lineRange: lineRange,
                                startState: state,
                                keywords: nil,
                                emit: emitNothing)

            _lines[line].endState = new
            state = new

            if line >= minLine && new == old {
                break
            }
            line += 1
        }
    }

    // MARK: - Private (lexer)

    private func emitNothing(_ range: Range<Int>, _ role: KFunctionalColor) {
        // no-op（scan only）
    }

    // 1行（LFを含まない）を走査して span 生成＋行末状態を返す
    // - keywords=nil の場合は keyword 判定を行わない（scan用途）
    private func parseLine(lineRange: Range<Int>,
                           startState: KEndState,
                           keywords: [[UInt8]]?,
                           emit: (Range<Int>, KFunctionalColor) -> Void) -> KEndState {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let start = lineRange.lowerBound
        let end = lineRange.upperBound
        if start >= end { return startState }

        // ローカル定数（1文字プロパティを作らない）
        let rangeAF: ClosedRange<UInt8> = UInt8(ascii: "A")...UInt8(ascii: "F")
        let rangeaf: ClosedRange<UInt8> = UInt8(ascii: "a")...UInt8(ascii: "f")
        let range07: ClosedRange<UInt8> = UInt8(ascii: "0")...UInt8(ascii: "7")

        @inline(__always)
        func isEscapedQuote(at index: Int, lineStart: Int) -> Bool {
            // 直前の '\' の連続数が奇数ならエスケープ扱い
            if index <= lineStart { return false }
            var backslashCount = 0
            var j = index - 1
            while j >= lineStart && bytes[j] == FC.backSlash {
                backslashCount += 1
                if j == 0 { break }
                j -= 1
            }
            return (backslashCount & 1) == 1
        }

        @inline(__always)
        func isStringPrefixLetter(_ b: UInt8) -> Bool {
            // rRuUbBfF
            return _stringPrefixLetters.contains(b)
        }

        @inline(__always)
        func isRawPrefix(_ b: UInt8) -> Bool {
            return b == UInt8(ascii: "r") || b == UInt8(ascii: "R")
        }

        @inline(__always)
        func stringPrefixInfo(before quoteIndex: Int, lineStart: Int) -> (tokenStart: Int, isRaw: Bool) {
            // quote直前の最大2文字までを prefix とみなす（fr / rf / br / rb 等）
            var tokenStart = quoteIndex
            var isRaw = false

            var consumed = 0
            var j = quoteIndex
            while j > lineStart && consumed < 2 {
                let b = bytes[j - 1]
                if !isStringPrefixLetter(b) { break }

                tokenStart = j - 1
                if isRawPrefix(b) { isRaw = true }

                j -= 1
                consumed += 1
            }

            // prefix のさらに前が識別子の一部なら誤検出なので無効化
            if tokenStart > lineStart {
                let prev = bytes[tokenStart - 1]
                if prev.isIdentPartAZ09_ {
                    return (tokenStart: quoteIndex, isRaw: false)
                }
            }

            return (tokenStart: tokenStart, isRaw: isRaw)
        }

        @inline(__always)
        func findClosingTriple(quote: UInt8, from: Int, lineStart: Int, isRaw: Bool) -> Int? {
            if from >= end { return nil }
            if end - from < 3 { return nil }

            var i = from
            while i + 2 < end {
                if bytes[i] == quote && bytes[i + 1] == quote && bytes[i + 2] == quote {
                    if !isRaw && isEscapedQuote(at: i, lineStart: lineStart) {
                        i += 1
                        continue
                    }
                    return i
                }
                i += 1
            }
            return nil
        }

        @inline(__always)
        func scanIdentifier(from i0: Int) -> Int {
            var i = i0
            i += 1
            while i < end && bytes[i].isIdentPartAZ09_ { i += 1 }
            return i
        }

        @inline(__always)
        func isHexDigit(_ b: UInt8) -> Bool {
            if b.isAsciiDigit { return true }
            return rangeAF.contains(b) || rangeaf.contains(b)
        }

        @inline(__always)
        func isOctDigit(_ b: UInt8) -> Bool { range07.contains(b) }

        @inline(__always)
        func isBinDigit(_ b: UInt8) -> Bool {
            return b == UInt8(ascii: "0") || b == UInt8(ascii: "1")
        }

        @inline(__always)
        func scanDigits(from i0: Int) -> Int {
            // 数字 + '_' を許容（厳密なルールは追わない）
            var i = i0
            while i < end {
                let b = bytes[i]
                if b.isAsciiDigit || b == FC.underscore {
                    i += 1
                    continue
                }
                break
            }
            return i
        }

        @inline(__always)
        func scanHexDigits(from i0: Int) -> Int {
            var i = i0
            while i < end {
                let b = bytes[i]
                if isHexDigit(b) || b == FC.underscore {
                    i += 1
                    continue
                }
                break
            }
            return i
        }

        @inline(__always)
        func scanOctDigits(from i0: Int) -> Int {
            var i = i0
            while i < end {
                let b = bytes[i]
                if isOctDigit(b) || b == FC.underscore {
                    i += 1
                    continue
                }
                break
            }
            return i
        }

        @inline(__always)
        func scanBinDigits(from i0: Int) -> Int {
            var i = i0
            while i < end {
                let b = bytes[i]
                if isBinDigit(b) || b == FC.underscore {
                    i += 1
                    continue
                }
                break
            }
            return i
        }

        @inline(__always)
        func scanExponent(from i0: Int) -> Int {
            // e/E[+/-]?digits
            var i = i0
            if i >= end { return i0 }

            let b = bytes[i]
            if b != UInt8(ascii: "e") && b != UInt8(ascii: "E") { return i0 }

            var j = i + 1
            if j < end && (bytes[j] == FC.plus || bytes[j] == FC.minus) {
                j += 1
            }

            let beforeDigits = j
            j = scanDigits(from: j)
            if j == beforeDigits {
                return i0
            }
            return j
        }

        @inline(__always)
        func scanNumber(from i0: Int) -> Int {
            var i = i0

            // .123
            if bytes[i] == FC.period {
                i += 1
                i = scanDigits(from: i)
                let exp = scanExponent(from: i)
                if exp != i { i = exp }
                return i
            }

            // 0x / 0b / 0o
            if bytes[i] == UInt8(ascii: "0") && i + 1 < end {
                switch bytes[i + 1] {
                case UInt8(ascii: "x"), UInt8(ascii: "X"):
                    i += 2
                    i = scanHexDigits(from: i)
                    return i
                case UInt8(ascii: "b"), UInt8(ascii: "B"):
                    i += 2
                    i = scanBinDigits(from: i)
                    return i
                case UInt8(ascii: "o"), UInt8(ascii: "O"):
                    i += 2
                    i = scanOctDigits(from: i)
                    return i
                default:
                    break
                }
            }

            // 10 / 10.2 / 10e-3
            i = scanDigits(from: i)

            if i < end && bytes[i] == FC.period {
                i += 1
                i = scanDigits(from: i)
            }

            let exp = scanExponent(from: i)
            if exp != i { i = exp }

            // 1j / 1J
            if i < end {
                let b = bytes[i]
                if b == UInt8(ascii: "j") || b == UInt8(ascii: "J") {
                    i += 1
                }
            }

            return i
        }

        // --- ここから本体走査 ---

        var state = startState
        var i = start

        // startState がトリプルクォート継続中なら、まずそれを処理
        switch startState {
        case .inTripleSingle(let isRaw):
            if let close = findClosingTriple(quote: FC.singleQuote, from: i, lineStart: start, isRaw: isRaw) {
                emit(start..<(close + 3), .string)
                i = close + 3
                state = .neutral
            } else {
                emit(start..<end, .string)
                return startState
            }

        case .inTripleDouble(let isRaw):
            if let close = findClosingTriple(quote: FC.doubleQuote, from: i, lineStart: start, isRaw: isRaw) {
                emit(start..<(close + 3), .string)
                i = close + 3
                state = .neutral
            } else {
                emit(start..<end, .string)
                return startState
            }

        case .neutral:
            break
        }

        // 以降は neutral の前提で走査
        while i < end {
            let b = bytes[i]

            // コメント（文字列外のみ）
            if b == FC.numeric {
                emit(i..<end, .comment)
                break
            }

            // 文字列（' / "）
            if b == FC.singleQuote || b == FC.doubleQuote {
                let quote = b
                let quoteIndex = i

                let prefix = stringPrefixInfo(before: quoteIndex, lineStart: start)
                let tokenStart = prefix.tokenStart
                let isRaw = prefix.isRaw

                // triple?
                if quoteIndex + 2 < end && bytes[quoteIndex + 1] == quote && bytes[quoteIndex + 2] == quote {
                    let contentStart = quoteIndex + 3
                    if let close = findClosingTriple(quote: quote, from: contentStart, lineStart: start, isRaw: isRaw) {
                        emit(tokenStart..<(close + 3), .string)
                        i = close + 3
                        continue
                    } else {
                        emit(tokenStart..<end, .string)
                        return (quote == FC.singleQuote)
                            ? .inTripleSingle(isRaw: isRaw)
                            : .inTripleDouble(isRaw: isRaw)
                    }
                } else {
                    // single-line quote
                    var j = quoteIndex + 1
                    while j < end {
                        let c = bytes[j]

                        if c == quote {
                            if !isRaw && isEscapedQuote(at: j, lineStart: start) {
                                j += 1
                                continue
                            }
                            emit(tokenStart..<(j + 1), .string)
                            i = j + 1
                            break
                        }

                        // エスケープ（rawでない場合のみ）
                        if !isRaw && c == FC.backSlash {
                            j += 2
                            continue
                        }

                        j += 1
                    }
                    if j >= end {
                        // 行内で閉じていない → その行末まで文字列色（次行へは継続しない）
                        emit(tokenStart..<end, .string)
                        break
                    }
                    continue
                }
            }

            // 識別子（keyword判定）
            if b.isIdentStartAZ_ {
                let startWord = i
                let endWord = scanIdentifier(from: i)
                let wordRange = startWord..<endWord

                if let kw = keywords {
                    if skeleton.matches(words: kw, in: wordRange) {
                        emit(wordRange, .keyword)
                    }
                }

                i = endWord
                continue
            }

            // 数値
            if b.isAsciiDigit || (b == FC.period && (i + 1) < end && bytes[i + 1].isAsciiDigit) {
                let startNum = i
                let endNum = scanNumber(from: i)
                if endNum > startNum {
                    emit(startNum..<endNum, .number)
                    i = endNum
                    continue
                }
            }

            i += 1
        }

        return state
    }
}
