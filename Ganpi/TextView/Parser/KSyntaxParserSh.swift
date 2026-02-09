//
//  KSyntaxParserSh.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

final class KSyntaxParserSh: KSyntaxParser {

    // MARK: - Types

    private struct KHeredocEntry: Equatable {
        let label: [UInt8]
        let allowLeadingTabs: Bool   // <<- の場合 true（行頭TABを許容）
    }

    private enum KCommandQuoteState: Equatable {
        case none
        case single
        case double
    }

    private enum KEndState: Equatable {
        case neutral
        case inCasePattern
        case inSingleQuote
        case inDoubleQuote
        case inHeredoc(queue: [KHeredocEntry], active: KHeredocEntry?)

        // $(...) が行を跨ぐための状態
        // depth はネスト数。quote は $(...) の中で継続している quote 状態（sed "..." など）を保持する。
        case inCommandSubstitution(depth: Int, quote: KCommandQuoteState)
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .sh)
    }

    // MARK: - Override

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            let _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        // 行数差分を反映
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
        guard range.count > 0 else { return [] }

        ensureUpToDate(for: range)

        let skeleton = storage.skeletonString
        let lineRange = skeleton.lineRange(contains: range)
        guard !lineRange.isEmpty else { return [] }

        let lineIndex = skeleton.lineIndex(at: lineRange.lowerBound)

        // ★重要：case/quote/$(...) は「数十行前の状態」に依存し得る。
        // 直前1行だけだと startState が neutral のままになり、対策が発火しない。
        if !_lines.isEmpty {
            let lookback = 200  // まずは安全側（重ければ 50/100 に落として可）
            let start = max(0, min(lineIndex - lookback, _lines.count - 1))
            let minLine = max(0, min(lineIndex, _lines.count - 1))
            scanFrom(line: start, minLine: minLine)
        }

        let startState: KEndState =
            (lineIndex > 0 && lineIndex - 1 < _lines.count) ? _lines[lineIndex - 1].endState : .neutral

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(8)

        _ = parseLine(lineRange: lineRange,
                      clampTo: range,
                      startState: startState,
                      collectSpans: true,
                      spans: &spans)

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

        // CompletionController は「単語末尾（=区切り文字側）」で呼ばれるので、
        // まず index-1 を基準にする。
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

        // 先頭文字が start 条件を満たさないなら無効（例: "9abc" を単語にしない）
        if !isIdentStart(skeleton[start]) { return nil }

        // 右端は「元の index（カーソル位置）」を採用する
        // （probe は index-1 なので probe+1 でも同じだが、意図を明確にする）
        let end = i
        if start >= end { return nil }

        return start..<end
    }
    
    override func outline(in range: Range<Int>?) -> [KOutlineItem] {     // range is ignored for now.
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return [] }

        // endState を参照するため、全文を一度 up-to-date にしておく
        ensureUpToDate(for: 0..<n)

        let newlineIndices = skeleton.newlineIndices

        let functionBytes = Array("function".utf8)

        var items: [KOutlineItem] = []
        items.reserveCapacity(128)

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        func skipSpaces(_ i: inout Int, _ end: Int) {
            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
        }

        func matchBytes(_ target: [UInt8], at index: Int, end: Int) -> Bool {
            let m = target.count
            if index + m > end { return false }
            var k = 0
            while k < m {
                if bytes[index + k] != target[k] { return false }
                k += 1
            }
            return true
        }

        func isKeywordBoundary(_ index: Int, end: Int) -> Bool {
            if index >= end { return true }
            return isSpaceOrTab(bytes[index])
        }

        func parseIdentName(start: Int, end: Int) -> Range<Int>? {
            var i = start
            if i >= end { return nil }
            if !bytes[i].isIdentStartAZ_ { return nil }
            i += 1
            while i < end && bytes[i].isIdentPartAZ09_ { i += 1 }
            return start..<i
        }

        func matchParenPair(_ i: inout Int, _ end: Int) -> Bool {
            // allow: "()" or "(   )" or " ( ) " etc
            skipSpaces(&i, end)
            if i >= end || bytes[i] != FC.leftParen { return false }
            i += 1
            skipSpaces(&i, end)
            if i >= end || bytes[i] != FC.rightParen { return false }
            i += 1
            return true
        }

        func hasBraceHereOrNextLine(after index0: Int, lineIndex: Int, lineEnd: Int) -> Bool {
            var i = index0
            skipSpaces(&i, lineEnd)
            if i < lineEnd && bytes[i] == FC.leftBrace { return true }
            if i < lineEnd { return false } // other tokens exist on same line

            // next line: "{" alone (allow spaces + optional trailing comment)
            let nextLine = lineIndex + 1
            let lineCount = newlineIndices.count + 1
            if nextLine >= lineCount { return false }

            let nextStart = (nextLine == 0) ? 0 : (newlineIndices[nextLine - 1] + 1)
            let nextEnd = (nextLine < newlineIndices.count) ? newlineIndices[nextLine] : n

            var p = nextStart
            skipSpaces(&p, nextEnd)
            if p >= nextEnd || bytes[p] != FC.leftBrace { return false }
            p += 1
            skipSpaces(&p, nextEnd)
            if p >= nextEnd { return true }
            // allow "{   # comment"
            if bytes[p] == FC.numeric { return true }   // '#' is FC.numeric
            return false
        }

        let lineCount = newlineIndices.count + 1

        for lineIndex in 0..<lineCount {
            let lineStart = (lineIndex == 0) ? 0 : (newlineIndices[lineIndex - 1] + 1)
            let lineEnd = (lineIndex < newlineIndices.count) ? newlineIndices[lineIndex] : n
            if lineStart >= lineEnd { continue }

            let startState: KEndState = (lineIndex == 0) ? .neutral : _lines[lineIndex - 1].endState
            if startState != .neutral { continue }

            var i = lineStart
            skipSpaces(&i, lineEnd)
            if i >= lineEnd { continue }

            // comment line
            if bytes[i] == FC.numeric { continue } // '#'

            // ---- pattern A: function NAME [()] [{ or nextline {] ----
            if matchBytes(functionBytes, at: i, end: lineEnd),
               isKeywordBoundary(i + functionBytes.count, end: lineEnd) {

                i += functionBytes.count
                skipSpaces(&i, lineEnd)

                guard let nameRange = parseIdentName(start: i, end: lineEnd) else { continue }
                i = nameRange.upperBound

                var p = i
                _ = matchParenPair(&p, lineEnd) // optional "()"
                if hasBraceHereOrNextLine(after: p, lineIndex: lineIndex, lineEnd: lineEnd) {
                    items.append(KOutlineItem(kind: .method, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }

            // ---- pattern B: NAME () [{ or nextline {] ----
            guard let nameRange = parseIdentName(start: i, end: lineEnd) else { continue }
            var p = nameRange.upperBound
            if !matchParenPair(&p, lineEnd) { continue }

            if hasBraceHereOrNextLine(after: p, lineIndex: lineIndex, lineEnd: lineEnd) {
                items.append(KOutlineItem(kind: .method, nameRange: nameRange, level: 0, isSingleton: false))
            }
        }

        return items
    }

    // MARK: - Scanning

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        if _lines.isEmpty { return }

        var state: KEndState = (startLine > 0) ? _lines[startLine - 1].endState : .neutral

        var line = startLine
        while line < _lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let old = _lines[line].endState
            let new = scanOneLine(lineRange: lineRange, startState: state)

            _lines[line].endState = new
            state = new

            if line >= minLine && new == old {
                break
            }

            line += 1
        }
    }

    private func scanOneLine(lineRange: Range<Int>, startState: KEndState) -> KEndState {
        if lineRange.isEmpty { return startState }

        switch startState {
        case .inHeredoc(let queue0, let active0):
            var queue = queue0
            var active = active0

            if active == nil, !queue.isEmpty {
                active = queue[0]
            }

            if let a = active {
                if isHeredocTerminatorLine(lineRange: lineRange, entry: a) {
                    if !queue.isEmpty { queue.removeFirst() }
                    active = nil

                    if queue.isEmpty {
                        return .neutral
                    } else {
                        return .inHeredoc(queue: queue, active: nil)
                    }
                }
                return .inHeredoc(queue: queue, active: active)
            }

            if queue.isEmpty { return .neutral }
            return .inHeredoc(queue: queue, active: nil)

        case .inCommandSubstitution(let depth, let quote):
            return scanLineForMultiLineState(lineRange: lineRange,
                                             startInSingleQuote: false,
                                             startInDoubleQuote: false,
                                             startInCommandSubstitution: (depth: depth, quote: quote),
                                             startInCasePattern: false)

        case .inSingleQuote:
            return scanLineForMultiLineState(lineRange: lineRange,
                                             startInSingleQuote: true,
                                             startInDoubleQuote: false,
                                             startInCommandSubstitution: nil,
                                             startInCasePattern: false)

        case .inDoubleQuote:
            return scanLineForMultiLineState(lineRange: lineRange,
                                             startInSingleQuote: false,
                                             startInDoubleQuote: true,
                                             startInCommandSubstitution: nil,
                                             startInCasePattern: false)

        case .inCasePattern:
            return scanLineForMultiLineState(lineRange: lineRange,
                                             startInSingleQuote: false,
                                             startInDoubleQuote: false,
                                             startInCommandSubstitution: nil,
                                             startInCasePattern: true)

        case .neutral:
            return scanLineForMultiLineState(lineRange: lineRange,
                                             startInSingleQuote: false,
                                             startInDoubleQuote: false,
                                             startInCommandSubstitution: nil,
                                             startInCasePattern: false)
        }
    }

    private func scanLineForMultiLineState(lineRange: Range<Int>,
                                           startInSingleQuote: Bool,
                                           startInDoubleQuote: Bool,
                                           startInCommandSubstitution: (depth: Int, quote: KCommandQuoteState)?,
                                           startInCasePattern: Bool) -> KEndState {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound

        // case pattern 継続中：pattern は最初の ')' まで（esac まで維持しない）
        if startInCasePattern {
            var inSingleQuote = false
            var inDoubleQuote = false
            var doubleEscaped = false

            var j = i
            while j < end {
                let b = skeleton[j]

                // comment（クォート外）
                if !inSingleQuote, !inDoubleQuote, b == FC.numeric {
                    break
                }

                if inSingleQuote {
                    if b == FC.singleQuote { inSingleQuote = false }
                    j += 1
                    continue
                }

                if inDoubleQuote {
                    if doubleEscaped {
                        doubleEscaped = false
                        j += 1
                        continue
                    }
                    if b == FC.backSlash {
                        doubleEscaped = true
                        j += 1
                        continue
                    }
                    if b == FC.doubleQuote {
                        inDoubleQuote = false
                        j += 1
                        continue
                    }
                    j += 1
                    continue
                }

                // クォート開始
                if b == FC.singleQuote { inSingleQuote = true; j += 1; continue }
                if b == FC.doubleQuote { inDoubleQuote = true; j += 1; continue }

                // エスケープ（クォート外）
                if b == FC.backSlash {
                    j = min(j + 2, end)
                    continue
                }

                // pattern 終端
                if b == FC.rightParen {
                    return .neutral
                }

                j += 1
            }

            return .inCasePattern
        }

        // $(...) 継続（行全体が command substitution の途中として扱う）
        if let cs = startInCommandSubstitution {
            let result = scanCommandSubstitutionStateInLine(startIndex: i, end: end, depth: cs.depth, quote: cs.quote)
            if result.depth == 0 {
                return .neutral
            } else {
                return .inCommandSubstitution(depth: result.depth, quote: result.quote)
            }
        }

        // 行頭がすでに quote 継続なら、この行で閉じを探す
        if startInSingleQuote {
            switch skeleton.scan(in: i..<end, targets: [FC.singleQuote], escape: FC.backSlash) {
            case .notFound:
                return .inSingleQuote
            case .hit(let index, _):
                i = index + 1
            }
        } else if startInDoubleQuote {
            if let next = findClosingDoubleQuoteInContinuation(startIndex: i, end: end) {
                i = next
            } else {
                return .inDoubleQuote
            }
        }

        var sawCase = false
        var sawInAfterCase = false
        var sawRightParenAfterIn = false

        // case ... in を検出する（クォート・コメントを雑にでも避ける）
        var inSingleQuote = false
        var inDoubleQuote = false
        var doubleEscaped = false

        var j = i
        while j < end {
            let b = skeleton[j]

            // comment（クォート外）
            if !inSingleQuote, !inDoubleQuote, b == FC.numeric {
                break
            }

            if inSingleQuote {
                if b == FC.singleQuote { inSingleQuote = false }
                j += 1
                continue
            }

            if inDoubleQuote {
                if doubleEscaped {
                    doubleEscaped = false
                    j += 1
                    continue
                }
                if b == FC.backSlash {
                    doubleEscaped = true
                    j += 1
                    continue
                }
                if b == FC.doubleQuote {
                    inDoubleQuote = false
                    j += 1
                    continue
                }
                j += 1
                continue
            }

            // クォート開始
            if b == FC.singleQuote { inSingleQuote = true; j += 1; continue }
            if b == FC.doubleQuote { inDoubleQuote = true; j += 1; continue }

            // エスケープ（クォート外）
            if b == FC.backSlash {
                j = min(j + 2, end)
                continue
            }

            // pattern の ')'（case ... in の同一行に来た場合）
            if b == FC.rightParen, sawInAfterCase {
                sawRightParenAfterIn = true
                j += 1
                continue
            }

            // 識別子
            if b.isIdentStartAZ_ {
                var k = j + 1
                while k < end, skeleton[k].isIdentPartAZ09_ { k += 1 }

                // "case"
                if (k - j) == 4,
                   skeleton[j] == 99, skeleton[j + 1] == 97, skeleton[j + 2] == 115, skeleton[j + 3] == 101 {
                    sawCase = true
                    j = k
                    continue
                }

                // "in"（case の後だけ）
                if sawCase, (k - j) == 2,
                   skeleton[j] == 105, skeleton[j + 1] == 110 {
                    sawInAfterCase = true
                    j = k
                    continue
                }

                j = k
                continue
            }

            j += 1
        }

        // case ... in を検出したら pattern 状態に入る（ただし同一行で ')' まで出たなら入らない）
        if sawCase, sawInAfterCase, !sawRightParenAfterIn {
            return .inCasePattern
        }

        return .neutral
    }

    // MARK: - Coloring + endState (single pass for one visual line)

    @discardableResult
    private func parseLine(lineRange: Range<Int>,
                           clampTo requested: Range<Int>,
                           startState: KEndState,
                           collectSpans: Bool,
                           spans: inout [KAttributedSpan]) -> KEndState {

        let skeleton = storage.skeletonString
        let end = min(lineRange.upperBound, skeleton.count)
        var i = max(lineRange.lowerBound, 0)

        var pendingHeredocs: [KHeredocEntry] = []
        var nextStateFromCase: KEndState? = nil

        @inline(__always)
        func addSpan(_ r: Range<Int>, _ role: KFunctionalColor) {
            if !collectSpans { return }
            if r.isEmpty { return }

            let lower = max(r.lowerBound, requested.lowerBound)
            let upper = min(r.upperBound, requested.upperBound)
            if lower >= upper { return }

            spans.append(makeSpan(range: lower..<upper, role: role))
        }

        // heredoc 本文
        if case .inHeredoc(let queue0, let active0) = startState {
            var queue = queue0
            var active = active0

            if active == nil, !queue.isEmpty {
                active = queue[0]
            }

            addSpan(i..<end, .string)

            if let a = active {
                if isHeredocTerminatorLine(lineRange: i..<end, entry: a) {
                    if !queue.isEmpty { queue.removeFirst() }
                    active = nil
                    if queue.isEmpty {
                        return .neutral
                    } else {
                        return .inHeredoc(queue: queue, active: nil)
                    }
                }
                return .inHeredoc(queue: queue, active: active)
            }

            if queue.isEmpty { return .neutral }
            return .inHeredoc(queue: queue, active: nil)
        }
        
        // case pattern 中：パターン部は解析しない。
        // ただし "esac" 行に来たらこの行で neutral に戻す（後方まで塗り続けないため）
        if startState == .inCasePattern {

            // 行内に "esac" があるかだけを見る（識別子として検出）
            var foundEsac = false
            var j = i
            while j < end {
                let bb = skeleton[j]
                if bb.isIdentStartAZ_ {
                    var k = j + 1
                    while k < end, skeleton[k].isIdentPartAZ09_ { k += 1 }

                    if (k - j) == 4,
                       skeleton[j] == 101, skeleton[j + 1] == 115, skeleton[j + 2] == 97, skeleton[j + 3] == 99 {
                        foundEsac = true
                        break
                    }

                    j = k
                    continue
                }
                j += 1
            }

            if !foundEsac {
                // 解析はしないが、属性を正規化するため base で必ず塗る
                addSpan(i..<end, .base)
                return .inCasePattern
            }

            // "esac" 行：この行は以降を通常解析に任せる（ここで return しない）
            // ＝後方まで .inCasePattern が伝播しない
        }
        
        // $(...) 継続：parse 側は中身を深追いしないが、quote 継続は反映する
        if case .inCommandSubstitution(let depth, let quote) = startState {
            // sed " ... のように $(...) 内で quote が継続している場合は string 扱いにする
            if quote == .none {
                addSpan(i..<end, .variable)
            } else {
                addSpan(i..<end, .string)
            }

            // endState は scan 側のロジックで更新
            return scanLineForMultiLineState(lineRange: i..<end,
                                             startInSingleQuote: false,
                                             startInDoubleQuote: false,
                                             startInCommandSubstitution: (depth: depth, quote: quote),
                                             startInCasePattern: false)
        }

        // quote 継続：まず閉じまでを string として塗る
        if startState == .inSingleQuote {
            switch skeleton.scan(in: i..<end, targets: [FC.singleQuote], escape: FC.backSlash) {
            case .notFound:
                addSpan(i..<end, .string)
                return .inSingleQuote
            case .hit(let index, _):
                addSpan(i..<(index + 1), .string)
                i = index + 1
            }
        } else if startState == .inDoubleQuote {
            if let next = findClosingDoubleQuoteInContinuation(startIndex: i, end: end) {
                addSpan(i..<next, .string)
                i = next
            } else {
                addSpan(i..<end, .string)
                return .inDoubleQuote
            }
        }

        // 残り走査
        while i < end {
            let b = skeleton[i]

            // comment（クォート外）
            if b == FC.numeric {
                addSpan(i..<end, .comment)
                break
            }

            // $() / $(( ))：中身は走査しない（中の " に引っ張られない）
            if b == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftParen {

                // 1) $((...)) を優先（算術展開）
                if (i + 2) < end, skeleton[i + 2] == FC.leftParen {
                    if let nextIndex = skipArithmeticExpansionInLineSh(startingAtDollar: i, end: end) {
                        addSpan(i..<nextIndex, .variable)
                        i = nextIndex
                        continue
                    } else {
                        addSpan(i..<end, .variable)
                        // 多行は追わない（state も持たない）
                        return .neutral
                    }
                }

                // 2) $(...)（コマンド置換）
                if let nextIndex = skipCommandSubstitutionInLineSh(startingAtDollar: i, end: end) {
                    addSpan(i..<nextIndex, .variable)
                    i = nextIndex
                    continue
                } else {
                    // ★ここが重要：neutral に落とさず、inCommandSubstitution に入る
                    addSpan(i..<end, .variable)
                    if let st = startCommandSubstitutionStateInLine(dollarIndex: i, end: end) {
                        return .inCommandSubstitution(depth: st.depth, quote: st.quote)
                    } else {
                        return .inCommandSubstitution(depth: 1, quote: .none)
                    }
                }
            }
            
            // $'...'（ANSI-C quoting）を文字列として扱う
            if b == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: FC.singleQuote, in: (i + 1)..<end, escape: FC.backSlash) {
                case .found(let next):
                    addSpan(i..<next, .string)   // $'...' 全体
                    i = next
                    continue
                case .stopped(_), .notFound:
                    addSpan(i..<end, .string)
                    return .neutral
                }
            }

            // single quote
            if b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end, escape: FC.backSlash) {
                case .found(let next):
                    addSpan(i..<next, .string)
                    i = next
                    continue
                case .stopped(_), .notFound:
                    addSpan(i..<end, .string)
                    return .inSingleQuote
                }
            }

            // double quote (Shell)
            if b == FC.doubleQuote {
                if let next = skipDoubleQuotedInLineSh(in: i..<end) {
                    addSpan(i..<next, .string)
                    i = next
                    continue
                } else {
                    addSpan(i..<end, .string)
                    return .inDoubleQuote
                }
            }

            // heredoc start
            if b == FC.lt, (i + 1) < end, skeleton[i + 1] == FC.lt {
                let (entry, nextIndex) = parseHeredocStart(lineRange: i..<end, at: i)
                if let e = entry { pendingHeredocs.append(e) }
                i = max(nextIndex, i + 2)
                continue
            }

            // variable（${...}, $NAME など）
            if b == FC.dollar {
                if let rr = scanVariableOrSubstitution(lineRange: i..<end, at: i) {
                    addSpan(rr, .variable)
                    i = rr.upperBound
                    continue
                }
            }

            // keyword
            if b.isIdentStartAZ_ {
                var j = i + 1
                while j < end, skeleton[j].isIdentPartAZ09_ { j += 1 }
                let wordRange = i..<j
                if skeleton.matches(words: keywords, in: wordRange) {
                    addSpan(wordRange, .keyword)
                }
                // "case" を見たら、この行内に "in" があるか探す（簡易）
                if (j - i) == 4,
                   skeleton[i] == 99, skeleton[i + 1] == 97, skeleton[i + 2] == 115, skeleton[i + 3] == 101 {

                    var p = j
                    while p < end {
                        let cc = skeleton[p]
                        if cc.isIdentStartAZ_ {
                            var q = p + 1
                            while q < end, skeleton[q].isIdentPartAZ09_ { q += 1 }
                            if (q - p) == 2, skeleton[p] == 105, skeleton[p + 1] == 110 {
                                nextStateFromCase = .inCasePattern
                                break
                            }
                            p = q
                            continue
                        }
                        p += 1
                    }
                }
                i = j
                continue
            }

            i += 1
        }

        if !pendingHeredocs.isEmpty {
            return .inHeredoc(queue: pendingHeredocs, active: nil)
        }
        
        if let s = nextStateFromCase {
            return s
        }
        
        return .neutral
    }
    
    // MARK: - Helpers (quote, sh)

    // ダブルクォート内を走査し、対応する " を見つけたらその次の index を返す。
    // Shell の $(...) を考慮し、$(...) 内の " では閉じない。
    // 見つからなければ nil（= 行内に閉じが無い）
    private func skipDoubleQuotedInLineSh(in range: Range<Int>) -> Int? {
        let skeleton = storage.skeletonString
        let end = range.upperBound
        var i = range.lowerBound

        // range.lowerBound は " の位置の前提
        if i >= end { return nil }
        if skeleton[i] != FC.doubleQuote { return nil }

        i += 1

        while i < end {
            let b = skeleton[i]

            // \" など（最低限、次の1文字を飛ばす）
            if b == FC.backSlash {
                if i + 1 < end {
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            // $(...) をスキップ（中の " は外側を閉じない）
            if b == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftParen {
                // "$((" は算術展開
                if (i + 2) < end, skeleton[i + 2] == FC.leftParen {
                    if let next = skipArithmeticExpansionInLineSh(startingAtDollar: i, end: end) {
                        i = next
                        continue
                    }
                    return nil
                }

                // "$(" はコマンド置換
                if let next = skipCommandSubstitutionInLineSh(startingAtDollar: i, end: end) {
                    i = next
                    continue
                }
                return nil
            }

            // 閉じ "
            if b == FC.doubleQuote {
                return i + 1
            }

            i += 1
        }

        return nil
    }

    // ダブルクォート継続中（行頭が " とは限らない）で、この行内の閉じ " を探す。
    // 見つかれば「閉じ " の次 index」を返す。見つからなければ nil。
    // 途中の $(...) は中身をスキップし、その中の " で閉じない。
    private func findClosingDoubleQuoteInContinuation(startIndex: Int, end: Int) -> Int? {
        let skeleton = storage.skeletonString
        var i = startIndex

        while i < end {
            let b = skeleton[i]

            // エスケープ
            if b == FC.backSlash {
                if i + 1 < end { i += 2 } else { i += 1 }
                continue
            }

            // ${...} を飛ばす（中で $(), $(( )) があっても崩れないように）
            if b == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftBrace {
                // ここは scanVariableOrSubstitution を使う（すでに ${...} 強化済みの前提）
                if let rr = scanVariableOrSubstitution(lineRange: i..<end, at: i) {
                    i = rr.upperBound
                    continue
                }
                return nil
            }

            // $((...)) を優先
            if b == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftParen {
                if (i + 2) < end, skeleton[i + 2] == FC.leftParen {
                    if let nextIndex = skipArithmeticExpansionInLineSh(startingAtDollar: i, end: end) {
                        i = nextIndex
                        continue
                    }
                    return nil
                }

                // $(...) コマンド置換
                if let nextIndex = skipCommandSubstitutionInLineSh(startingAtDollar: i, end: end) {
                    i = nextIndex
                    continue
                }
                return nil
            }

            // 閉じ "
            if b == FC.doubleQuote {
                return i + 1
            }

            i += 1
        }

        return nil
    }

    // "$(" から始まる command substitution を、対応する ")" までスキップして次 index を返す。
    // 行内で閉じなければ nil。
    private func skipCommandSubstitutionInLineSh(startingAtDollar dollarIndex: Int, end: Int) -> Int? {
        let skeleton = storage.skeletonString

        // "$(" の前提
        if dollarIndex + 1 >= end { return nil }
        if skeleton[dollarIndex] != FC.dollar { return nil }
        if skeleton[dollarIndex + 1] != FC.leftParen { return nil }

        var depth = 1
        var i = dollarIndex + 2

        while i < end {
            let b = skeleton[i]

            // single quote: 次の ' まで（エスケープなし）
            if b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end, escape: nil) {
                case .found(let next):
                    i = next
                    continue
                case .stopped(_), .notFound:
                    return nil
                }
            }

            // double quote: Shell 仕様で " を探す（$(...) を考慮）
            if b == FC.doubleQuote {
                if let next = skipDoubleQuotedInLineSh(in: i..<end) {
                    i = next
                    continue
                } else {
                    return nil
                }
            }

            // ネストする $(...)
            if b == FC.dollar, i + 1 < end, skeleton[i + 1] == FC.leftParen {
                depth += 1
                i += 2
                continue
            }

            // 対応する ")"
            if b == FC.rightParen {
                depth -= 1
                i += 1
                if depth == 0 {
                    return i
                }
                continue
            }

            // ざっくりエスケープ
            if b == FC.backSlash {
                if i + 1 < end {
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            i += 1
        }

        return nil
    }
    
    // "$(( ... ))" を行内で閉じる範囲までスキップして次 index を返す。閉じなければ nil。
    private func skipArithmeticExpansionInLineSh(startingAtDollar dollarIndex: Int, end: Int) -> Int? {
        let skeleton = storage.skeletonString
        if dollarIndex + 2 >= end { return nil }
        if skeleton[dollarIndex] != FC.dollar { return nil }
        if skeleton[dollarIndex + 1] != FC.leftParen { return nil }
        if skeleton[dollarIndex + 2] != FC.leftParen { return nil }   // "$(("

        var depth = 1
        var i = dollarIndex + 3

        while i < end {
            let b = skeleton[i]

            // 中の '...' / "..." は飛ばす（"..." では $(...) も考慮）
            if b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end, escape: FC.backSlash) {
                case .found(let next): i = next; continue
                case .stopped(_), .notFound: return nil
                }
            }
            if b == FC.doubleQuote {
                if let next = skipDoubleQuotedInLineSh(in: i..<end) { i = next; continue }
                return nil
            }

            // ネストする "((" は深さ+1
            if b == FC.leftParen, (i + 1) < end, skeleton[i + 1] == FC.leftParen {
                depth += 1
                i += 2
                continue
            }

            // 閉じる "))" は深さ-1、0になったら終了
            if b == FC.rightParen, (i + 1) < end, skeleton[i + 1] == FC.rightParen {
                depth -= 1
                i += 2
                if depth == 0 { return i }
                continue
            }

            // ざっくりエスケープ
            if b == FC.backSlash {
                if i + 1 < end { i += 2 } else { i += 1 }
                continue
            }

            i += 1
        }

        return nil
    }
    
    // command substitution 内を 1 行分走査し、(depth, quote) を更新して返す。
    // startIndex はこの行内の開始位置。
    // end に到達した時点の状態を返す（閉じ切っていれば depth == 0）。
    private func scanCommandSubstitutionStateInLine(startIndex: Int, end: Int, depth: Int, quote: KCommandQuoteState) -> (depth: Int, quote: KCommandQuoteState) {
        let skeleton = storage.skeletonString

        var d = depth
        var q = quote
        var i = startIndex

        while i < end {
            let b = skeleton[i]

            // quote 継続中
            if q == .single {
                switch skeleton.scan(in: i..<end, targets: [FC.singleQuote], escape: nil) {
                case .notFound:
                    return (d, .single)
                case .hit(let index, _):
                    i = index + 1
                    q = .none
                    continue
                }
            } else if q == .double {
                // " の中身位置(i)から閉じ " を探す（$(), $(( )), ${} も安全にスキップ）
                if let next = findClosingDoubleQuoteInContinuation(startIndex: i, end: end) {
                    i = next          // next は閉じ " の次
                    q = .none
                    continue
                } else {
                    return (d, .double)
                }
            }

            // コメント（command substitution 中でも # はここではコメント扱いにしない。必要なら後で検討）
            // ここでは何もしない。

            // 新規 quote 開始
            if b == FC.singleQuote {
                q = .single
                i += 1
                continue
            }
            if b == FC.doubleQuote {
                q = .double
                i += 1
                continue
            }

            // ネストする $(...)
            if b == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftParen {
                d += 1
                i += 2
                continue
            }

            // 閉じ )
            if b == FC.rightParen {
                d -= 1
                i += 1
                if d <= 0 {
                    return (0, .none)
                }
                continue
            }

            // ざっくりエスケープ
            if b == FC.backSlash {
                if i + 1 < end { i += 2 } else { i += 1 }
                continue
            }

            i += 1
        }

        return (d, q)
    }

    // neutral の行内で "$(" を見つけたら開始し、この行末までの state を返す（depth>=1）。
    private func startCommandSubstitutionStateInLine(dollarIndex: Int, end: Int) -> (depth: Int, quote: KCommandQuoteState)? {
        let skeleton = storage.skeletonString
        if dollarIndex + 1 >= end { return nil }
        if skeleton[dollarIndex] != FC.dollar { return nil }
        if skeleton[dollarIndex + 1] != FC.leftParen { return nil }

        return scanCommandSubstitutionStateInLine(startIndex: dollarIndex + 2, end: end, depth: 1, quote: .none)
    }
    
    

    // MARK: - Helpers (heredoc)

    private func isHeredocTerminatorLine(lineRange: Range<Int>, entry: KHeredocEntry) -> Bool {
        let skeleton = storage.skeletonString

        var start = lineRange.lowerBound
        if entry.allowLeadingTabs {
            while start < lineRange.upperBound, skeleton[start] == FC.tab {
                start += 1
            }
        }

        let len = lineRange.upperBound - start
        if len != entry.label.count { return false }
        if entry.label.isEmpty { return false }

        let slice = skeleton.bytes(in: start..<lineRange.upperBound)
        return slice.elementsEqual(entry.label)
    }

    private func parseHeredocStart(lineRange: Range<Int>, at index: Int) -> (KHeredocEntry?, Int) {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        // index は '<'（次も '<' の前提）
        var i = index + 2
        var allowTabs = false

        if i < end, skeleton[i] == FC.minus {
            allowTabs = true
            i += 1
        }

        i = skeleton.skipSpaces(from: i, to: end)
        if i >= end { return (nil, i) }

        // delimiter は quoted / unquoted だが、シェルの厳密ルールまでは追わず「妥当な token」だけ拾う（誤爆回避優先）
        let q = skeleton[i]
        if q == FC.singleQuote || q == FC.doubleQuote {
            // quoted delimiter
            let quote = q
            i += 1
            let labelStart = i

            while i < end {
                if skeleton[i] == quote {
                    let labelEnd = i
                    let labelBytes = Array(skeleton.bytes(in: labelStart..<labelEnd))
                    if labelBytes.isEmpty { return (nil, i + 1) }

                    let e = KHeredocEntry(label: labelBytes, allowLeadingTabs: allowTabs)
                    return (e, i + 1)
                }
                i += 1
            }

            // 閉じ quote が無い：無効扱い
            return (nil, end)
        }

        // unquoted delimiter：空白または簡単な区切りで止める（保守的）
        let labelStart = i
        while i < end {
            let b = skeleton[i]
            if b == FC.space || b == FC.tab { break }
            if b == FC.semicolon || b == FC.pipe || b == FC.ampersand { break }
            if b == FC.lt || b == FC.gt { break }
            if b == FC.leftParen || b == FC.rightParen { break }
            i += 1
        }

        let labelEnd = i
        let labelBytes = Array(skeleton.bytes(in: labelStart..<labelEnd))
        if labelBytes.isEmpty { return (nil, i) }

        let e = KHeredocEntry(label: labelBytes, allowLeadingTabs: allowTabs)
        return (e, i)
    }

    // MARK: - Helpers (variable)

    func scanVariableOrSubstitution(lineRange: Range<Int>, at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        if index >= end { return nil }
        if skeleton[index] != FC.dollar { return nil }

        let next = index + 1
        if next >= end { return index..<(index + 1) }

        let b = skeleton[next]

        // ${...}（Shell寄り：中の "..." / '...' / $() / $(( )) を飛ばしつつ最初の対応 } まで）
        if b == FC.leftBrace {
            var i = next + 1
            var braceDepth = 1

            while i < end {
                let c = skeleton[i]

                // quote を飛ばす
                if c == FC.singleQuote {
                    switch skeleton.skipQuotedInLine(for: c, in: i..<end, escape: FC.backSlash) {
                    case .found(let nextIndex):
                        i = nextIndex
                        continue
                    case .stopped(_), .notFound:
                        return index..<end
                    }
                }

                if c == FC.doubleQuote {
                    if let nextIndex = skipDoubleQuotedInLineSh(in: i..<end) {
                        i = nextIndex
                        continue
                    }
                    return index..<end
                }

                // $((...)) を優先
                if c == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftParen {
                    if (i + 2) < end, skeleton[i + 2] == FC.leftParen {
                        if let nextIndex = skipArithmeticExpansionInLineSh(startingAtDollar: i, end: end) {
                            i = nextIndex
                            continue
                        }
                        return index..<end
                    }
                    if let nextIndex = skipCommandSubstitutionInLineSh(startingAtDollar: i, end: end) {
                        i = nextIndex
                        continue
                    }
                    return index..<end
                }

                // ネストする ${...}（最低限 depth を追う）
                if c == FC.dollar, (i + 1) < end, skeleton[i + 1] == FC.leftBrace {
                    braceDepth += 1
                    i += 2
                    continue
                }

                // 閉じ }
                if c == FC.rightBrace {
                    braceDepth -= 1
                    i += 1
                    if braceDepth == 0 {
                        return index..<i
                    }
                    continue
                }

                // ざっくりエスケープ
                if c == FC.backSlash {
                    if i + 1 < end { i += 2 } else { i += 1 }
                    continue
                }

                i += 1
            }

            return index..<end
        }

        // $(...)（Shell 仕様：中の quote / ネストを考慮して閉じる ) まで）
        if b == FC.leftParen {
            if let nextIndex = skipCommandSubstitutionInLineSh(startingAtDollar: index, end: end) {
                return index..<nextIndex
            }
            return index..<end
        }

        // $NAME
        if b.isIdentStartAZ_ {
            var i = next + 1
            while i < end, skeleton[i].isIdentPartAZ09_ {
                i += 1
            }
            return index..<i
        }

        return index..<(index + 1)
    }
}
