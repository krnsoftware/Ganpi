//
//  KSyntaxParserCss.swift
//
//  Ganpi - macOS Text Editor
//

import AppKit

final class KSyntaxParserCss: KSyntaxParser {

    private enum KEndState: Equatable {
        case neutral(braceDepth: Int)
        case inBlockComment(braceDepth: Int)
        case inSingleQuote(braceDepth: Int)
        case inDoubleQuote(braceDepth: Int)

        var braceDepth: Int {
            switch self {
            case .neutral(let d),
                 .inBlockComment(let d),
                 .inSingleQuote(let d),
                 .inDoubleQuote(let d):
                return d
            }
        }
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    private var _lines: [KLineInfo] = []

    // @media / @supports / @container 判定用（定数は private let）
    private let _tokenAtMedia = Array("@media".utf8)
    private let _tokenAtSupports = Array("@supports".utf8)
    private let _tokenAtContainer = Array("@container".utf8)

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .css)
    }

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral(braceDepth: 0)) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        if plan.lineDelta != 0 {
            applyLineDelta(lines: &_lines,
                           spliceIndex: plan.spliceIndex,
                           lineDelta: plan.lineDelta) {
                KLineInfo(endState: .neutral(braceDepth: 0))
            }
        }

        let rebuilt = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral(braceDepth: 0)) }
        if rebuilt { log("Line counts do not match.", from: self) }
        if _lines.isEmpty { return }

        var startLine = plan.startLine
        if plan.lineDelta != 0 {
            startLine = min(startLine, max(0, plan.spliceIndex - 1))
        }

        let maxLine = max(0, _lines.count - 1)
        startLine = max(0, min(startLine, maxLine))

        // 改行挿入/削除（lineDelta != 0）は後続の endState 連鎖が崩れるので、
        // 早期breakせず後方を必ず再スキャンする。
        var minLine = plan.minLine
        if plan.lineDelta != 0 {
            minLine = maxLine
        } else {
            minLine = max(0, min(minLine, maxLine))
        }

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

        let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral(braceDepth: 0)

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(16)

        @inline(__always)
        func emitSpan(_ tokenRange: Range<Int>, role: KFunctionalColor) {
            let clipped = tokenRange.clamped(to: paintRange)
            if clipped.isEmpty { return }
            spans.append(makeSpan(range: clipped, role: role))
        }

        _ = parseLine(lineRange: lineRange,
                      startState: startState,
                      keywords: keywords,
                      emit: emitSpan)

        return spans
    }

    override func wordRange(at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }

        var pos: Int? = nil
        if index >= 0 && index < n {
            if isCssIdentPart(bytes[index]) || bytes[index] == FC.at { pos = index }
        }
        if pos == nil, index > 0 && index - 1 < n {
            if isCssIdentPart(bytes[index - 1]) || bytes[index - 1] == FC.at { pos = index - 1 }
        }
        guard let p = pos else { return nil }

        var left = p
        while left > 0 && isCssIdentPart(bytes[left - 1]) { left -= 1 }

        if left > 0 && bytes[left - 1] == FC.at {
            left -= 1
            if (left + 1) >= n || !isCssIdentStart(bytes[left + 1]) { return nil }
        } else {
            if !isCssIdentStart(bytes[left]) { return nil }
        }

        var right = p + 1
        if bytes[left] == FC.at {
            right = max(right, left + 1)
            while right < n && isCssIdentPart(bytes[right]) { right += 1 }
        } else {
            while right < n && isCssIdentPart(bytes[right]) { right += 1 }
        }

        if left >= right { return nil }
        return left..<right
    }



    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        if skeleton.count == 0 { return (nil, nil) }
        if index < 0 || index > skeleton.count { return (nil, nil) }

        let safeIndex = min(max(0, index), max(0, skeleton.count - 1))
        ensureUpToDate(for: safeIndex..<(safeIndex + 1))
        if _lines.isEmpty { return (nil, nil) }

        let lineIndex = skeleton.lineIndex(at: safeIndex)
        if lineIndex < 0 { return (nil, nil) }

        let lineRange = skeleton.lineRange(at: lineIndex)
        let startState: KEndState = (lineIndex > 0 && (lineIndex - 1) < _lines.count) ? _lines[lineIndex - 1].endState : .neutral(braceDepth: 0)
        let caretDepth = braceDepthAt(index: safeIndex, lineRange: lineRange, startState: startState)

        if caretDepth <= 0 { return (nil, nil) }

        // まず inner（最内）を探す：level == caretDepth-1 のブロックヘッダ
        var innerHeader: Range<Int>? = nil
        var innerIsAtRule = false
        var innerLevel = caretDepth - 1

        var line = min(lineIndex, max(0, _lines.count - 1))
        while line >= 0 {
            if let hit = blockHeaderRange(at: line, limit: (line == lineIndex) ? safeIndex : nil) {
                if hit.level == innerLevel {
                    innerHeader = hit.headerRange
                    innerIsAtRule = hit.isAtRule
                    break
                }
            }
            line -= 1
        }

        if innerHeader == nil { return (nil, nil) }

        // inner が @rule の場合は outer として返して終了（selector は無し）
        if innerIsAtRule {
            let outer = trimmedString(in: innerHeader!)
            return (outer.isEmpty ? nil : outer, nil)
        }

        let inner = trimmedString(in: innerHeader!)
        if innerLevel == 0 {
            return (nil, inner.isEmpty ? nil : inner)
        }

        // outer：inner を包む @rule（level == innerLevel-1）を後方から探す
        var outerHeader: Range<Int>? = nil
        line = min(lineIndex, max(0, _lines.count - 1))
        while line >= 0 {
            if let hit = blockHeaderRange(at: line, limit: nil) {
                if hit.level == (innerLevel - 1) && hit.isAtRule {
                    outerHeader = hit.headerRange
                    break
                }
            }
            line -= 1
        }

        let outer = outerHeader != nil ? trimmedString(in: outerHeader!) : ""
        return (outer.isEmpty ? nil : outer, inner.isEmpty ? nil : inner)
    }

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {
        let skeleton = storage.skeletonString
        if skeleton.count == 0 { return [] }

        let target: Range<Int> = {
            if let r = range {
                let lower = max(0, min(r.lowerBound, skeleton.count))
                let upper = max(0, min(r.upperBound, skeleton.count))
                if lower >= upper { return 0..<0 }
                return lower..<upper
            }
            return 0..<skeleton.count
        }()

        if target.isEmpty { return [] }

        ensureUpToDate(for: target)
        if _lines.isEmpty { return [] }

        let startLine = skeleton.lineIndex(at: target.lowerBound)
        let endLine = skeleton.lineIndex(at: min(max(target.lowerBound, target.upperBound - 1), skeleton.count - 1))

        let maxLine = max(0, _lines.count - 1)
        let fromLine = max(0, min(startLine, maxLine))
        let toLine = max(0, min(endLine, maxLine))
        if fromLine > toLine { return [] }

        var items: [KOutlineItem] = []
        items.reserveCapacity(128)

        for line in fromLine...toLine {
            if let hit = blockHeaderRange(at: line, limit: nil) {
                let headerRange = hit.headerRange.clamped(to: target)
                if headerRange.isEmpty { continue }

                let kind: KOutlineItem.Kind = hit.isAtRule ? .module : .class
                items.append(KOutlineItem(kind: kind,
                                          nameRange: headerRange,
                                          level: hit.level,
                                          isSingleton: false))
            }
        }

        return items
    }

    // MARK: - Private

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        let lineCount = skeletonLineCount()
        if lineCount <= 0 { return }
        if _lines.isEmpty { return }

        var line = max(0, min(startLine, lineCount - 1))

        var state: KEndState = {
            if line == 0 { return .neutral(braceDepth: 0) }
            let prev = line - 1
            if prev >= 0 && prev < _lines.count { return _lines[prev].endState }
            return .neutral(braceDepth: 0)
        }()

        while line < lineCount && line < _lines.count {
            let old = _lines[line].endState

            let lineRange = skeleton.lineRange(at: line)
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

    private func emitNothing(_ range: Range<Int>, _ role: KFunctionalColor) {
        // no-op（scan only）
    }

    private func isCssIdentStart(_ b: UInt8) -> Bool {
        if b.isAsciiAlpha { return true }
        if b == FC.underscore { return true }
        if b == FC.minus { return true }
        return false
    }

    private func isCssIdentPart(_ b: UInt8) -> Bool {
        if b.isAsciiAlpha { return true }
        if b.isAsciiDigit { return true }
        if b == FC.underscore { return true }
        if b == FC.minus { return true }
        return false
    }

    private func isAsciiHexDigit(_ b: UInt8) -> Bool {
        if b.isAsciiDigit { return true }
        return (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
    }

    private func isUnitChar(_ b: UInt8) -> Bool {
        if b.isAsciiAlpha { return true }
        if b == FC.percent { return true }
        return false
    }

    private func isDeclarationColon(_ bytes: [UInt8], lineStart: Int, colonIndex: Int) -> Bool {
        var segStart = lineStart
        var j = colonIndex - 1
        while j >= lineStart {
            let b = bytes[j]
            if b == FC.semicolon || b == FC.leftBrace {
                segStart = j + 1
                break
            }
            j -= 1
        }

        // '(' を含むなら url(http://...) 等の誤検出が増えるので除外（安全側）
        var k = segStart
        while k < colonIndex {
            if bytes[k] == FC.leftParen { return false }
            k += 1
        }

        k = segStart
        while k < colonIndex {
            let b = bytes[k]
            if b == FC.space || b == FC.tab {
                k += 1
                continue
            }
            if isCssIdentPart(b) {
                k += 1
                continue
            }
            return false
        }
        return true
    }

    private func propertyNameRange(_ bytes: [UInt8], lineStart: Int, colonIndex: Int) -> Range<Int>? {
        var p = colonIndex - 1
        while p >= lineStart && (bytes[p] == FC.space || bytes[p] == FC.tab) { p -= 1 }
        if p < lineStart { return nil }

        let right = p + 1

        var left = p
        while left >= lineStart && isCssIdentPart(bytes[left]) { left -= 1 }
        left += 1
        if left >= right { return nil }

        if bytes[left] == FC.minus && (left + 1) >= right { return nil }
        return left..<right
    }

    private func detectAtRuleLineHead(_ bytes: [UInt8], lineStart: Int, lineEnd: Int) -> Int? {
        var i = lineStart
        while i < lineEnd && (bytes[i] == FC.space || bytes[i] == FC.tab) { i += 1 }
        if i >= lineEnd { return nil }
        if bytes[i] != FC.at { return nil }
        return i
    }

    private func isFeatureQueryAtRule(_ skeleton: KSkeletonString, atIndex: Int, lineEnd: Int) -> Bool {
        let end1 = atIndex + _tokenAtMedia.count
        if end1 <= lineEnd {
            let r1 = atIndex..<end1
            if skeleton.compare(word: _tokenAtMedia, in: r1) == 0 { return true }
        }

        let end2 = atIndex + _tokenAtSupports.count
        if end2 <= lineEnd {
            let r2 = atIndex..<end2
            if skeleton.compare(word: _tokenAtSupports, in: r2) == 0 { return true }
        }

        let end3 = atIndex + _tokenAtContainer.count
        if end3 <= lineEnd {
            let r3 = atIndex..<end3
            if skeleton.compare(word: _tokenAtContainer, in: r3) == 0 { return true }
        }

        return false
    }

    private func paintFeatureQueryNames(_ bytes: [UInt8],
                                       lineStart: Int,
                                       lineEnd: Int,
                                       emit: (Range<Int>, KFunctionalColor) -> Void) {
        // 文字列/コメントはこの段では見ない（@media等の見出し行は大抵プレーン）
        // (...) の中で "ident:" になっている ident を .variable で塗る
        var i = lineStart
        while i < lineEnd {
            if bytes[i] == FC.leftParen {
                // ')' までの範囲で ':' を探す（複数個あり得る）
                var j = i + 1
                while j < lineEnd && bytes[j] != FC.rightParen {
                    if bytes[j] == FC.colon {
                        if let r = propertyNameRange(bytes, lineStart: i + 1, colonIndex: j) {
                            emit(r, .variable)
                        }
                    }
                    j += 1
                }
                i = j
                continue
            }
            i += 1
        }
    }

    private func parseLine(lineRange: Range<Int>,
                           startState: KEndState,
                           keywords: [[UInt8]]?,
                           emit: (Range<Int>, KFunctionalColor) -> Void) -> KEndState {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let start = lineRange.lowerBound
        let end = lineRange.upperBound
        if start >= end { return startState }

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func isEscaped(at index: Int, lineStart: Int) -> Bool {
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
        func findBlockCommentEnd(from i0: Int) -> Int? {
            var i = i0
            while i + 1 < end {
                if bytes[i] == FC.asterisk && bytes[i + 1] == FC.slash {
                    return i
                }
                i += 1
            }
            return nil
        }

        @inline(__always)
        func scanIdentifier(from i0: Int) -> Int {
            var i = i0 + 1
            while i < end && isCssIdentPart(bytes[i]) { i += 1 }
            return i
        }

        @inline(__always)
        func scanNumberBody(from i0: Int) -> Int {
            var i = i0
            if bytes[i] == FC.period {
                i += 1
                while i < end && bytes[i].isAsciiDigit { i += 1 }
            } else {
                while i < end && bytes[i].isAsciiDigit { i += 1 }
                if i < end && bytes[i] == FC.period {
                    i += 1
                    while i < end && bytes[i].isAsciiDigit { i += 1 }
                }
            }
            return i
        }

        @inline(__always)
        func scanUnit(from i0: Int) -> Int {
            var i = i0
            while i < end && isUnitChar(bytes[i]) { i += 1 }
            return i
        }

        @inline(__always)
        func scanHex(afterSharp sharpIndex: Int) -> Int? {
            var i = sharpIndex + 1
            var count = 0
            while i < end && isAsciiHexDigit(bytes[i]) {
                count += 1
                if count > 8 { break }
                i += 1
            }
            if count == 3 || count == 4 || count == 6 || count == 8 {
                return sharpIndex + 1 + count
            }
            return nil
        }

        var braceDepth = startState.braceDepth
        var i = start

        // 継続中の block comment / string
        switch startState {
        case .inBlockComment:
            if let close = findBlockCommentEnd(from: i) {
                emit(start..<(close + 2), .comment)
                i = close + 2
            } else {
                emit(start..<end, .comment)
                return startState
            }

        case .inSingleQuote:
            var j = i
            while j < end {
                if bytes[j] == FC.singleQuote && !isEscaped(at: j, lineStart: start) {
                    emit(start..<(j + 1), .string)
                    i = j + 1
                    break
                }
                j += 1
            }
            if j >= end {
                emit(start..<end, .string)
                return startState
            }

        case .inDoubleQuote:
            var j = i
            while j < end {
                if bytes[j] == FC.doubleQuote && !isEscaped(at: j, lineStart: start) {
                    emit(start..<(j + 1), .string)
                    i = j + 1
                    break
                }
                j += 1
            }
            if j >= end {
                emit(start..<end, .string)
                return startState
            }

        case .neutral:
            break
        }

        // @media/@supports/@container の括弧内 ident: を feature として塗る（braceDepth==0 のまま）
        if let atIndex = detectAtRuleLineHead(bytes, lineStart: start, lineEnd: end) {
            if isFeatureQueryAtRule(skeleton, atIndex: atIndex, lineEnd: end) {
                paintFeatureQueryNames(bytes, lineStart: start, lineEnd: end, emit: emit)
            }
        }

        // 宣言ブロック内の「プロパティ名」を文脈で塗る（1行につき最初の宣言だけ）
        if braceDepth > 0 {
            var c = i
            var didPaintProperty = false
            while c < end && !didPaintProperty {
                let b = bytes[c]
                if b == FC.slash && (c + 1) < end && bytes[c + 1] == FC.asterisk { break }
                if b == FC.singleQuote || b == FC.doubleQuote { break }

                if b == FC.colon {
                    if isDeclarationColon(bytes, lineStart: start, colonIndex: c),
                       let pr = propertyNameRange(bytes, lineStart: start, colonIndex: c) {
                        // プロパティは .keyword だと numeric と同系に見えることがあるので .variable に逃がす
                        emit(pr, .variable)
                    }
                    didPaintProperty = true
                    break
                }
                c += 1
            }
        }

        // 残り走査
        while i < end {
            let b = bytes[i]

            if b == FC.slash && (i + 1) < end && bytes[i + 1] == FC.asterisk {
                if let close = findBlockCommentEnd(from: i + 2) {
                    emit(i..<(close + 2), .comment)
                    i = close + 2
                    continue
                } else {
                    emit(i..<end, .comment)
                    return .inBlockComment(braceDepth: braceDepth)
                }
            }

            if b == FC.singleQuote {
                var j = i + 1
                while j < end {
                    if bytes[j] == FC.singleQuote && !isEscaped(at: j, lineStart: start) {
                        emit(i..<(j + 1), .string)
                        i = j + 1
                        break
                    }
                    j += 1
                }
                if j >= end {
                    emit(i..<end, .string)
                    return .inSingleQuote(braceDepth: braceDepth)
                }
                continue
            }

            if b == FC.doubleQuote {
                var j = i + 1
                while j < end {
                    if bytes[j] == FC.doubleQuote && !isEscaped(at: j, lineStart: start) {
                        emit(i..<(j + 1), .string)
                        i = j + 1
                        break
                    }
                    j += 1
                }
                if j >= end {
                    emit(i..<end, .string)
                    return .inDoubleQuote(braceDepth: braceDepth)
                }
                continue
            }

            if b == FC.leftBrace {
                braceDepth += 1
                i += 1
                continue
            }
            if b == FC.rightBrace {
                braceDepth = max(0, braceDepth - 1)
                i += 1
                continue
            }

            if b == FC.numeric {
                if let hexEnd = scanHex(afterSharp: i) {
                    emit(i..<hexEnd, .number)
                    i = hexEnd
                    continue
                }
            }
            
            // unicode-range の "U+xxxx-xxxx" 等は数値として扱わない（誤認識回避）
            if b == 85 /* 'U' */ {
                let next = i + 1
                if next < end, bytes[next] == FC.plus {
                    // "U+" を見たら、このトークン（識別子相当）を飛ばす
                    // 例: U+0000-00FF, U+0131
                    var j = next + 1
                    while j < end {
                        let c = bytes[j]
                        if c == FC.space || c == FC.tab || c == FC.comma || c == FC.semicolon || c == FC.rightParen {
                            break
                        }
                        j += 1
                    }
                    i = j
                    continue
                }
            }

            // -20px / -0.5rem などの先頭 '-' を数値として扱う
            if b == FC.minus {
                let next = i + 1
                if next < end {
                    let nb = bytes[next]
                    if nb.isAsciiDigit || (nb == FC.period && (next + 1) < end && bytes[next + 1].isAsciiDigit) {
                        let s = i
                        let bodyEnd = scanNumberBody(from: next)
                        var e = bodyEnd
                        if bodyEnd < end && isUnitChar(bytes[bodyEnd]) {
                            e = scanUnit(from: bodyEnd)
                        }
                        if e > s {
                            emit(s..<e, .number)
                            i = e
                            continue
                        }
                    }
                }
            }

            if b.isAsciiDigit || (b == FC.period && (i + 1) < end && bytes[i + 1].isAsciiDigit) {
                let s = i
                let bodyEnd = scanNumberBody(from: i)
                var e = bodyEnd
                if bodyEnd < end && isUnitChar(bytes[bodyEnd]) {
                    e = scanUnit(from: bodyEnd)
                }
                if e > s {
                    emit(s..<e, .number)
                    i = e
                    continue
                }
            }

            if isCssIdentStart(b) {
                let s = i
                let e = scanIdentifier(from: i)
                let r = s..<e
                if let kw = keywords {
                    if skeleton.matches(words: kw, in: r) {
                        emit(r, .keyword)
                    }
                }
                i = e
                continue
            }

            if b == FC.at {
                let s = i
                let j = i + 1
                if j < end && isCssIdentStart(bytes[j]) {
                    let e = scanIdentifier(from: j)
                    let r = s..<e
                    if let kw = keywords {
                        if skeleton.matches(words: kw, in: r) {
                            emit(r, .keyword)
                        }
                    }
                    i = e
                    continue
                }
                i += 1
                continue
            }

            i += 1
        }

        return .neutral(braceDepth: braceDepth)
    }
    private struct KBlockHeaderHit {
        let headerRange: Range<Int>
        let level: Int
        let isAtRule: Bool
    }

    private func trimmedString(in range: Range<Int>) -> String {
        return storage.string(in: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func braceDepthAt(index: Int, lineRange: Range<Int>, startState: KEndState) -> Int {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        var depth = startState.braceDepth
        var i = lineRange.lowerBound
        let end = min(index, lineRange.upperBound)

        enum Mode { case neutral, inBlockComment, inSingleQuote, inDoubleQuote }
        var mode: Mode = {
            switch startState {
            case .inBlockComment: return .inBlockComment
            case .inSingleQuote: return .inSingleQuote
            case .inDoubleQuote: return .inDoubleQuote
            case .neutral: return .neutral
            }
        }()

        @inline(__always)
        func isEscaped(_ j: Int) -> Bool {
            if j <= lineRange.lowerBound { return false }
            var count = 0
            var k = j - 1
            while k >= lineRange.lowerBound && bytes[k] == FC.backSlash {
                count += 1
                if k == 0 { break }
                k -= 1
            }
            return (count & 1) == 1
        }

        while i < end {
            let b = bytes[i]

            switch mode {
            case .neutral:
                if b == FC.slash, (i + 1) < end, bytes[i + 1] == FC.asterisk {
                    mode = .inBlockComment
                    i += 2
                    continue
                }
                if b == FC.singleQuote {
                    mode = .inSingleQuote
                    i += 1
                    continue
                }
                if b == FC.doubleQuote {
                    mode = .inDoubleQuote
                    i += 1
                    continue
                }
                if b == FC.leftBrace { depth += 1; i += 1; continue }
                if b == FC.rightBrace { depth = max(0, depth - 1); i += 1; continue }

            case .inBlockComment:
                if b == FC.asterisk, (i + 1) < end, bytes[i + 1] == FC.slash {
                    mode = .neutral
                    i += 2
                    continue
                }

            case .inSingleQuote:
                if b == FC.singleQuote && !isEscaped(i) {
                    mode = .neutral
                    i += 1
                    continue
                }

            case .inDoubleQuote:
                if b == FC.doubleQuote && !isEscaped(i) {
                    mode = .neutral
                    i += 1
                    continue
                }
            }

            i += 1
        }

        return depth
    }

    private func blockHeaderRange(at lineIndex: Int, limit: Int?) -> KBlockHeaderHit? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }
        if lineIndex < 0 || lineIndex >= skeletonLineCount() { return nil }

        let lineRange = skeleton.lineRange(at: lineIndex)
        if lineRange.isEmpty { return nil }

        let startState: KEndState = (lineIndex > 0 && (lineIndex - 1) < _lines.count) ? _lines[lineIndex - 1].endState : .neutral(braceDepth: 0)

        // 文字列/コメント継続行はヘッダとして扱わない
        switch startState {
        case .inBlockComment, .inSingleQuote, .inDoubleQuote:
            return nil
        case .neutral:
            break
        }

        let level = startState.braceDepth
        let scanEnd = min(limit ?? lineRange.upperBound, lineRange.upperBound)

        enum Mode { case neutral, inBlockComment, inSingleQuote, inDoubleQuote }
        var mode: Mode = .neutral

        @inline(__always)
        func isEscaped(_ j: Int) -> Bool {
            if j <= lineRange.lowerBound { return false }
            var count = 0
            var k = j - 1
            while k >= lineRange.lowerBound && bytes[k] == FC.backSlash {
                count += 1
                if k == 0 { break }
                k -= 1
            }
            return (count & 1) == 1
        }

        func trimHeader(_ r: Range<Int>) -> Range<Int>? {
            var l = r.lowerBound
            var u = r.upperBound

            while l < u {
                let b = bytes[l]
                if b == FC.space || b == FC.tab { l += 1; continue }
                break
            }
            while u > l {
                let b = bytes[u - 1]
                if b == FC.space || b == FC.tab { u -= 1; continue }
                break
            }
            if l >= u { return nil }
            return l..<u
        }

        // 同一行の '{' を探す（文字列/コメント中は無視）
        var i = lineRange.lowerBound
        while i < scanEnd {
            let b = bytes[i]

            switch mode {
            case .neutral:
                if b == FC.slash, (i + 1) < scanEnd, bytes[i + 1] == FC.asterisk {
                    mode = .inBlockComment
                    i += 2
                    continue
                }
                if b == FC.singleQuote { mode = .inSingleQuote; i += 1; continue }
                if b == FC.doubleQuote { mode = .inDoubleQuote; i += 1; continue }

                if b == FC.leftBrace {
                    if let header = trimHeader(lineRange.lowerBound..<i) {
                        let isAtRule = bytes[header.lowerBound] == FC.at
                        return KBlockHeaderHit(headerRange: header, level: level, isAtRule: isAtRule)
                    }
                    return nil
                }

            case .inBlockComment:
                if b == FC.asterisk, (i + 1) < scanEnd, bytes[i + 1] == FC.slash {
                    mode = .neutral
                    i += 2
                    continue
                }

            case .inSingleQuote:
                if b == FC.singleQuote && !isEscaped(i) { mode = .neutral; i += 1; continue }

            case .inDoubleQuote:
                if b == FC.doubleQuote && !isEscaped(i) { mode = .neutral; i += 1; continue }
            }

            i += 1
        }

        // 次行が「{」単独（スペース＋任意コメント）なら、現行行をヘッダ扱い
        let nextLine = lineIndex + 1
        let lineCount = skeletonLineCount()
        if nextLine < lineCount {
            let nextRange = skeleton.lineRange(at: nextLine)
            if !nextRange.isEmpty {
                var p = nextRange.lowerBound
                while p < nextRange.upperBound && (bytes[p] == FC.space || bytes[p] == FC.tab) { p += 1 }
                if p < nextRange.upperBound && bytes[p] == FC.leftBrace {
                    p += 1
                    while p < nextRange.upperBound && (bytes[p] == FC.space || bytes[p] == FC.tab) { p += 1 }

                    // allow empty or comment only
                    var ok = false
                    if p >= nextRange.upperBound {
                        ok = true
                    } else if (p + 1) < nextRange.upperBound, bytes[p] == FC.slash, bytes[p + 1] == FC.asterisk {
                        ok = true
                    }

                    if ok, let header = trimHeader(lineRange) {
                        let isAtRule = bytes[header.lowerBound] == FC.at
                        return KBlockHeaderHit(headerRange: header, level: level, isAtRule: isAtRule)
                    }
                }
            }
        }

        return nil
    }

}
