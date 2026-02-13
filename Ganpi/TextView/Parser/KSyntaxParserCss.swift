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

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {     // range is ignored for now.
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return [] }

        // endState を参照するため、全文を一度 up-to-date にしておく
        ensureUpToDate(for: 0..<n)
        if _lines.isEmpty { return [] }

        let lineCount = skeletonLineCount()
        if lineCount <= 0 { return [] }

        var items: [KOutlineItem] = []
        items.reserveCapacity(128)

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        func trimmedRange(_ lineRange: Range<Int>) -> Range<Int>? {
            var a = lineRange.lowerBound
            var b = lineRange.upperBound
            while a < b && isSpaceOrTab(bytes[a]) { a += 1 }
            while b > a && isSpaceOrTab(bytes[b - 1]) { b -= 1 }
            if a >= b { return nil }
            return a..<b
        }

        func firstOpenBraceIndex(in lineRange: Range<Int>, startState: KEndState, limit: Int?) -> Int? {
            let end = min(lineRange.upperBound, limit ?? lineRange.upperBound)
            if lineRange.lowerBound >= end { return nil }

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
                    if bytes[i] == FC.asterisk && bytes[i + 1] == FC.slash { return i }
                    i += 1
                }
                return nil
            }

            var i = lineRange.lowerBound
            var state = startState

            // 行頭で継続している block comment / string を処理してから走査を開始
            switch state {
            case .inBlockComment:
                if let close = findBlockCommentEnd(from: i) {
                    i = close + 2
                    state = .neutral(braceDepth: state.braceDepth)
                } else {
                    return nil
                }

            case .inSingleQuote:
                var j = i
                while j < end {
                    if bytes[j] == FC.singleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                        i = j + 1
                        state = .neutral(braceDepth: state.braceDepth)
                        break
                    }
                    j += 1
                }
                if j >= end { return nil }

            case .inDoubleQuote:
                var j = i
                while j < end {
                    if bytes[j] == FC.doubleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                        i = j + 1
                        state = .neutral(braceDepth: state.braceDepth)
                        break
                    }
                    j += 1
                }
                if j >= end { return nil }

            case .neutral:
                break
            }

            while i < end {
                let b = bytes[i]

                if b == FC.slash && (i + 1) < end && bytes[i + 1] == FC.asterisk {
                    if let close = findBlockCommentEnd(from: i + 2) {
                        i = close + 2
                        continue
                    } else {
                        return nil
                    }
                }

                if b == FC.singleQuote {
                    var j = i + 1
                    while j < end {
                        if bytes[j] == FC.singleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                            i = j + 1
                            break
                        }
                        j += 1
                    }
                    if j >= end { return nil }
                    continue
                }

                if b == FC.doubleQuote {
                    var j = i + 1
                    while j < end {
                        if bytes[j] == FC.doubleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                            i = j + 1
                            break
                        }
                        j += 1
                    }
                    if j >= end { return nil }
                    continue
                }

                if b == FC.leftBrace {
                    return i
                }

                i += 1
            }

            return nil
        }

        func headerNameRangeFromSameLine(_ lineRange: Range<Int>, braceIndex: Int) -> Range<Int>? {
            guard let t = trimmedRange(lineRange) else { return nil }
            var end = min(braceIndex, t.upperBound)
            while end > t.lowerBound && isSpaceOrTab(bytes[end - 1]) { end -= 1 }
            if end <= t.lowerBound { return nil }

            // 末尾の ',' は selector list 用に落とす
            if bytes[end - 1] == FC.comma {
                end -= 1
                while end > t.lowerBound && isSpaceOrTab(bytes[end - 1]) { end -= 1 }
            }

            if end <= t.lowerBound { return nil }
            return t.lowerBound..<end
        }

        func headerNameRangeFromWholeLine(_ lineRange: Range<Int>) -> Range<Int>? {
            guard var t = trimmedRange(lineRange) else { return nil }

            // 末尾の ',' は selector list 用に落とす
            if bytes[t.upperBound - 1] == FC.comma {
                var e = t.upperBound - 1
                while e > t.lowerBound && isSpaceOrTab(bytes[e - 1]) { e -= 1 }
                if e <= t.lowerBound { return nil }
                t = t.lowerBound..<e
            }

            return t
        }

        func isAtRule(_ nameRange: Range<Int>) -> Bool {
            let i = nameRange.lowerBound
            if i < 0 || i >= n { return false }
            return bytes[i] == FC.at
        }

        var line = 0
        while line < lineCount {
            let lineRange = skeleton.lineRange(at: line)
            let startState: KEndState = (line > 0 && (line - 1) < _lines.count) ? _lines[line - 1].endState : .neutral(braceDepth: 0)
            let enteringDepth = startState.braceDepth

            // 1) 同一行に '{' があるケース
            if let braceIndex = firstOpenBraceIndex(in: lineRange, startState: startState, limit: nil) {
                if let nameRange = headerNameRangeFromSameLine(lineRange, braceIndex: braceIndex) {

                    // selector list の改行継続（末尾 ','）を拾う：
                    // 例: "body," の次行に "html {" が来るケース
                    var headerLines: [Int] = []
                    var prev = line - 1
                    while prev >= 0 {
                        let prevRange = skeleton.lineRange(at: prev)
                        if let tr = trimmedRange(prevRange) {
                            // 空行でなければ対象。ただし "}" 単独行は無視。
                            if tr.count == 1, bytes[tr.lowerBound] == FC.rightBrace {
                                prev -= 1
                                continue
                            }

                            // 末尾 ',' の行だけを selector list とみなして拾う
                            if bytes[tr.upperBound - 1] == FC.comma {
                                headerLines.append(prev)
                                prev -= 1
                                continue
                            }
                        }
                        break
                    }

                    if !headerLines.isEmpty {
                        for h in headerLines.reversed() {
                            let hr = skeleton.lineRange(at: h)
                            if let r = headerNameRangeFromWholeLine(hr) {
                                let k: KOutlineItem.Kind = isAtRule(r) ? .module : .class
                                items.append(KOutlineItem(kind: k, nameRange: r, level: enteringDepth, isSingleton: false))
                            }
                        }
                    }

                    let kind: KOutlineItem.Kind = isAtRule(nameRange) ? .module : .class
                    items.append(KOutlineItem(kind: kind, nameRange: nameRange, level: enteringDepth, isSingleton: false))

                } else {
                    // 2) '{' 単独行（前行の selector / @rule を拾う）
                    if let t = trimmedRange(lineRange),
                       t.count == 1,
                       bytes[t.lowerBound] == FC.leftBrace {

                        var headerLines: [Int] = []
                        var prev = line - 1
                        while prev >= 0 {
                            let prevRange = skeleton.lineRange(at: prev)
                            if let tr = trimmedRange(prevRange) {
                                // 空行でなければ採用（ただし閉じ brace のみ行は無視）
                                if tr.count == 1, bytes[tr.lowerBound] == FC.rightBrace {
                                    prev -= 1
                                    continue
                                }
                                headerLines.append(prev)
                                // selector list 継続（末尾 ','）ならさらに上へ
                                if bytes[tr.upperBound - 1] == FC.comma {
                                    prev -= 1
                                    continue
                                }
                                break
                            }
                            prev -= 1
                        }

                        if !headerLines.isEmpty {
                            // 上から順に追加（文書順）
                            for h in headerLines.reversed() {
                                let hr = skeleton.lineRange(at: h)
                                if let nameRange = headerNameRangeFromWholeLine(hr) {
                                    let kind: KOutlineItem.Kind = isAtRule(nameRange) ? .module : .class
                                    items.append(KOutlineItem(kind: kind, nameRange: nameRange, level: enteringDepth, isSingleton: false))
                                }
                            }
                        }
                    }
                }
            }

            line += 1
        }

        return items
    }

    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return (nil, nil) }

        let clamped = max(0, min(index, n))
        let safeIndex = min(clamped, max(0, n - 1))

        ensureUpToDate(for: safeIndex..<(safeIndex + 1))
        if _lines.isEmpty { return (nil, nil) }

        let lineIndex = skeleton.lineIndex(at: safeIndex)
        if lineIndex < 0 { return (nil, nil) }

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        func trimmedRange(_ lineRange: Range<Int>) -> Range<Int>? {
            var a = lineRange.lowerBound
            var b = lineRange.upperBound
            while a < b && isSpaceOrTab(bytes[a]) { a += 1 }
            while b > a && isSpaceOrTab(bytes[b - 1]) { b -= 1 }
            if a >= b { return nil }
            return a..<b
        }

        func firstOpenBraceIndex(in lineRange: Range<Int>, startState: KEndState, limit: Int?) -> Int? {
            let end = min(lineRange.upperBound, limit ?? lineRange.upperBound)
            if lineRange.lowerBound >= end { return nil }

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
                    if bytes[i] == FC.asterisk && bytes[i + 1] == FC.slash { return i }
                    i += 1
                }
                return nil
            }

            var i = lineRange.lowerBound
            var state = startState

            switch state {
            case .inBlockComment:
                if let close = findBlockCommentEnd(from: i) {
                    i = close + 2
                    state = .neutral(braceDepth: state.braceDepth)
                } else {
                    return nil
                }

            case .inSingleQuote:
                var j = i
                while j < end {
                    if bytes[j] == FC.singleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                        i = j + 1
                        state = .neutral(braceDepth: state.braceDepth)
                        break
                    }
                    j += 1
                }
                if j >= end { return nil }

            case .inDoubleQuote:
                var j = i
                while j < end {
                    if bytes[j] == FC.doubleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                        i = j + 1
                        state = .neutral(braceDepth: state.braceDepth)
                        break
                    }
                    j += 1
                }
                if j >= end { return nil }

            case .neutral:
                break
            }

            while i < end {
                let b = bytes[i]

                if b == FC.slash && (i + 1) < end && bytes[i + 1] == FC.asterisk {
                    if let close = findBlockCommentEnd(from: i + 2) {
                        i = close + 2
                        continue
                    } else {
                        return nil
                    }
                }

                if b == FC.singleQuote {
                    var j = i + 1
                    while j < end {
                        if bytes[j] == FC.singleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                            i = j + 1
                            break
                        }
                        j += 1
                    }
                    if j >= end { return nil }
                    continue
                }

                if b == FC.doubleQuote {
                    var j = i + 1
                    while j < end {
                        if bytes[j] == FC.doubleQuote && !isEscaped(at: j, lineStart: lineRange.lowerBound) {
                            i = j + 1
                            break
                        }
                        j += 1
                    }
                    if j >= end { return nil }
                    continue
                }

                if b == FC.leftBrace {
                    return i
                }

                i += 1
            }

            return nil
        }

        func headerNameRangeFromSameLine(_ lineRange: Range<Int>, braceIndex: Int) -> Range<Int>? {
            guard let t = trimmedRange(lineRange) else { return nil }
            var end = min(braceIndex, t.upperBound)
            while end > t.lowerBound && isSpaceOrTab(bytes[end - 1]) { end -= 1 }
            if end <= t.lowerBound { return nil }

            if bytes[end - 1] == FC.comma {
                end -= 1
                while end > t.lowerBound && isSpaceOrTab(bytes[end - 1]) { end -= 1 }
            }

            if end <= t.lowerBound { return nil }
            return t.lowerBound..<end
        }

        func headerNameRangeFromWholeLine(_ lineRange: Range<Int>) -> Range<Int>? {
            guard var t = trimmedRange(lineRange) else { return nil }

            if bytes[t.upperBound - 1] == FC.comma {
                var e = t.upperBound - 1
                while e > t.lowerBound && isSpaceOrTab(bytes[e - 1]) { e -= 1 }
                if e <= t.lowerBound { return nil }
                t = t.lowerBound..<e
            }

            return t
        }

        func nameString(_ r: Range<Int>) -> String {
            return storage.string(in: r).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func isAtRule(_ r: Range<Int>) -> Bool {
            let i = r.lowerBound
            if i < 0 || i >= n { return false }
            return bytes[i] == FC.at
        }

        // caret 行までの braceDepth を概算（行前半は _lines の endState を使う）
        let baseDepth: Int = (lineIndex > 0 && (lineIndex - 1) < _lines.count) ? _lines[lineIndex - 1].endState.braceDepth : 0

        // 行内で caret まで走査し、braceDepth を補正（文字列/コメント内の brace は無視）
        let lineRange = skeleton.lineRange(at: lineIndex)
        let startState: KEndState = (lineIndex > 0 && (lineIndex - 1) < _lines.count) ? _lines[lineIndex - 1].endState : .neutral(braceDepth: 0)
        let limit = min(max(lineRange.lowerBound, safeIndex), lineRange.upperBound)

        var depthAtCaret = baseDepth

        // braceDepth のみを追い、文字列/コメントを避ける
        if let _ = firstOpenBraceIndex(in: lineRange, startState: startState, limit: limit) {
            // 同一行で '{' を跨いでいる可能性があるので、簡易スキャンで数える
            var i = lineRange.lowerBound
            var state = startState

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

            while i < limit {
                let b = bytes[i]

                if case .inBlockComment = state {
                    if (i + 1) < limit, bytes[i] == FC.asterisk, bytes[i + 1] == FC.slash {
                        state = .neutral(braceDepth: depthAtCaret)
                        i += 2
                        continue
                    }
                    i += 1
                    continue
                }

                if b == FC.slash && (i + 1) < limit && bytes[i + 1] == FC.asterisk {
                    state = .inBlockComment(braceDepth: depthAtCaret)
                    i += 2
                    continue
                }

                if case .inSingleQuote = state {
                    if b == FC.singleQuote && !isEscaped(at: i, lineStart: lineRange.lowerBound) {
                        state = .neutral(braceDepth: depthAtCaret)
                    }
                    i += 1
                    continue
                }

                if case .inDoubleQuote = state {
                    if b == FC.doubleQuote && !isEscaped(at: i, lineStart: lineRange.lowerBound) {
                        state = .neutral(braceDepth: depthAtCaret)
                    }
                    i += 1
                    continue
                }

                if b == FC.singleQuote {
                    state = .inSingleQuote(braceDepth: depthAtCaret)
                    i += 1
                    continue
                }
                if b == FC.doubleQuote {
                    state = .inDoubleQuote(braceDepth: depthAtCaret)
                    i += 1
                    continue
                }

                if b == FC.leftBrace { depthAtCaret += 1 }
                if b == FC.rightBrace { depthAtCaret = max(0, depthAtCaret - 1) }

                i += 1
            }
        }

        if depthAtCaret <= 0 { return (nil, nil) }

        let wantDepthForInner = depthAtCaret - 1

        var inner: String? = nil
        var outer: String? = nil

        // inner（selector）を探す：brace を開くヘッダで、@ で始まらないもの
        var foundInnerLine: Int? = nil
        var searchLine = lineIndex
        while searchLine >= 0 {
            let lr = skeleton.lineRange(at: searchLine)
            let ss: KEndState = (searchLine > 0 && (searchLine - 1) < _lines.count) ? _lines[searchLine - 1].endState : .neutral(braceDepth: 0)
            let enteringDepth = ss.braceDepth

            let lim = (searchLine == lineIndex) ? limit : nil
            if enteringDepth == wantDepthForInner, let braceIndex = firstOpenBraceIndex(in: lr, startState: ss, limit: lim) {
                var nameRange: Range<Int>? = headerNameRangeFromSameLine(lr, braceIndex: braceIndex)

                if nameRange == nil {
                    if let t = trimmedRange(lr),
                       t.count == 1,
                       bytes[t.lowerBound] == FC.leftBrace {
                        let prevLine = searchLine - 1
                        if prevLine >= 0 {
                            let pr = skeleton.lineRange(at: prevLine)
                            nameRange = headerNameRangeFromWholeLine(pr)
                        }
                    }
                }

                if let nr = nameRange, !isAtRule(nr) {
                    inner = nameString(nr)
                    foundInnerLine = searchLine
                    break
                }
            }

            searchLine -= 1
        }

        // outer（@rule）を探す：inner が見つかった行（または caret 行）から上へ、最初の @ ヘッダ
        var searchOuterLine = foundInnerLine ?? lineIndex
        while searchOuterLine >= 0 {
            let lr = skeleton.lineRange(at: searchOuterLine)
            let ss: KEndState = (searchOuterLine > 0 && (searchOuterLine - 1) < _lines.count) ? _lines[searchOuterLine - 1].endState : .neutral(braceDepth: 0)
            let enteringDepth = ss.braceDepth

            // inner ブロックより外側に限定
            if enteringDepth < depthAtCaret {
                let lim = (searchOuterLine == lineIndex) ? limit : nil
                if let braceIndex = firstOpenBraceIndex(in: lr, startState: ss, limit: lim) {
                    var nameRange: Range<Int>? = headerNameRangeFromSameLine(lr, braceIndex: braceIndex)

                    if nameRange == nil {
                        if let t = trimmedRange(lr),
                           t.count == 1,
                           bytes[t.lowerBound] == FC.leftBrace {
                            let prevLine = searchOuterLine - 1
                            if prevLine >= 0 {
                                let pr = skeleton.lineRange(at: prevLine)
                                nameRange = headerNameRangeFromWholeLine(pr)
                            }
                        }
                    }

                    if let nr = nameRange, isAtRule(nr) {
                        outer = nameString(nr)
                        break
                    }
                }
            }

            searchOuterLine -= 1
        }

        return (outer, inner)
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
}
