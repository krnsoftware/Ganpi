//
//  KSyntaxParserHtml.swift
//  Ganpi
//
//  Created by KARINO Masatsugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

final class KSyntaxParserHtml: KSyntaxParser {

    // MARK: - Types

    private enum KTagOpenKind: Equatable {
        case normal
        case script
        case style
    }

    private enum KEndState: Equatable {
        case neutral
        case inComment
        case inScript
        case inStyle
        case inTag(kind: KTagOpenKind)
        case inTagQuote(kind: KTagOpenKind, quote: UInt8)
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    private let _commentStartBytes: [UInt8] = [FC.lt, FC.exclamation, FC.minus, FC.minus] // <!--
    private let _commentEndBytes:   [UInt8] = [FC.minus, FC.minus, FC.gt]                // -->

    private let _scriptLower: [UInt8] = Array("script".utf8)
    private let _styleLower:  [UInt8] = Array("style".utf8)

    // MARK: - Init

    override init(storage: KTextStorageReadable, type: KSyntaxType = .html) {
        super.init(storage: storage, type: type)
    }

    // MARK: - Override

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            let _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        if plan.lineDelta != 0 {
            applyLineDelta(lines: &_lines,
                           spliceIndex: plan.spliceIndex,
                           lineDelta: plan.lineDelta) { KLineInfo(endState: .neutral) }
        }

        let rebuilt = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
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

        let skeleton = storage.skeletonString
        let lineRange = skeleton.lineRange(contains: range)
        guard !lineRange.isEmpty else { return [] }

        let lineIndex = skeleton.lineIndex(at: lineRange.lowerBound)
        let startState: KEndState = (lineIndex > 0 && lineIndex - 1 < _lines.count) ? _lines[lineIndex - 1].endState : .neutral

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(8)

        _ = parseLine(lineRange: lineRange, clampTo: range, startState: startState, collectSpans: true, spans: &spans)
        return spans
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
            var dummySpans: [KAttributedSpan] = []
            let new = parseLine(lineRange: lineRange, clampTo: lineRange, startState: state, collectSpans: false, spans: &dummySpans)


            _lines[line].endState = new
            state = new

            if line >= minLine && new == old {
                break
            }

            line += 1
        }
    }

    @discardableResult
    private func parseLine(lineRange: Range<Int>,
                           clampTo requested: Range<Int>,
                           startState: KEndState,
                           collectSpans: Bool,
                           spans: inout [KAttributedSpan]) -> KEndState {

        let skeleton = storage.skeletonString
        let end = min(lineRange.upperBound, skeleton.count)
        var i = max(lineRange.lowerBound, 0)

        var state = startState

        @inline(__always)
        func addSpan(_ r: Range<Int>, _ role: KFunctionalColor) {
            if !collectSpans { return }
            if r.isEmpty { return }

            let lower = max(r.lowerBound, requested.lowerBound)
            let upper = min(r.upperBound, requested.upperBound)
            if lower >= upper { return }

            spans.append(makeSpan(range: lower..<upper, role: role))
        }

        while i < end {

            switch state {

            case .inComment:
                if let close = findSequence(_commentEndBytes, from: i, to: end, skeleton: skeleton) {
                    let closeEnd = min(close + _commentEndBytes.count, end)
                    addSpan(i..<closeEnd, .comment)
                    i = closeEnd
                    state = .neutral
                } else {
                    addSpan(i..<end, .comment)
                    i = end
                }

            case .inScript:
                if let closeTagStart = findCloseTagStart(nameLower: _scriptLower, from: i, to: end, skeleton: skeleton) {
                    i = closeTagStart
                    state = .neutral
                } else {
                    i = end
                }

            case .inStyle:
                if let closeTagStart = findCloseTagStart(nameLower: _styleLower, from: i, to: end, skeleton: skeleton) {
                    i = closeTagStart
                    state = .neutral
                } else {
                    i = end
                }

            case .inTagQuote(let kind, let quote):
                if let q = findByte(quote, from: i, to: end, skeleton: skeleton) {
                    let qEnd = min(q + 1, end)
                    addSpan(i..<qEnd, .string)
                    i = qEnd
                    state = .inTag(kind: kind)
                } else {
                    addSpan(i..<end, .string)
                    i = end
                }

            case .inTag(let kind):
                let result = parseTagBody(from: i,
                                          to: end,
                                          skeleton: skeleton,
                                          clampTo: requested,
                                          kind: kind,
                                          collectSpans: collectSpans,
                                          addSpan: { r, role in addSpan(r, role) })
                i = result.nextIndex
                state = result.endState

            case .neutral:
                let b = skeleton[i]

                if b == FC.ampersand {
                    if let entityEnd = parseEntity(from: i, to: end, skeleton: skeleton) {
                        addSpan(i..<entityEnd, .number)
                        i = entityEnd
                    } else {
                        i += 1
                    }
                    continue
                }

                if b == FC.lt {
                    // comment
                    if i + _commentStartBytes.count <= end,
                       matchesPrefixIgnoreCase(_commentStartBytes, at: i, skeleton: skeleton, to: end) {

                        if let close = findSequence(_commentEndBytes,
                                                   from: i + _commentStartBytes.count,
                                                   to: end,
                                                   skeleton: skeleton) {
                            let closeEnd = min(close + _commentEndBytes.count, end)
                            addSpan(i..<closeEnd, .comment)
                            i = closeEnd
                            state = .neutral
                        } else {
                            addSpan(i..<end, .comment)
                            i = end
                            state = .inComment
                        }
                        continue
                    }

                    // tag / declaration
                    let parsed = parseTag(from: i,
                                          to: end,
                                          skeleton: skeleton,
                                          clampTo: requested,
                                          collectSpans: collectSpans,
                                          addSpan: { r, role in addSpan(r, role) })
                    i = parsed.nextIndex
                    state = parsed.endState
                    continue
                }

                i += 1
            }
        }

        return state
    }

    // MARK: - Tag parsing

    private func parseTag(from index: Int,
                          to end: Int,
                          skeleton: KSkeletonString,
                          clampTo requested: Range<Int>,
                          collectSpans: Bool,
                          addSpan: (Range<Int>, KFunctionalColor) -> Void) -> (nextIndex: Int, endState: KEndState) {

        var i = index
        let tagStart = i

        // '<'
        i += 1

        // '</' / '<!' / '<?'
        var prefix: UInt8? = nil
        if i < end {
            let p = skeleton[i]
            if p == FC.slash || p == FC.exclamation || p == FC.question {
                prefix = p
                i += 1
            }
        }

        addSpan(tagStart..<i, .tag)

        let nameStart = i
        if i < end, isHtmlNameStart(skeleton[i]) {
            i += 1
            while i < end, isHtmlNamePart(skeleton[i]) {
                i += 1
            }
        }

        if i > nameStart {
            // 要素名・宣言名は .keyword
            addSpan(nameStart..<i, .keyword)
        }

        // 開きタグのみ script/style を判定（閉じタグや <! ... は除外）
        var kind: KTagOpenKind = .normal
        if prefix != FC.slash, prefix != FC.exclamation {
            if isWordIgnoreCase(_scriptLower, in: nameStart..<i, skeleton: skeleton) {
                kind = .script
            } else if isWordIgnoreCase(_styleLower, in: nameStart..<i, skeleton: skeleton) {
                kind = .style
            }
        }

        // タグ本文へ
        let body = parseTagBody(from: i,
                                to: end,
                                skeleton: skeleton,
                                clampTo: requested,
                                kind: kind,
                                collectSpans: collectSpans,
                                addSpan: addSpan)

        return (nextIndex: body.nextIndex, endState: body.endState)
    }

    private func parseTagBody(from index: Int,
                              to end: Int,
                              skeleton: KSkeletonString,
                              clampTo requested: Range<Int>,
                              kind: KTagOpenKind,
                              collectSpans: Bool,
                              addSpan: (Range<Int>, KFunctionalColor) -> Void) -> (nextIndex: Int, endState: KEndState) {

        var i = index
        var state: KEndState = .inTag(kind: kind)

        while i < end {
            let b = skeleton[i]

            if b == FC.gt {
                addSpan(i..<min(i + 1, end), .tag)
                i += 1
                switch kind {
                case .script: return (i, .inScript)
                case .style: return (i, .inStyle)
                case .normal: return (i, .neutral)
                }
            }

            // '=' を伴わないクオート文字列（DOCTYPE の PUBLIC "..." "..." など）も .string 扱い
            if b == FC.doubleQuote || b == FC.singleQuote {
                let quote = b
                let start = i
                i += 1
                while i < end, skeleton[i] != quote {
                    i += 1
                }
                if i < end {
                    i += 1
                    addSpan(start..<i, .string)
                    continue
                } else {
                    addSpan(start..<end, .string)
                    state = .inTagQuote(kind: kind, quote: quote)
                    return (end, state)
                }
            }

            if b == FC.equals {
                addSpan(i..<min(i + 1, end), .tag)
                i += 1

                i = skeleton.skipSpaces(from: i, to: end)
                if i >= end { break }

                let v = skeleton[i]
                if v == FC.doubleQuote || v == FC.singleQuote {
                    let quote = v
                    let start = i
                    i += 1
                    while i < end, skeleton[i] != quote {
                        i += 1
                    }
                    if i < end {
                        i += 1
                        addSpan(start..<i, .string)
                        continue
                    } else {
                        addSpan(start..<end, .string)
                        state = .inTagQuote(kind: kind, quote: quote)
                        return (end, state)
                    }
                }

                // クオート無し属性値
                let start = i
                while i < end {
                    let c = skeleton[i]
                    if c == FC.space || c == FC.tab || c == FC.gt { break }
                    i += 1
                }
                if i > start {
                    addSpan(start..<i, .string)
                }

                continue
            }

            // 属性名や宣言中の名前相当（ここでは .tag に寄せる）
            if isHtmlNameStart(b) {
                let start = i
                i += 1
                while i < end, isHtmlNamePart(skeleton[i]) {
                    i += 1
                }
                addSpan(start..<i, .tag)
                continue
            }

            if b == FC.slash || b == FC.exclamation || b == FC.question {
                addSpan(i..<min(i + 1, end), .tag)
            }

            i += 1
        }

        return (end, state)
    }

    // MARK: - Entity

    private func parseEntity(from index: Int, to end: Int, skeleton: KSkeletonString) -> Int? {
        // &name;  /  &#123;  /  &#x1A2B;
        var i = index
        if skeleton[i] != FC.ampersand { return nil }
        i += 1
        if i >= end { return nil }

        var seenOne = false

        while i < end {
            let b = skeleton[i]

            if b == FC.semicolon {
                if !seenOne { return nil }
                return i + 1
            }

            if b == FC.numeric { // '#'
                if seenOne { return nil }
                seenOne = true
                i += 1
                continue
            }

            if b.isAsciiAlpha || b.isAsciiDigit || b == FC.underscore {
                seenOne = true
                i += 1
                continue
            }

            if b == 0x78 || b == 0x58 { // x / X (hex)
                seenOne = true
                i += 1
                continue
            }

            return nil
        }

        return nil
    }

    // MARK: - Close tag detection (script/style)

    private func findCloseTagStart(nameLower: [UInt8], from index: Int, to end: Int, skeleton: KSkeletonString) -> Int? {
        // </name>  または </name   > の形だけを閉じタグとして認める。
        // ("</name not really>" のような文字列内パターンを誤検出しないため)

        var i = index
        while i < end {
            if skeleton[i] != FC.lt {
                i += 1
                continue
            }

            let slashIndex = i + 1
            if slashIndex >= end {
                return nil
            }
            if skeleton[slashIndex] != FC.slash {
                i += 1
                continue
            }

            let nameStart = slashIndex + 1
            let nameEnd = nameStart + nameLower.count
            if nameEnd > end {
                return nil
            }

            if !isWordIgnoreCase(nameLower, in: nameStart..<nameEnd, skeleton: skeleton) {
                i += 1
                continue
            }

            // "</scriptx" のようなケースを排除
            if nameEnd < end, isHtmlNamePart(skeleton[nameEnd]) {
                i += 1
                continue
            }

            var j = nameEnd
            while j < end {
                let b = skeleton[j]
                if b == FC.space || b == FC.tab {
                    j += 1
                    continue
                }
                break
            }

            if j < end, skeleton[j] == FC.gt {
                return i
            }

            i += 1
        }
        return nil
    }

    // MARK: - Utilities

    private func isHtmlNameStart(_ b: UInt8) -> Bool {
        // HTML/XML 風: A-Z a-z _ :
        return b.isAsciiAlpha || b == FC.underscore || b == FC.colon
    }

    private func isHtmlNamePart(_ b: UInt8) -> Bool {
        // start + 0-9 -
        return isHtmlNameStart(b) || b.isAsciiDigit || b == FC.minus
    }

    private func lowerAscii(_ b: UInt8) -> UInt8 {
        if b.isAsciiUpper { return b + 0x20 }
        return b
    }

    private func isWordIgnoreCase(_ wordLower: [UInt8], in range: Range<Int>, skeleton: KSkeletonString) -> Bool {
        if range.count != wordLower.count { return false }
        var i = 0
        while i < wordLower.count {
            if lowerAscii(skeleton[range.lowerBound + i]) != wordLower[i] { return false }
            i += 1
        }
        return true
    }

    private func matchesPrefixIgnoreCase(_ word: [UInt8], at index: Int, skeleton: KSkeletonString, to end: Int) -> Bool {
        if word.isEmpty { return true }
        if index < 0 { return false }
        if index + word.count > end { return false }

        var i = 0
        while i < word.count {
            if lowerAscii(skeleton[index + i]) != lowerAscii(word[i]) { return false }
            i += 1
        }
        return true
    }

    private func findSequence(_ seq: [UInt8], from index: Int, to end: Int, skeleton: KSkeletonString) -> Int? {
        if seq.isEmpty { return index }
        if index < 0 { return nil }
        if index >= end { return nil }
        if seq.count > (end - index) { return nil }

        var i = index
        let last = end - seq.count
        while i <= last {
            var j = 0
            while j < seq.count {
                if skeleton[i + j] != seq[j] { break }
                j += 1
            }
            if j == seq.count { return i }
            i += 1
        }
        return nil
    }

    private func findByte(_ b: UInt8, from index: Int, to end: Int, skeleton: KSkeletonString) -> Int? {
        var i = index
        while i < end {
            if skeleton[i] == b { return i }
            i += 1
        }
        return nil
    }
}
