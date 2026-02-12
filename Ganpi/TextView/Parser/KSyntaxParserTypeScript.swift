//
//  KSyntaxParserTypeScript.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/02/11,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

/// TypeScript / JavaScript 統合パーサ（色分け用途）
final class KSyntaxParserTypeScript: KSyntaxParser {

    // MARK: - Internal types

    private enum KEndState: Equatable {
        case neutral
        case inBlockComment
        case inSingleQuote
        case inDoubleQuote
        case inTemplateText
        case inTemplateInterpolation(braceDepth: Int, subState: KInterpolationState)
    }

    private enum KInterpolationState: Equatable {
        case normal
        case inBlockComment
        case inSingleQuote
        case inDoubleQuote
        case inBacktickString
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Private properties

    private var _lines: [KLineInfo] = []

    // Outline / currentContext 用（ASCII バイト列）
    private let _tokenExport: [UInt8]     = Array("export".utf8)
    private let _tokenDefault: [UInt8]    = Array("default".utf8)
    private let _tokenDeclare: [UInt8]    = Array("declare".utf8)
    private let _tokenAsync: [UInt8]      = Array("async".utf8)

    private let _tokenFunction: [UInt8]   = Array("function".utf8)
    private let _tokenClass: [UInt8]      = Array("class".utf8)
    private let _tokenInterface: [UInt8]  = Array("interface".utf8)
    private let _tokenType: [UInt8]       = Array("type".utf8)
    private let _tokenEnum: [UInt8]       = Array("enum".utf8)
    private let _tokenNamespace: [UInt8]  = Array("namespace".utf8)
    private let _tokenModule: [UInt8]     = Array("module".utf8)

    private let _tokenStatic: [UInt8]     = Array("static".utf8)
    private let _tokenGet: [UInt8]        = Array("get".utf8)
    private let _tokenSet: [UInt8]        = Array("set".utf8)
    private let _tokenConstructor: [UInt8] = Array("constructor".utf8)

    private let _lookbackLinesForAttributes: Int = 200
    private let _maxBackLinesForContext: Int = 1000

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .typescript)
    }

    // MARK: - Overrides

    override var lineCommentPrefix: String? { "//" }

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        if plan.lineDelta != 0 {
            applyLineDelta(lines: &_lines,
                           spliceIndex: plan.spliceIndex,
                           lineDelta: plan.lineDelta) {
                KLineInfo(endState: .neutral)
            }
        }

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
        if lineRange.isEmpty { return [] }

        let lineIndex = skeleton.lineIndex(at: lineRange.lowerBound)

        // JS/TS はテンプレートリテラルやブロックコメントがあるので、少し遡って状態を安定させる
        if !_lines.isEmpty {
            let start = max(0, min(lineIndex - _lookbackLinesForAttributes, _lines.count - 1))
            let minLine = max(0, min(lineIndex, _lines.count - 1))
            scanFrom(line: start, minLine: minLine)
        }

        let startState: KEndState = {
            if lineIndex == 0 { return .neutral }
            let prev = lineIndex - 1
            if prev >= 0 && prev < _lines.count { return _lines[prev].endState }
            return .neutral
        }()

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(16)

        _ = parseLine(lineRange: lineRange,
                      clampTo: range,
                      startState: startState,
                      collectSpans: true,
                      spans: &spans)

        return spans
    }

    override func wordRange(at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }

        let i = max(0, min(index, n - 1))
        let b = bytes[i]

        // 単語構成は A-Z a-z 0-9 _ のみ（軽量エディタ方針）
        if !b.isIdentPartAZ09_ { return nil }

        var left = i
        while left > 0, bytes[left - 1].isIdentPartAZ09_ { left -= 1 }

        var right = i + 1
        while right < n, bytes[right].isIdentPartAZ09_ { right += 1 }

        if left >= right { return nil }
        return left..<right
    }

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {     // range is ignored for now.
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return [] }

        ensureUpToDate(for: 0..<n)

        let lineCount = max(1, skeleton.newlineIndices.count + 1)

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        func skipSpaces(_ i: inout Int, _ end: Int) {
            while i < end, isSpaceOrTab(bytes[i]) { i += 1 }
        }

        func matchWord(_ word: [UInt8], at i: Int, end: Int) -> Bool {
            let m = word.count
            if i + m > end { return false }
            if !bytes[i..<(i + m)].elementsEqual(word) { return false }
            // 後ろが identifier 続きなら単語境界ではない
            if i + m < end, bytes[i + m].isIdentPartAZ09_ { return false }
            return true
        }

        func parseIdent(after i0: Int, end: Int) -> Range<Int>? {
            var i = i0
            skipSpaces(&i, end)
            if i >= end { return nil }
            if !bytes[i].isIdentStartAZ_ { return nil }
            let start = i
            i += 1
            while i < end, bytes[i].isIdentPartAZ09_ { i += 1 }
            if start >= i { return nil }
            return start..<i
        }

        var items: [KOutlineItem] = []
        items.reserveCapacity(256)

        for line in 0..<lineCount {
            let startState: KEndState = {
                if line == 0 { return .neutral }
                let prev = line - 1
                if prev >= 0 && prev < _lines.count { return _lines[prev].endState }
                return .neutral
            }()

            if startState != .neutral { continue }

            let lr = skeleton.lineRange(at: line)
            var i = lr.lowerBound
            let end = lr.upperBound

            skipSpaces(&i, end)
            if i >= end { continue }

            // 先頭行の shebang はコメント扱い
            if line == 0, (end - i) >= 2, bytes[i] == FC.numeric, bytes[i + 1] == FC.exclamation {
                continue
            }

            // 行頭コメント
            if (end - i) >= 2, bytes[i] == FC.slash, bytes[i + 1] == FC.slash { continue }
            if (end - i) >= 2, bytes[i] == FC.slash, bytes[i + 1] == FC.asterisk { continue }

            // prefix（export/default/declare/async）を飛ばす（繰り返し可）
            while true {
                if matchWord(_tokenExport, at: i, end: end) {
                    i += _tokenExport.count
                    skipSpaces(&i, end)
                    continue
                }
                if matchWord(_tokenDefault, at: i, end: end) {
                    i += _tokenDefault.count
                    skipSpaces(&i, end)
                    continue
                }
                if matchWord(_tokenDeclare, at: i, end: end) {
                    i += _tokenDeclare.count
                    skipSpaces(&i, end)
                    continue
                }
                if matchWord(_tokenAsync, at: i, end: end) {
                    i += _tokenAsync.count
                    skipSpaces(&i, end)
                    continue
                }
                break
            }

            // function
            if matchWord(_tokenFunction, at: i, end: end) {
                i += _tokenFunction.count
                skipSpaces(&i, end)
                if i < end, bytes[i] == FC.asterisk { i += 1; skipSpaces(&i, end) } // function*
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .method, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }

            // class / interface / enum
            if matchWord(_tokenClass, at: i, end: end) {
                i += _tokenClass.count
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .class, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }
            if matchWord(_tokenInterface, at: i, end: end) {
                i += _tokenInterface.count
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .class, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }
            if matchWord(_tokenEnum, at: i, end: end) {
                i += _tokenEnum.count
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .class, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }

            // namespace / module / type
            if matchWord(_tokenNamespace, at: i, end: end) {
                i += _tokenNamespace.count
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .module, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }
            if matchWord(_tokenModule, at: i, end: end) {
                i += _tokenModule.count
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .module, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }
            if matchWord(_tokenType, at: i, end: end) {
                i += _tokenType.count
                if let nameRange = parseIdent(after: i, end: end) {
                    items.append(KOutlineItem(kind: .module, nameRange: nameRange, level: 0, isSingleton: false))
                }
                continue
            }
        }

        return items
    }

    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let n = skeleton.count
        if n == 0 { return (nil, nil) }

        let clamped = max(0, min(index, n))
        let ensureUpper = min(clamped + 1, n)
        if clamped < ensureUpper {
            ensureUpToDate(for: clamped..<ensureUpper)
        } else {
            ensureUpToDate(for: max(0, n - 1)..<n)
        }

        let bytes = skeleton.bytes
        let caretLine = skeleton.lineIndex(at: clamped)

        var outerRange: Range<Int>? = nil
        var innerText: String? = nil

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        func skipSpaces(_ i: inout Int, _ end: Int) {
            while i < end, isSpaceOrTab(bytes[i]) { i += 1 }
        }

        func matchWord(_ word: [UInt8], at i: Int, end: Int) -> Bool {
            let m = word.count
            if i + m > end { return false }
            if !bytes[i..<(i + m)].elementsEqual(word) { return false }
            if i + m < end, bytes[i + m].isIdentPartAZ09_ { return false }
            return true
        }

        func parseIdentRange(after i0: Int, end: Int) -> Range<Int>? {
            var i = i0
            skipSpaces(&i, end)
            if i >= end { return nil }
            if !bytes[i].isIdentStartAZ_ { return nil }
            let start = i
            i += 1
            while i < end, bytes[i].isIdentPartAZ09_ { i += 1 }
            if start >= i { return nil }
            return start..<i
        }

        func parseFunctionName(at p0: Int, end: Int) -> String? {
            var i = p0

            // prefix をスキップ（export/default/declare/async）: currentContext は軽量優先で緩めに
            while true {
                if matchWord(_tokenExport, at: i, end: end) { i += _tokenExport.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenDefault, at: i, end: end) { i += _tokenDefault.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenDeclare, at: i, end: end) { i += _tokenDeclare.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenAsync, at: i, end: end) { i += _tokenAsync.count; skipSpaces(&i, end); continue }
                break
            }

            // function foo
            if matchWord(_tokenFunction, at: i, end: end) {
                i += _tokenFunction.count
                skipSpaces(&i, end)
                if i < end, bytes[i] == FC.asterisk { i += 1; skipSpaces(&i, end) } // function*
                if let r = parseIdentRange(after: i, end: end) {
                    let name = storage.string(in: r)
                    return name + "()"
                }
                return nil
            }

            // class method: [static] [async] [get|set] name(
            var isStatic = false
            while true {
                if matchWord(_tokenStatic, at: i, end: end) { isStatic = true; i += _tokenStatic.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenAsync, at: i, end: end) { i += _tokenAsync.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenGet, at: i, end: end) { i += _tokenGet.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenSet, at: i, end: end) { i += _tokenSet.count; skipSpaces(&i, end); continue }
                break
            }

            if matchWord(_tokenConstructor, at: i, end: end) {
                // constructor(
                let name = "constructor()"
                return "#" + name
            }

            guard let nameRange = parseIdentRange(after: i, end: end) else { return nil }
            var j = nameRange.upperBound
            skipSpaces(&j, end)
            if j >= end { return nil }
            if bytes[j] != FC.leftParen { return nil }

            let name = storage.string(in: nameRange) + "()"
            return (isStatic ? "." : "#") + name
        }

        func parseOuterRange(at p0: Int, end: Int) -> Range<Int>? {
            var i = p0

            while true {
                if matchWord(_tokenExport, at: i, end: end) { i += _tokenExport.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenDefault, at: i, end: end) { i += _tokenDefault.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenDeclare, at: i, end: end) { i += _tokenDeclare.count; skipSpaces(&i, end); continue }
                if matchWord(_tokenAsync, at: i, end: end) { i += _tokenAsync.count; skipSpaces(&i, end); continue }
                break
            }

            if matchWord(_tokenClass, at: i, end: end) {
                i += _tokenClass.count
                return parseIdentRange(after: i, end: end)
            }
            if matchWord(_tokenInterface, at: i, end: end) {
                i += _tokenInterface.count
                return parseIdentRange(after: i, end: end)
            }
            if matchWord(_tokenEnum, at: i, end: end) {
                i += _tokenEnum.count
                return parseIdentRange(after: i, end: end)
            }
            if matchWord(_tokenNamespace, at: i, end: end) {
                i += _tokenNamespace.count
                return parseIdentRange(after: i, end: end)
            }
            if matchWord(_tokenModule, at: i, end: end) {
                i += _tokenModule.count
                return parseIdentRange(after: i, end: end)
            }
            return nil
        }

        var line = caretLine
        var scanned = 0
        while line >= 0 && scanned < _maxBackLinesForContext && (outerRange == nil || innerText == nil) {
            let startState: KEndState = {
                if line == 0 { return .neutral }
                let prev = line - 1
                if prev >= 0 && prev < _lines.count { return _lines[prev].endState }
                return .neutral
            }()

            if startState == .neutral {
                let lr = skeleton.lineRange(at: line)
                var p = lr.lowerBound
                let end = lr.upperBound

                skipSpaces(&p, end)
                if p < end {
                    // 行頭コメント
                    if (end - p) >= 2, bytes[p] == FC.slash, bytes[p + 1] == FC.slash {
                        // skip
                    } else if (end - p) >= 2, bytes[p] == FC.slash, bytes[p + 1] == FC.asterisk {
                        // skip
                    } else if innerText == nil {
                        innerText = parseFunctionName(at: p, end: end)
                    }

                    if outerRange == nil {
                        outerRange = parseOuterRange(at: p, end: end)
                    }
                }
            }

            line -= 1
            scanned += 1
        }

        let outerText: String? = {
            guard let r = outerRange else { return nil }
            return storage.string(in: r)
        }()

        // outer があるのに inner が separator を持っていない場合は、表示が詰まるので補正する
        let innerAdjusted: String? = {
            guard let inner = innerText else { return nil }
            if outerText == nil { return inner }
            if inner.hasPrefix("#") || inner.hasPrefix(".") { return inner }
            return "#" + inner
        }()

        return (outer: outerText, inner: innerAdjusted)
    }

    // MARK: - Line scan

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        var state: KEndState = (startLine > 0 && startLine - 1 < _lines.count) ? _lines[startLine - 1].endState : .neutral

        if _lines.isEmpty { return }

        for line in startLine..<_lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let oldEndState = _lines[line].endState
            let newEndState = scanOneLine(lineRange: lineRange, startState: state)

            _lines[line].endState = newEndState
            state = newEndState

            if oldEndState == newEndState && line >= minLine {
                break
            }
        }
    }

    private func scanOneLine(lineRange: Range<Int>, startState: KEndState) -> KEndState {
        var dummy: [KAttributedSpan] = []
        dummy.reserveCapacity(0)

        return parseLine(lineRange: lineRange,
                         clampTo: lineRange,
                         startState: startState,
                         collectSpans: false,
                         spans: &dummy)
    }

    // MARK: - Parse line

    private func parseLine(
        lineRange: Range<Int>,
        clampTo paintRange: Range<Int>,
        startState: KEndState,
        collectSpans: Bool,
        spans: inout [KAttributedSpan]
    ) -> KEndState {

        if lineRange.isEmpty { return startState }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let end = lineRange.upperBound

        func addSpan(_ range: Range<Int>, _ role: KFunctionalColor) {
            if !collectSpans { return }
            let clipped = range.clamped(to: paintRange)
            if clipped.isEmpty { return }
            spans.append(makeSpan(range: clipped, role: role))
        }

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        func isEscapedInLine(at index: Int, lineStart: Int) -> Bool {
            var esc = 0
            var k = index - 1
            while k >= lineStart, bytes[k] == FC.backSlash {
                esc += 1
                k -= 1
            }
            return (esc % 2) == 1
        }

        func trailingBackslashIsOdd(lineStart: Int) -> Bool {
            if end <= lineStart { return false }
            let last = end - 1
            if bytes[last] != FC.backSlash { return false }

            var esc = 0
            var k = last
            while k >= lineStart, bytes[k] == FC.backSlash {
                esc += 1
                k -= 1
            }
            return (esc % 2) == 1
        }

        func scanBlockComment(from start: Int) -> (closed: Bool, end: Int) {
            var j = start
            while j + 1 < end {
                if bytes[j] == FC.asterisk && bytes[j + 1] == FC.slash {
                    return (true, j + 2)
                }
                j += 1
            }
            return (false, end)
        }

        func scanQuotedInLine(from start: Int, quote: UInt8, lineStart: Int) -> (closed: Bool, end: Int) {
            var j = start + 1
            while j < end {
                if bytes[j] == quote, !isEscapedInLine(at: j, lineStart: lineStart) {
                    return (true, j + 1)
                }
                j += 1
            }
            return (false, end)
        }

        // 文字列継続（開きクォートが前行）の場合：start から走査する
        func scanQuotedBodyInLine(from start: Int, quote: UInt8, lineStart: Int) -> (closed: Bool, end: Int) {
            var j = start
            while j < end {
                if bytes[j] == quote, !isEscapedInLine(at: j, lineStart: lineStart) {
                    return (true, j + 1)
                }
                j += 1
            }
            return (false, end)
        }

        func scanBacktickInLine(from start: Int, lineStart: Int) -> (closed: Bool, end: Int) {
            var j = start + 1
            while j < end {
                if bytes[j] == FC.backtick, !isEscapedInLine(at: j, lineStart: lineStart) {
                    return (true, j + 1)
                }
                j += 1
            }
            return (false, end)
        }

        func scanBacktickBodyInLine(from start: Int, lineStart: Int) -> (closed: Bool, end: Int) {
            var j = start
            while j < end {
                if bytes[j] == FC.backtick, !isEscapedInLine(at: j, lineStart: lineStart) {
                    return (true, j + 1)
                }
                j += 1
            }
            return (false, end)
        }

        func scanRegexInLine(from start: Int, lineStart: Int) -> (closed: Bool, end: Int) {
            var j = start + 1
            var inClass = 0

            while j < end {
                let c = bytes[j]

                if c == FC.leftBracket, !isEscapedInLine(at: j, lineStart: lineStart) {
                    inClass += 1
                    j += 1
                    continue
                }

                if c == FC.rightBracket, inClass > 0, !isEscapedInLine(at: j, lineStart: lineStart) {
                    inClass -= 1
                    j += 1
                    continue
                }

                if c == FC.slash, inClass == 0, !isEscapedInLine(at: j, lineStart: lineStart) {
                    var k = j + 1
                    while k < end, bytes[k].isAsciiAlpha { k += 1 } // flags
                    return (true, k)
                }

                j += 1
            }

            return (false, end)
        }

        func isRegexStart(at slashIndex: Int, lineStart: Int) -> Bool {
            // コメントではないことは呼び出し側が保証
            var p = slashIndex - 1
            while p >= lineStart {
                let b = bytes[p]
                if isSpaceOrTab(b) { p -= 1; continue }

                switch b {
                case FC.leftParen, FC.leftBracket, FC.leftBrace,
                     FC.comma, FC.colon, FC.semicolon,
                     FC.equals,
                     FC.question, FC.exclamation,
                     FC.plus, FC.minus, FC.asterisk, FC.percent,
                     FC.caret, FC.pipe, FC.ampersand, FC.tilde,
                     FC.lt, FC.gt:
                    return true
                default:
                    return false
                }
            }
            // 行頭は regex とみなす
            return true
        }

        func scanNumber(from start: Int) -> Int {
            var i = start

            func isDigitOrUnderscore(_ b: UInt8) -> Bool {
                b.isAsciiDigit || b == FC.underscore
            }

            // .5 など
            if bytes[i] == FC.period {
                i += 1
                while i < end, isDigitOrUnderscore(bytes[i]) { i += 1 }
                // exponent
                if i < end, bytes[i] == 0x65 || bytes[i] == 0x45 { // e/E
                    i += 1
                    if i < end, bytes[i] == FC.plus || bytes[i] == FC.minus { i += 1 }
                    while i < end, isDigitOrUnderscore(bytes[i]) { i += 1 }
                }
                return i
            }

            // 0x / 0b / 0o
            if bytes[i] == 0x30, i + 1 < end { // '0'
                let b1 = bytes[i + 1]
                if b1 == 0x78 || b1 == 0x58 { // x/X
                    i += 2
                    while i < end {
                        let b = bytes[i]
                        if b == FC.underscore { i += 1; continue }
                        if b.isAsciiDigit || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46) {
                            i += 1
                            continue
                        }
                        break
                    }
                    if i < end, bytes[i] == 0x6E { i += 1 } // n (bigint)
                    return i
                }

                if b1 == 0x62 || b1 == 0x42 { // b/B
                    i += 2
                    while i < end {
                        let b = bytes[i]
                        if b == FC.underscore { i += 1; continue }
                        if b == 0x30 || b == 0x31 { i += 1; continue }
                        break
                    }
                    if i < end, bytes[i] == 0x6E { i += 1 }
                    return i
                }

                if b1 == 0x6F || b1 == 0x4F { // o/O
                    i += 2
                    while i < end {
                        let b = bytes[i]
                        if b == FC.underscore { i += 1; continue }
                        if b >= 0x30 && b <= 0x37 { i += 1; continue }
                        break
                    }
                    if i < end, bytes[i] == 0x6E { i += 1 }
                    return i
                }
            }

            // decimal
            while i < end, isDigitOrUnderscore(bytes[i]) { i += 1 }

            // fraction
            if i < end, bytes[i] == FC.period {
                i += 1
                while i < end, isDigitOrUnderscore(bytes[i]) { i += 1 }
            }

            // exponent
            if i < end, bytes[i] == 0x65 || bytes[i] == 0x45 { // e/E
                i += 1
                if i < end, bytes[i] == FC.plus || bytes[i] == FC.minus { i += 1 }
                while i < end, isDigitOrUnderscore(bytes[i]) { i += 1 }
            }

            // bigint suffix
            if i < end, bytes[i] == 0x6E { i += 1 } // n

            return i
        }

        // shebang（先頭行のみ）はコメント扱い
        if lineRange.lowerBound == 0, lineRange.count >= 2, bytes[0] == FC.numeric, bytes[1] == FC.exclamation {
            addSpan(lineRange, .comment)
            return .neutral
        }

        var i = lineRange.lowerBound
        var state = startState

        // Template の中で、次の `${` または `` ` `` を探す
        func processTemplateText(from startIndex: Int, segmentStart: Int) -> (newState: KEndState, nextIndex: Int) {
            var i = startIndex
            var segmentStart = segmentStart

            while i < end {
                let b = bytes[i]

                // closing `
                if b == FC.backtick, !isEscapedInLine(at: i, lineStart: lineRange.lowerBound) {
                    addSpan(segmentStart..<(i + 1), .string)
                    return (.neutral, i + 1)
                }

                // interpolation ${
                if b == FC.dollar, i + 1 < end, bytes[i + 1] == FC.leftBrace,
                   !isEscapedInLine(at: i, lineStart: lineRange.lowerBound) {
                    addSpan(segmentStart..<(i + 2), .string) // include ${
                    return (.inTemplateInterpolation(braceDepth: 1, subState: .normal), i + 2)
                }

                i += 1
            }

            // 行末までテンプレート文字列
            addSpan(segmentStart..<end, .string)
            return (.inTemplateText, end)
        }

        mainLoop: while true {
            switch state {
            case .neutral:
                while i < end {
                    let b = bytes[i]

                    if isSpaceOrTab(b) { i += 1; continue }

                    // comment or regex
                    if b == FC.slash, i + 1 < end {
                        let b2 = bytes[i + 1]
                        if b2 == FC.slash {
                            addSpan(i..<end, .comment)
                            return .neutral
                        }
                        if b2 == FC.asterisk {
                            let start = i
                            let res = scanBlockComment(from: i + 2)
                            if res.closed {
                                addSpan(start..<res.end, .comment)
                                i = res.end
                                continue
                            } else {
                                addSpan(start..<end, .comment)
                                return .inBlockComment
                            }
                        }

                        if isRegexStart(at: i, lineStart: lineRange.lowerBound) {
                            let start = i
                            let res = scanRegexInLine(from: i, lineStart: lineRange.lowerBound)
                            addSpan(start..<res.end, .string)
                            i = res.end
                            continue
                        }

                        i += 1
                        continue
                    }

                    // single/double quote
                    if b == FC.singleQuote || b == FC.doubleQuote {
                        let quote = b
                        let start = i
                        let res = scanQuotedInLine(from: i, quote: quote, lineStart: lineRange.lowerBound)
                        if res.closed {
                            addSpan(start..<res.end, .string)
                            i = res.end
                            continue
                        } else {
                            addSpan(start..<end, .string)
                            if trailingBackslashIsOdd(lineStart: lineRange.lowerBound) {
                                return (quote == FC.singleQuote) ? .inSingleQuote : .inDoubleQuote
                            }
                            return .neutral
                        }
                    }

                    // template literal
                    if b == FC.backtick {
                        let start = i
                        let (newState, next) = processTemplateText(from: i + 1, segmentStart: start)
                        state = newState
                        i = next

                        if state == .neutral { continue }

                        // テンプレート継続（または補間開始）。行末ならそのまま返す。
                        if i >= end { return state }
                        continue mainLoop
                    }

                    // number
                    if b.isAsciiDigit || (b == FC.period && i + 1 < end && bytes[i + 1].isAsciiDigit) {
                        let start = i
                        i = scanNumber(from: i)
                        addSpan(start..<i, .number)
                        continue
                    }

                    // identifier
                    if b.isIdentStartAZ_ {
                        let start = i
                        i += 1
                        while i < end, bytes[i].isIdentPartAZ09_ { i += 1 }
                        let wordRange = start..<i
                        if !keywords.isEmpty, skeleton.matches(words: keywords, in: wordRange) {
                            addSpan(wordRange, .keyword)
                        }
                        continue
                    }

                    i += 1
                }

                return .neutral

            case .inBlockComment:
                let start = i
                let res = scanBlockComment(from: i)
                if res.closed {
                    addSpan(start..<res.end, .comment)
                    i = res.end
                    state = .neutral
                    continue
                } else {
                    addSpan(start..<end, .comment)
                    return .inBlockComment
                }

            case .inSingleQuote:
                let start = i
                let res = scanQuotedBodyInLine(from: i, quote: FC.singleQuote, lineStart: lineRange.lowerBound)
                if res.closed {
                    addSpan(start..<res.end, .string)
                    i = res.end
                    state = .neutral
                    continue
                } else {
                    addSpan(start..<end, .string)
                    if trailingBackslashIsOdd(lineStart: lineRange.lowerBound) { return .inSingleQuote }
                    return .neutral
                }

            case .inDoubleQuote:
                let start = i
                let res = scanQuotedBodyInLine(from: i, quote: FC.doubleQuote, lineStart: lineRange.lowerBound)
                if res.closed {
                    addSpan(start..<res.end, .string)
                    i = res.end
                    state = .neutral
                    continue
                } else {
                    addSpan(start..<end, .string)
                    if trailingBackslashIsOdd(lineStart: lineRange.lowerBound) { return .inDoubleQuote }
                    return .neutral
                }

            case .inTemplateText:
                let (newState, next) = processTemplateText(from: i, segmentStart: i)
                state = newState
                i = next

                if i >= end { return state }
                continue mainLoop

            case .inTemplateInterpolation(let braceDepth0, let sub0):
                var braceDepth = braceDepth0
                var subState = sub0

                while i < end {
                    switch subState {
                    case .normal:
                        let b = bytes[i]
                        if isSpaceOrTab(b) { i += 1; continue }

                        // comment
                        if b == FC.slash, i + 1 < end {
                            let b2 = bytes[i + 1]
                            if b2 == FC.slash {
                                addSpan(i..<end, .comment)
                                i = end
                                break
                            }
                            if b2 == FC.asterisk {
                                let start = i
                                let res = scanBlockComment(from: i + 2)
                                if res.closed {
                                    addSpan(start..<res.end, .comment)
                                    i = res.end
                                    continue
                                } else {
                                    addSpan(start..<end, .comment)
                                    subState = .inBlockComment
                                    i = end
                                    break
                                }
                            }

                            if isRegexStart(at: i, lineStart: lineRange.lowerBound) {
                                let start = i
                                let res = scanRegexInLine(from: i, lineStart: lineRange.lowerBound)
                                addSpan(start..<res.end, .string)
                                i = res.end
                                continue
                            }

                            i += 1
                            continue
                        }

                        // quote
                        if b == FC.singleQuote || b == FC.doubleQuote {
                            let quote = b
                            let start = i
                            let res = scanQuotedInLine(from: i, quote: quote, lineStart: lineRange.lowerBound)
                            if res.closed {
                                addSpan(start..<res.end, .string)
                                i = res.end
                                continue
                            } else {
                                addSpan(start..<end, .string)
                                if trailingBackslashIsOdd(lineStart: lineRange.lowerBound) {
                                    subState = (quote == FC.singleQuote) ? .inSingleQuote : .inDoubleQuote
                                }
                                i = end
                                break
                            }
                        }

                        // backtick string in interpolation (簡易：ネストテンプレートは文字列扱いに留める)
                        if b == FC.backtick {
                            let start = i
                            let res = scanBacktickInLine(from: i, lineStart: lineRange.lowerBound)
                            if res.closed {
                                addSpan(start..<res.end, .string)
                                i = res.end
                                continue
                            } else {
                                addSpan(start..<end, .string)
                                subState = .inBacktickString
                                i = end
                                break
                            }
                        }

                        // number
                        if b.isAsciiDigit || (b == FC.period && i + 1 < end && bytes[i + 1].isAsciiDigit) {
                            let start = i
                            i = scanNumber(from: i)
                            addSpan(start..<i, .number)
                            continue
                        }

                        // identifier
                        if b.isIdentStartAZ_ {
                            let start = i
                            i += 1
                            while i < end, bytes[i].isIdentPartAZ09_ { i += 1 }
                            let wordRange = start..<i
                            if !keywords.isEmpty, skeleton.matches(words: keywords, in: wordRange) {
                                addSpan(wordRange, .keyword)
                            }
                            continue
                        }

                        // braces
                        if b == FC.leftBrace {
                            braceDepth += 1
                            i += 1
                            continue
                        }

                        if b == FC.rightBrace {
                            if braceDepth == 1 {
                                // interpolation end
                                addSpan(i..<(i + 1), .string) // } をテンプレート扱いに寄せる
                                i += 1

                                // template text 再開
                                let (newState, next) = processTemplateText(from: i, segmentStart: i)
                                state = newState
                                i = next

                                if i >= end { return state }
                                continue mainLoop
                            } else {
                                braceDepth -= 1
                                i += 1
                                continue
                            }
                        }

                        i += 1

                    case .inBlockComment:
                        let start = i
                        let res = scanBlockComment(from: i)
                        if res.closed {
                            addSpan(start..<res.end, .comment)
                            i = res.end
                            subState = .normal
                            continue
                        } else {
                            addSpan(start..<end, .comment)
                            i = end
                            break
                        }

                    case .inSingleQuote:
                        let start = i
                        let res = scanQuotedBodyInLine(from: i, quote: FC.singleQuote, lineStart: lineRange.lowerBound)
                        if res.closed {
                            addSpan(start..<res.end, .string)
                            i = res.end
                            subState = .normal
                            continue
                        } else {
                            addSpan(start..<end, .string)
                            i = end
                            break
                        }

                    case .inDoubleQuote:
                        let start = i
                        let res = scanQuotedBodyInLine(from: i, quote: FC.doubleQuote, lineStart: lineRange.lowerBound)
                        if res.closed {
                            addSpan(start..<res.end, .string)
                            i = res.end
                            subState = .normal
                            continue
                        } else {
                            addSpan(start..<end, .string)
                            i = end
                            break
                        }

                    case .inBacktickString:
                        let start = i
                        let res = scanBacktickBodyInLine(from: i, lineStart: lineRange.lowerBound)
                        if res.closed {
                            addSpan(start..<res.end, .string)
                            i = res.end
                            subState = .normal
                            continue
                        } else {
                            addSpan(start..<end, .string)
                            i = end
                            break
                        }
                    }
                }

                // 行末。template interpolation 継続
                return .inTemplateInterpolation(braceDepth: braceDepth, subState: subState)
            }
        }
    }
}
