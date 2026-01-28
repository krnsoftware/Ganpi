//
//  KSyntaxParserHtml.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/01/29,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

final class KSyntaxParserHtml: KSyntaxParser {

    // MARK: - Types

    private enum KTagKind: Equatable {
        case normal
        case scriptOpen
        case styleOpen
    }

    private enum KEndState: Equatable {
        case neutral
        case inComment
        case inCData
        case inScript
        case inStyle
        case inTag(kind: KTagKind, quote: UInt8?)
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []
    private var _hasScanned = false

    private let _commentBeginBytes = Array("<!--".utf8)
    private let _commentEndBytes   = Array("-->".utf8)

    private let _cdataBeginBytes   = Array("<![CDATA[".utf8)
    private let _cdataEndBytes     = Array("]]>".utf8)

    private let _scriptLowerBytes  = Array("script".utf8)
    private let _styleLowerBytes   = Array("style".utf8)

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

        // まず差分（改行増減）を splice で反映
        if plan.lineDelta != 0 {
            applyLineDelta(lines: &_lines,
                           spliceIndex: plan.spliceIndex,
                           lineDelta: plan.lineDelta) { KLineInfo(endState: .neutral) }
        }

        // 安全弁：それでも行数が合わなければ全再構築
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

        let skeleton = storage.skeletonString
        let clamped = min(range.lowerBound, skeleton.count)
        let requestedLine = skeleton.lineIndex(at: clamped)

        // 初回は、状態連鎖を作るため必ず先頭から requestedLine までは走査する
        if !_hasScanned {
            startLine = 0
            minLine = max(minLine, requestedLine)
        }

        // rebuilt で行バッファを作り直した場合も、先頭からやり直す
        scanFrom(line: rebuilt ? 0 : startLine, minLine: minLine)
        _hasScanned = true
    }

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        ensureUpToDate(for: range)
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let lineIndex = skeleton.lineIndex(at: range.lowerBound)

        if lineIndex < 0 || lineIndex >= _lines.count { return [] }

        let lineRange = skeleton.lineRange(at: lineIndex)
        let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral

        var spans: [KAttributedSpan] = []
        let _ = scanLine(lineRange: lineRange,
                         startState: startState,
                         emitSpans: true,
                         limitRange: range,
                         spans: &spans)
        return spans
    }

    // MARK: - Line scan (endState chain)

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        var state: KEndState = (startLine > 0) ? _lines[startLine - 1].endState : .neutral

        for line in startLine..<_lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let oldEndState = _lines[line].endState
            let newEndState = scanOneLine(lineRange: lineRange, startState: state)

            _lines[line].endState = newEndState
            state = newEndState

            // 連鎖が止まっても、minLine までは必ず走査する
            if oldEndState == newEndState && line >= minLine {
                break
            }
        }
    }

    private func scanOneLine(lineRange: Range<Int>, startState: KEndState) -> KEndState {
        var dummy: [KAttributedSpan] = []
        return scanLine(lineRange: lineRange,
                        startState: startState,
                        emitSpans: false,
                        limitRange: 0..<0,
                        spans: &dummy)
    }

    // MARK: - Core scanner (optionally emit spans)

    private func scanLine(
        lineRange: Range<Int>,
        startState: KEndState,
        emitSpans: Bool,
        limitRange: Range<Int>,
        spans: inout [KAttributedSpan]
    ) -> KEndState {
        if lineRange.isEmpty { return startState }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound
        var state = startState

        while i < end {
            switch state {
            case .neutral:
                while i < end && skeleton[i] != FC.lt {
                    i += 1
                }
                if i >= end { return .neutral }

                if skeleton.matchesPrefix(_commentBeginBytes, at: i) {
                    state = .inComment
                    continue
                }

                if skeleton.matchesPrefix(_cdataBeginBytes, at: i) {
                    state = .inCData
                    continue
                }

                let (nextState, nextIndex) = scanTag(from: i,
                                                     lineEnd: end,
                                                     startWithLt: true,
                                                     tagKindHint: .normal,
                                                     quoteHint: nil,
                                                     emitSpans: emitSpans,
                                                     limitRange: limitRange,
                                                     spans: &spans)
                state = nextState
                i = nextIndex

            case .inComment:
                if let close = skeleton.firstIndex(ofSequence: _commentEndBytes, in: i..<end) {
                    appendSpan(start: i, end: min(close + _commentEndBytes.count, end), role: .comment,
                               emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                    i = close + _commentEndBytes.count
                    state = .neutral
                } else {
                    appendSpan(start: i, end: end, role: .comment,
                               emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                    return .inComment
                }

            case .inCData:
                if let close = skeleton.firstIndex(ofSequence: _cdataEndBytes, in: i..<end) {
                    appendSpan(start: i, end: min(close + _cdataEndBytes.count, end), role: .string,
                               emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                    i = close + _cdataEndBytes.count
                    state = .neutral
                } else {
                    appendSpan(start: i, end: end, role: .string,
                               emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                    return .inCData
                }

            case .inScript:
                if let closeLt = findClosingTagStart(nameLower: _scriptLowerBytes, in: i..<end) {
                    // 本文は span を出さない（.base）
                    i = closeLt
                    state = .neutral
                } else {
                    return .inScript
                }

            case .inStyle:
                if let closeLt = findClosingTagStart(nameLower: _styleLowerBytes, in: i..<end) {
                    i = closeLt
                    state = .neutral
                } else {
                    return .inStyle
                }

            case .inTag(let kind, let quote):
                let (nextState, nextIndex) = scanTag(from: i,
                                                     lineEnd: end,
                                                     startWithLt: false,
                                                     tagKindHint: kind,
                                                     quoteHint: quote,
                                                     emitSpans: emitSpans,
                                                     limitRange: limitRange,
                                                     spans: &spans)
                state = nextState
                i = nextIndex
                if case .inTag = state {
                    return state
                }
            }
        }

        return state
    }

    // MARK: - Tag scan

    private func scanTag(
        from start: Int,
        lineEnd: Int,
        startWithLt: Bool,
        tagKindHint: KTagKind,
        quoteHint: UInt8?,
        emitSpans: Bool,
        limitRange: Range<Int>,
        spans: inout [KAttributedSpan]
    ) -> (state: KEndState, nextIndex: Int) {
        let skeleton = storage.skeletonString

        var i = start
        var kind = tagKindHint
        var quote = quoteHint

        // 既にクオート継続中なら、まず閉じを探す（クオート自体も .string に含める）
        if let q = quote {
            if let close = firstIndex(ofByte: q, in: i..<lineEnd) {
                appendSpan(start: i, end: min(close + 1, lineEnd), role: .string,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                i = close + 1
                quote = nil
            } else {
                appendSpan(start: i, end: lineEnd, role: .string,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                return (.inTag(kind: kind, quote: q), lineEnd)
            }
        }

        var isCloseTag = false

        // startWithLt の場合は '<' から始まる
        if startWithLt {
            appendSpan(start: i, end: min(i + 1, lineEnd), role: .tag,
                       emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
            i += 1
            if i >= lineEnd { return (.inTag(kind: kind, quote: nil), lineEnd) }

            // '</' / '<!' / '<?' の記号は .tag（閉じタグ判定もここで取る）
            if skeleton[i] == FC.slash || skeleton[i] == FC.exclamation || skeleton[i] == FC.question {
                if skeleton[i] == FC.slash {
                    isCloseTag = true
                }
                appendSpan(start: i, end: min(i + 1, lineEnd), role: .tag,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                i += 1
                if i >= lineEnd { return (.inTag(kind: kind, quote: nil), lineEnd) }
            }

            // タグ名
            let nameStart = i
            if isHtmlNameStart(skeleton[i]) {
                i += 1
                while i < lineEnd && isHtmlNamePart(skeleton[i]) {
                    i += 1
                }
                let nameEnd = i
                appendSpan(start: nameStart, end: nameEnd, role: .tag,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)

                // script/style open 判定は「開きタグのみ」
                if !isCloseTag {
                    let nameLen = nameEnd - nameStart
                    if nameLen == _scriptLowerBytes.count && matchesLowerWord(_scriptLowerBytes, at: nameStart) {
                        kind = .scriptOpen
                    } else if nameLen == _styleLowerBytes.count && matchesLowerWord(_styleLowerBytes, at: nameStart) {
                        kind = .styleOpen
                    } else {
                        kind = .normal
                    }
                } else {
                    kind = .normal
                }
            }
        }

        // タグ内部：属性列を走査
        while i < lineEnd {
            // 空白スキップ
            while i < lineEnd && (skeleton[i] == FC.space || skeleton[i] == FC.tab) {
                i += 1
            }
            if i >= lineEnd { return (.inTag(kind: kind, quote: nil), lineEnd) }

            let b = skeleton[i]

            // '>' でタグ終了
            if b == FC.gt {
                appendSpan(start: i, end: min(i + 1, lineEnd), role: .tag,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                i += 1

                // 閉じタグは常に neutral に戻す
                if isCloseTag {
                    return (.neutral, i)
                }

                switch kind {
                case .scriptOpen: return (.inScript, i)
                case .styleOpen:  return (.inStyle, i)
                case .normal:     return (.neutral, i)
                }
            }

            // "/>" の '/' は .tag（self close は script/style に入らない）
            if b == FC.slash {
                appendSpan(start: i, end: min(i + 1, lineEnd), role: .tag,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)

                // 直後が '>' なら self-closing。script/style でも neutral 扱いにする。
                if i + 1 < lineEnd && skeleton[i + 1] == FC.gt {
                    kind = .normal
                }

                i += 1
                continue
            }

            // 属性名
            if isHtmlNameStart(b) {
                let attrStart = i
                i += 1
                while i < lineEnd && isHtmlNamePart(skeleton[i]) {
                    i += 1
                }
                let attrEnd = i
                appendSpan(start: attrStart, end: attrEnd, role: .variable,
                           emitSpans: emitSpans, limitRange: limitRange, spans: &spans)

                // 空白スキップ
                while i < lineEnd && (skeleton[i] == FC.space || skeleton[i] == FC.tab) {
                    i += 1
                }
                if i >= lineEnd { return (.inTag(kind: kind, quote: nil), lineEnd) }

                // '=' があれば属性値
                if skeleton[i] == FC.equals {
                    appendSpan(start: i, end: min(i + 1, lineEnd), role: .tag,
                               emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                    i += 1

                    while i < lineEnd && (skeleton[i] == FC.space || skeleton[i] == FC.tab) {
                        i += 1
                    }
                    if i >= lineEnd { return (.inTag(kind: kind, quote: nil), lineEnd) }

                    let vb = skeleton[i]

                    // クオート有り
                    if vb == FC.singleQuote || vb == FC.doubleQuote {
                        let q = vb
                        let valueStart = i
                        i += 1

                        if let close = firstIndex(ofByte: q, in: i..<lineEnd) {
                            let valueEnd = min(close + 1, lineEnd)
                            appendSpan(start: valueStart, end: valueEnd, role: .string,
                                       emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                            i = valueEnd
                            continue
                        } else {
                            appendSpan(start: valueStart, end: lineEnd, role: .string,
                                       emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                            return (.inTag(kind: kind, quote: q), lineEnd)
                        }
                    }

                    // クオート無し属性値：空白または '>' までを .string
                    let valueStart = i
                    while i < lineEnd {
                        let cb = skeleton[i]
                        if cb == FC.space || cb == FC.tab || cb == FC.gt { break }
                        i += 1
                    }
                    if valueStart < i {
                        appendSpan(start: valueStart, end: i, role: .string,
                                   emitSpans: emitSpans, limitRange: limitRange, spans: &spans)
                    }
                    continue
                }

                // '=' が無い boolean attribute はここで終了（名前のみ色付け）
                continue
            }

            // その他の文字は黙って進める（破綻を避ける）
            i += 1
        }

        return (.inTag(kind: kind, quote: nil), lineEnd)
    }


    // MARK: - Helpers (span)

    private func appendSpan(
        start: Int,
        end: Int,
        role: KFunctionalColor,
        emitSpans: Bool,
        limitRange: Range<Int>,
        spans: inout [KAttributedSpan]
    ) {
        if !emitSpans { return }
        if start >= end { return }

        // limitRange との交差を手動で取る（Range.clamped は使わない）
        let lower = max(start, limitRange.lowerBound)
        let upper = min(end, limitRange.upperBound)
        if lower >= upper { return }

        spans.append(makeSpan(range: lower..<upper, role: role))
    }

    // MARK: - Helpers (search)

    private func firstIndex(ofByte target: UInt8, in range: Range<Int>) -> Int? {
        let skeleton = storage.skeletonString
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if skeleton[i] == target { return i }
            i += 1
        }
        return nil
    }

    private func findClosingTagStart(nameLower: [UInt8], in range: Range<Int>) -> Int? {
        let skeleton = storage.skeletonString
        var i = range.lowerBound
        let end = range.upperBound

        while i < end {
            // '<' を探す
            while i < end && skeleton[i] != FC.lt {
                i += 1
            }
            if i >= end { return nil }

            let p = i
            let slashIndex = p + 1
            if slashIndex >= end { return nil }

            // "</" でなければ閉じタグ候補ではない
            if skeleton[slashIndex] != FC.slash {
                i = p + 1
                continue
            }

            let nameStart = slashIndex + 1
            if nameStart + nameLower.count > end { return nil }

            // "</script" の一致（大小無視）
            if matchesLowerWord(nameLower, at: nameStart) {
                let afterName = nameStart + nameLower.count

                // 直後が名前継続文字なら別タグ（例: </scriptx）
                if afterName < end && isHtmlNamePart(skeleton[afterName]) {
                    i = p + 1
                    continue
                }

                // HTMLの end tag は属性を持てない：空白(任意)の後に '>' が必要
                var j = afterName
                while j < end && (skeleton[j] == FC.space || skeleton[j] == FC.tab) {
                    j += 1
                }
                if j < end && skeleton[j] == FC.gt {
                    return p
                }

                // "</script not ...>" のようなケースは閉じタグではない
                i = p + 1
                continue
            }

            i = p + 1
        }

        return nil
    }


    private func matchesLowerWord(_ lowerBytes: [UInt8], at index: Int) -> Bool {
        let skeleton = storage.skeletonString
        if index < 0 { return false }
        if index + lowerBytes.count > skeleton.count { return false }

        var i = 0
        while i < lowerBytes.count {
            let b = skeleton[index + i]
            if lowerAscii(b) != lowerBytes[i] { return false }
            i += 1
        }
        return true
    }

    private func lowerAscii(_ b: UInt8) -> UInt8 {
        if b.isAsciiUpper { return b + 0x20 }
        return b
    }

    // MARK: - Helpers (HTML name char)

    private func isHtmlNameStart(_ b: UInt8) -> Bool {
        // ':' は先頭不可（XML系の慣習に合わせる）
        if b == FC.colon { return false }
        return b.isAsciiAlpha || b == FC.underscore
    }

    private func isHtmlNamePart(_ b: UInt8) -> Bool {
        if b.isIdentPartAZ09_ { return true }
        if b == FC.minus { return true }
        if b == FC.colon { return true }
        return false
    }
}
