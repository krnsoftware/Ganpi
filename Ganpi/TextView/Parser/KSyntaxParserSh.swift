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

    private enum KEndState: Equatable {
        case neutral
        case inSingleQuote
        case inDoubleQuote
        case inHeredoc(queue: [KHeredocEntry], active: KHeredocEntry?)
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
        let startState: KEndState = (lineIndex > 0 && lineIndex - 1 < _lines.count) ? _lines[lineIndex - 1].endState : .neutral

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(8)

        _ = parseLine(lineRange: lineRange,
                      clampTo: range,
                      startState: startState,
                      collectSpans: true,
                      spans: &spans)

        return spans
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

        case .inSingleQuote:
            return scanLineForMultiLineState(lineRange: lineRange, startInSingleQuote: true, startInDoubleQuote: false)

        case .inDoubleQuote:
            return scanLineForMultiLineState(lineRange: lineRange, startInSingleQuote: false, startInDoubleQuote: true)

        case .neutral:
            return scanLineForMultiLineState(lineRange: lineRange, startInSingleQuote: false, startInDoubleQuote: false)
        }
    }

    private func scanLineForMultiLineState(lineRange: Range<Int>, startInSingleQuote: Bool, startInDoubleQuote: Bool) -> KEndState {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound
        var pendingHeredocs: [KHeredocEntry] = []

        // 行頭がすでに quote 継続なら、この行で閉じを探す
        if startInSingleQuote || startInDoubleQuote {
            let quote = startInDoubleQuote ? FC.doubleQuote : FC.singleQuote
            let escape: UInt8? = startInDoubleQuote ? FC.backSlash : nil

            switch skeleton.scan(in: i..<end, targets: [quote], escape: escape) {
            case .notFound:
                return startInDoubleQuote ? .inDoubleQuote : .inSingleQuote
            case .hit(let index, _):
                i = index + 1
            }
        }

        while i < end {
            let b = skeleton[i]

            // comment
            if b == FC.numeric {
                break
            }

            // quote: 単行で閉じるなら飛ばす。閉じなければ endState
            if b == FC.singleQuote || b == FC.doubleQuote {
                let escape: UInt8? = (b == FC.doubleQuote) ? FC.backSlash : nil
                switch skeleton.skipQuotedInLine(for: b, in: i..<end, escape: escape) {
                case .found(let next):
                    i = next
                    continue
                case .stopped(_):
                    return (b == FC.doubleQuote) ? .inDoubleQuote : .inSingleQuote
                case .notFound:
                    return (b == FC.doubleQuote) ? .inDoubleQuote : .inSingleQuote
                }
            }

            // heredoc start: << or <<-
            if b == FC.lt, (i + 1) < end, skeleton[i + 1] == FC.lt {
                let (entry, nextIndex) = parseHeredocStart(lineRange: i..<end, at: i)
                if let e = entry {
                    pendingHeredocs.append(e)
                }
                i = max(nextIndex, i + 2)
                continue
            }

            i += 1
        }

        if !pendingHeredocs.isEmpty {
            return .inHeredoc(queue: pendingHeredocs, active: nil)
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

        @inline(__always)
        func addSpan(_ r: Range<Int>, _ role: KFunctionalColor) {
            if !collectSpans { return }
            if r.isEmpty { return }

            let lower = max(r.lowerBound, requested.lowerBound)
            let upper = min(r.upperBound, requested.upperBound)
            if lower >= upper { return }

            spans.append(makeSpan(range: lower..<upper, role: role))
        }

        // 1) heredoc 本文：行全体を string で塗る（次行以降の終端判定は scanOneLine と一致させる）
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

        // 2) quote 継続の場合：まず閉じまでを string として塗る
        if startState == .inSingleQuote || startState == .inDoubleQuote {
            let quote = (startState == .inDoubleQuote) ? FC.doubleQuote : FC.singleQuote
            let escape: UInt8? = (startState == .inDoubleQuote) ? FC.backSlash : nil

            switch skeleton.scan(in: i..<end, targets: [quote], escape: escape) {
            case .notFound:
                addSpan(i..<end, .string)
                return startState
            case .hit(let index, _):
                addSpan(i..<(index + 1), .string)
                i = index + 1
            }
        }

        // 3) 残り（neutral）を走査：comment / quote / heredoc / variable / keyword
        while i < end {
            let b = skeleton[i]

            // comment（クォート外の # から行末）
            if b == FC.numeric {
                addSpan(i..<end, .comment)
                break
            }

            // quote（単行で閉じれば string span、閉じなければ複数行へ）
            if b == FC.singleQuote || b == FC.doubleQuote {
                let escape: UInt8? = (b == FC.doubleQuote) ? FC.backSlash : nil
                switch skeleton.skipQuotedInLine(for: b, in: i..<end, escape: escape) {
                case .found(let next):
                    addSpan(i..<next, .string)
                    i = next
                    continue
                case .stopped(_):
                    addSpan(i..<end, .string)
                    return (b == FC.doubleQuote) ? .inDoubleQuote : .inSingleQuote
                case .notFound:
                    addSpan(i..<end, .string)
                    return (b == FC.doubleQuote) ? .inDoubleQuote : .inSingleQuote
                }
            }

            // heredoc start: << or <<-
            if b == FC.lt, (i + 1) < end, skeleton[i + 1] == FC.lt {
                let (entry, nextIndex) = parseHeredocStart(lineRange: i..<end, at: i)
                if let e = entry {
                    pendingHeredocs.append(e)
                }
                i = max(nextIndex, i + 2)
                continue
            }

            // variable (shallow)
            if b == FC.dollar {
                if let rr = scanVariableOrSubstitution(lineRange: i..<end, at: i) {
                    addSpan(rr, .variable)
                    i = rr.upperBound
                    continue
                }
                i += 1
                continue
            }

            // reserved word（ASCII ident）
            if b.isIdentStartAZ_ {
                var j = i + 1
                while j < end, skeleton[j].isIdentPartAZ09_ {
                    j += 1
                }
                let wordRange = i..<j
                if skeleton.matches(words: keywords, in: wordRange) {
                    addSpan(wordRange, .keyword)
                }
                i = j
                continue
            }

            i += 1
        }

        if !pendingHeredocs.isEmpty {
            return .inHeredoc(queue: pendingHeredocs, active: nil)
        }

        return .neutral
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

    private func scanVariableOrSubstitution(lineRange: Range<Int>, at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        if index >= end { return nil }
        if skeleton[index] != FC.dollar { return nil }

        let next = index + 1
        if next >= end { return index..<(index + 1) }

        let b = skeleton[next]

        // ${...}
        if b == FC.leftBrace {
            var i = next + 1
            while i < end {
                if skeleton[i] == FC.rightBrace {
                    return index..<(i + 1)
                }
                i += 1
            }
            return index..<end
        }

        // $(...)
        if b == FC.leftParen {
            var i = next + 1
            while i < end {
                if skeleton[i] == FC.rightParen {
                    return index..<(i + 1)
                }
                i += 1
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
