//
//  KSyntaxParserRuby.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

final class KSyntaxParserRuby: KSyntaxParser {

    // MARK: - Types

    private enum KEndState: Equatable {
        case neutral
        case inMultiComment
        case inHeredoc(label: [UInt8], allowIndent: Bool)
        case inDoubleQuote
        case inSingleQuote
        case inRegexSlash(inClass: Int)
        case inRegexPercent(close: UInt8, allowNesting: Bool, depth: Int)
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    private let _commentBeginBytes = Array("=begin".utf8)
    private let _commentEndBytes   = Array("=end".utf8)

    // MARK: - Init

    override init(storage: KTextStorageReadable, type: KSyntaxType = .ruby) {
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

        // 行頭状態（＝前行の endState）
        let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral

        // ディレクティブ行はそれ自体もコメント色にする
        // - "=begin" は常にコメント色
        // - "=end"   は multi comment 中（前行 endState が inMultiComment）のときだけコメント色
        if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentBeginBytes) {
            return [makeSpan(range: paintRange, role: .comment)]
        }
        if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentEndBytes) {
            if startState == .inMultiComment {
                return [makeSpan(range: paintRange, role: .comment)]
            }
        }


        switch startState {
        case .inMultiComment:
            return [makeSpan(range: paintRange, role: .comment)]

        case .inHeredoc:
            return [makeSpan(range: paintRange, role: .string)]

        case .inDoubleQuote:
            // 行頭から閉じ " まで（無ければ行末まで）
            switch skeleton.scan(in: lineRange, targets: [FC.doubleQuote], escape: FC.backSlash) {
            case .notFound:
                return [makeSpan(range: paintRange, role: .string)]

            case .hit(let closeIndex, _):
                var spans: [KAttributedSpan] = []

                // 行頭〜閉じ"（閉じ自身を含む）
                let firstStringRange = lineRange.lowerBound..<(closeIndex + 1)
                let paint1 = paintRange.clamped(to: firstStringRange)
                if !paint1.isEmpty {
                    spans.append(makeSpan(range: paint1, role: .string))
                }

                // この行の残りに、さらに複数行 " の開始があるならそこから行末まで
                if _lines[lineIndex].endState == .inDoubleQuote {
                    let rest = (closeIndex + 1)..<lineRange.upperBound
                    if let start = multiLineDoubleQuoteStartIndex(lineRange: rest) {
                        let secondStringRange = start..<lineRange.upperBound
                        let paint2 = paintRange.clamped(to: secondStringRange)
                        if !paint2.isEmpty {
                            spans.append(makeSpan(range: paint2, role: .string))
                        }
                    }
                }

                return spans
            }
            
        case .inSingleQuote:
            // 行頭から閉じ ' まで（無ければ行末まで）
            switch skeleton.scan(in: lineRange, targets: [FC.singleQuote], escape: FC.backSlash) {
            case .notFound:
                return [makeSpan(range: paintRange, role: .string)]

            case .hit(let closeIndex, _):
                var spans: [KAttributedSpan] = []

                // 行頭〜閉じ'（閉じ自身を含む）
                let firstStringRange = lineRange.lowerBound..<(closeIndex + 1)
                let paint1 = paintRange.clamped(to: firstStringRange)
                if !paint1.isEmpty {
                    spans.append(makeSpan(range: paint1, role: .string))
                }

                // この行の残りに、さらに複数行 ' の開始があるならそこから行末まで
                if _lines[lineIndex].endState == .inSingleQuote {
                    let rest = (closeIndex + 1)..<lineRange.upperBound
                    if let start = multiLineSingleQuoteStartIndex(lineRange: rest) {
                        let secondStringRange = start..<lineRange.upperBound
                        let paint2 = paintRange.clamped(to: secondStringRange)
                        if !paint2.isEmpty {
                            spans.append(makeSpan(range: paint2, role: .string))
                        }
                    }
                }

                return spans
            }
            
        case .inRegexSlash(let inClass):
            // 行頭から閉じ / まで（無ければ行末まで）
            let r = scanRegexBodyInLine(startIndex: lineRange.lowerBound, in: lineRange, inClass: inClass)
            if !r.closed {
                return [makeSpan(range: paintRange, role: .string)]
            }

            // 閉じ /（閉じ自身を含む）まで
            let closeIndex = r.closeIndex ?? (r.nextIndex - 1)
            var spans: [KAttributedSpan] = []

            let firstRegexRange = lineRange.lowerBound..<(closeIndex + 1)
            let paint1 = paintRange.clamped(to: firstRegexRange)
            if !paint1.isEmpty {
                spans.append(makeSpan(range: paint1, role: .string))
            }

            // 同一行の残りに、さらに multi-line regex の開始があるならそこから行末まで
            if isInRegex(_lines[lineIndex].endState) {
                let rest = r.nextIndex..<lineRange.upperBound
                if let start = multiLineRegexSlashStartIndex(lineRange: rest) {
                    let secondRegexRange = start..<lineRange.upperBound
                    let paint2 = paintRange.clamped(to: secondRegexRange)
                    if !paint2.isEmpty {
                        spans.append(makeSpan(range: paint2, role: .string))
                    }
                }
            }

            return spans

        case .inRegexPercent(let close, let allowNesting, let depth):
            let r = scanPercentRegexBodyInLine(
                startIndex: lineRange.lowerBound,
                in: lineRange,
                close: close,
                allowNesting: allowNesting,
                depth: depth
            )
            if !r.closed {
                return [makeSpan(range: paintRange, role: .string)]
            }

            var spans: [KAttributedSpan] = []
            let closeIndex = r.closeIndex ?? (r.nextIndex - 1)
            let firstRange = lineRange.lowerBound..<(closeIndex + 1)
            let paint1 = paintRange.clamped(to: firstRange)
            if !paint1.isEmpty { spans.append(makeSpan(range: paint1, role: .string)) }

            if isInRegex(_lines[lineIndex].endState) {
                let rest = r.nextIndex..<lineRange.upperBound
                if let start = multiLineRegexPercentStartIndex(lineRange: rest) {
                    let paint2 = paintRange.clamped(to: start..<lineRange.upperBound)
                    if !paint2.isEmpty { spans.append(makeSpan(range: paint2, role: .string)) }
                }
            }
            return spans

        case .neutral:
            // この行が multi-line の開始行なら、開始位置から行末まで string 色
            if _lines[lineIndex].endState == .inDoubleQuote {
                if let start = multiLineDoubleQuoteStartIndex(lineRange: lineRange) {
                    let stringRange = start..<lineRange.upperBound
                    let paint = paintRange.clamped(to: stringRange)
                    if !paint.isEmpty {
                        return [makeSpan(range: paint, role: .string)]
                    }
                }
            }
            // この行が multi-line ' の開始行なら、開始位置から行末まで string 色
            if _lines[lineIndex].endState == .inSingleQuote {
                if let start = multiLineSingleQuoteStartIndex(lineRange: lineRange) {
                    let stringRange = start..<lineRange.upperBound
                    let paint = paintRange.clamped(to: stringRange)
                    if !paint.isEmpty {
                        return [makeSpan(range: paint, role: .string)]
                    }
                }
            }
            // この行が multi-line regex の開始行なら、開始位置から行末まで string 色
            if isInRegex(_lines[lineIndex].endState) {
                let slashStart = multiLineRegexSlashStartIndex(lineRange: lineRange)
                let percentStart = multiLineRegexPercentStartIndex(lineRange: lineRange)

                let start: Int?
                if let s0 = slashStart, let s1 = percentStart {
                    start = min(s0, s1)
                } else {
                    start = slashStart ?? percentStart
                }

                if let start {
                    let stringRange = start..<lineRange.upperBound
                    let paint = paintRange.clamped(to: stringRange)
                    if !paint.isEmpty {
                        return [makeSpan(range: paint, role: .string)]
                    }
                }
            }



            return []
        }
    }

    // MARK: - Line scan

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
        switch startState {
        case .inMultiComment:
            if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentEndBytes) {
                return .neutral
            }
            return .inMultiComment

        case .inHeredoc(let label, let allowIndent):
            if isHeredocTerminatorLine(lineRange: lineRange, label: label, allowIndent: allowIndent) {
                return .neutral
            }
            return .inHeredoc(label: label, allowIndent: allowIndent)

        case .inDoubleQuote:
            // 文字列継続中：この行で閉じた後も、同一行の残りに multi-line 開始がある可能性がある
            return scanLineForMultiLineState(lineRange: lineRange, startInDoubleQuote: true, startInSingleQuote: false)
            
        case .inSingleQuote:
            return scanLineForMultiLineState(lineRange: lineRange, startInDoubleQuote: false, startInSingleQuote: true)

        case .inRegexSlash(let inClass):
            return scanLineStartingInRegex(lineRange: lineRange, inClass: inClass)

        case .inRegexPercent(let close, let allowNesting, let depth):
            return scanLineStartingInPercentRegex(lineRange: lineRange, close: close, allowNesting: allowNesting, depth: depth)

        case .neutral:
            if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentBeginBytes) {
                return .inMultiComment
            }
            return scanLineForMultiLineState(lineRange: lineRange, startInDoubleQuote: false, startInSingleQuote: false)
        }
    }

    // MARK: - Multi comment helpers

    private func isLineHeadDirective(lineRange: Range<Int>, directiveBytes: [UInt8]) -> Bool {
        if lineRange.isEmpty { return false }

        let skeleton = storage.skeletonString
        let head = lineRange.lowerBound
        let end = lineRange.upperBound

        // Ruby の =begin/=end は行頭（カラム0）前提：空白スキップ等はしない
        if !skeleton.matchesPrefix(directiveBytes, at: head) { return false }

        let next = head + directiveBytes.count
        if next >= end { return true }

        let b = skeleton[next]
        return b == FC.space || b == FC.tab
    }


    // MARK: - Multi-line state scan (double-quote / heredoc)

    private func scanLineForMultiLineState(lineRange: Range<Int>, startInDoubleQuote: Bool, startInSingleQuote: Bool) -> KEndState {
        if lineRange.isEmpty {
            if startInSingleQuote { return .inSingleQuote }
            return startInDoubleQuote ? .inDoubleQuote : .neutral
        }


        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound

        // 行頭が「すでに quote の中」なら、この行で閉じを探す
        if startInDoubleQuote || startInSingleQuote {
            let quote = startInDoubleQuote ? FC.doubleQuote : FC.singleQuote

            switch storage.skeletonString.scan(in: i..<end, targets: [quote], escape: FC.backSlash) {
            case .notFound:
                return endState(for: quote)

            case .hit(let index, _):
                i = index + 1
            }
        }

        while i < end {
            let b = skeleton[i]

            // # comment: 以降は無視
            if b == FC.numeric { // '#'
                break
            }
            
            // quote: 単行で閉じるなら飛ばす、閉じないなら複数行へ
            if b == FC.doubleQuote || b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
                case .found(let next):
                    i = next
                    continue
                case .stopped(_):
                    return endState(for: b)
                case .notFound:
                    return endState(for: b)
                }
            }

            // %r... : 正規表現（単行で閉じれば読み飛ばし、閉じなければ endState）
            if b == FC.percent, i + 1 < end {
                let c = skeleton[i + 1]
                if c == 0x72 || c == 0x52 { // r/R
                    let delimIndex = i + 2
                    if delimIndex >= end { return .inRegexPercent(close: FC.percent, allowNesting: false, depth: 1) }

                    let opener = skeleton[delimIndex]
                    let info = percentDelimiterInfo(for: opener)

                    // opener の直後から本文
                    let bodyStart = delimIndex + 1
                    let rr = scanPercentRegexBodyInLine(
                        startIndex: bodyStart,
                        in: bodyStart..<end,
                        close: info.close,
                        allowNesting: info.allowNesting,
                        depth: info.initialDepth
                    )

                    if rr.closed {
                        i = rr.nextIndex
                        continue
                    } else {
                        return .inRegexPercent(close: info.close, allowNesting: info.allowNesting, depth: rr.endDepth)
                    }
                }
            }
            
            // /regex/ : 除算と区別できる場合のみ開始扱いする
            if b == FC.slash {
                if isRegexLikelyAfterSlash(slashIndex: i, in: lineRange) {
                    let rx = scanRegexLiteralInLine(slashIndex: i, in: lineRange)
                    if rx.closed {
                        i = rx.nextIndex
                        continue
                    } else {
                        return .inRegexSlash(inClass: rx.endInClass)
                    }
                }
            }

            // heredoc start candidate（クォート/正規表現/コメント外のみ）
            if b == FC.lt, i + 1 < end, skeleton[i + 1] == FC.lt {
                if let hd = parseHeredocAtIntroducer(introducerStart: i, in: lineRange) {
                    return .inHeredoc(label: hd.label, allowIndent: hd.allowIndent)
                }
            }

            i += 1
        }

        return .neutral
    }
    
    private func scanLineStartingInRegex(lineRange: Range<Int>, inClass: Int) -> KEndState {
        if lineRange.isEmpty { return .inRegexSlash(inClass: inClass) }

        let r = scanRegexBodyInLine(startIndex: lineRange.lowerBound, in: lineRange, inClass: inClass)

        if !r.closed {
            return .inRegexSlash(inClass: r.endInClass)
        }

        let rest = r.nextIndex..<lineRange.upperBound
        if rest.isEmpty { return .neutral }

        // 同一行の残りに、さらに複数行要素が始まる可能性があるので通常スキャンへ
        return scanLineForMultiLineState(lineRange: rest, startInDoubleQuote: false, startInSingleQuote: false)
    }
    
    private func scanLineStartingInPercentRegex(lineRange: Range<Int>, close: UInt8, allowNesting: Bool, depth: Int) -> KEndState {
        if lineRange.isEmpty { return .inRegexPercent(close: close, allowNesting: allowNesting, depth: depth) }

        let r = scanPercentRegexBodyInLine(startIndex: lineRange.lowerBound, in: lineRange, close: close, allowNesting: allowNesting, depth: depth)

        if !r.closed {
            return .inRegexPercent(close: close, allowNesting: allowNesting, depth: r.endDepth)
        }

        let rest = r.nextIndex..<lineRange.upperBound
        if rest.isEmpty { return .neutral }

        return scanLineForMultiLineState(lineRange: rest, startInDoubleQuote: false, startInSingleQuote: false)
    }

    
    // MARK: - Quote helpers

    private func endState(for quote: UInt8) -> KEndState {
        quote == FC.doubleQuote ? .inDoubleQuote : .inSingleQuote
    }

    

    // neutral 行内で「閉じない quote の開始位置」を探す（見つかったらその index を返す）
    // - # 以降は無視
    // - %r... は飛ばす（中の quote を拾わない）
    // - 反対側 quote が「閉じない」場合は、この行の状態が矛盾するので nil
    private func multiLineQuoteStartIndex(lineRange: Range<Int>, quote: UInt8) -> Int? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound
        while i < end {
            let b = skeleton[i]

            if b == FC.numeric { // '#'
                break
            }

            // %r... は飛ばす
            if b == FC.percent, i + 1 < end {
                let c = skeleton[i + 1]
                if c == 0x72 || c == 0x52 { // r/R
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FC.backSlash) {
                        case .found(let next):
                            i = next
                        case .stopped(_):
                            return nil
                        case .notFound:
                            i = end
                        }
                    } else {
                        i = end
                    }
                    continue
                }
            }

            // quote
            if b == FC.doubleQuote || b == FC.singleQuote {
                if b == quote {
                    // 対象 quote：閉じないなら開始位置
                    switch skeleton.skipQuotedInLine(for: quote, in: i..<end) {
                    case .found(let next):
                        i = next
                        continue
                    case .stopped(_), .notFound:
                        return i
                    }
                } else {
                    // 反対 quote：閉じないなら矛盾なので nil
                    switch skeleton.skipQuotedInLine(for: quote, in: i..<end) {
                    case .found(let next):
                        i = next
                        continue
                    case .stopped(_), .notFound:
                        return nil
                    }
                }
            }

            i += 1
        }

        return nil
    }

    private func multiLineDoubleQuoteStartIndex(lineRange: Range<Int>) -> Int? {
        multiLineQuoteStartIndex(lineRange: lineRange, quote: FC.doubleQuote)
    }

    private func multiLineSingleQuoteStartIndex(lineRange: Range<Int>) -> Int? {
        multiLineQuoteStartIndex(lineRange: lineRange, quote: FC.singleQuote)
    }

    // MARK: - Regex helpers
    
    private func isInRegex(_ state: KEndState) -> Bool {
        switch state {
        case .inRegexSlash: return true
        case .inRegexPercent: return true
        default: return false
        }
    }
    
    private func percentDelimiterInfo(for opener: UInt8) -> (close: UInt8, allowNesting: Bool, initialDepth: Int) {
        switch opener {
        case FC.leftParen:  return (close: FC.rightParen,  allowNesting: true,  initialDepth: 1)
        case FC.leftBracket:return (close: FC.rightBracket,allowNesting: true,  initialDepth: 1)
        case FC.leftBrace:  return (close: FC.rightBrace,  allowNesting: true,  initialDepth: 1)
        case FC.lt:         return (close: FC.gt,         allowNesting: true,  initialDepth: 1)
        default:            return (close: opener,         allowNesting: false, initialDepth: 1)
        }
    }

    // /regex/ の直前文脈（超簡易）
    private func isRegexLikelyAfterSlash(slashIndex: Int, in lineRange: Range<Int>) -> Bool {
        let skeleton = storage.skeletonString

        var j = slashIndex - 1
        while j >= lineRange.lowerBound {
            let b = skeleton[j]
            if b != FC.space && b != FC.tab { break }
            j -= 1
        }
        if j < lineRange.lowerBound { return true }

        switch skeleton[j] {
        case FC.equals, FC.plus, FC.asterisk, FC.percent,
             FC.caret, FC.pipe, FC.ampersand, FC.minus,
             FC.exclamation, FC.question, FC.colon, FC.semicolon,
             FC.comma, FC.leftParen, FC.leftBracket, FC.leftBrace,
             FC.lt, FC.gt:
            return true
        default:
            break
        }

        // 直前の英小文字連続が if / elsif なら regex とみなす（例: if /.../, elsif /.../）
        if skeleton[j].isAsciiLower {
            var k = j
            while k >= lineRange.lowerBound, skeleton[k].isAsciiLower { k -= 1 }
            let start = k + 1
            let len = j - start + 1

            if len == 2, skeleton[start] == 0x69, skeleton[start + 1] == 0x66 { // "if"
                return true
            }
            if len == 5,
               skeleton[start] == 0x65, skeleton[start + 1] == 0x6C, skeleton[start + 2] == 0x73,
               skeleton[start + 3] == 0x69, skeleton[start + 4] == 0x66 {       // "elsif"
                return true
            }
        }

        let prev = skeleton[j]
        if prev.isIdentStartAZ_ || prev.isAsciiDigit { return false }
        if prev == FC.rightParen || prev == FC.rightBracket || prev == FC.rightBrace { return false }
        return true
    }

    private func isEscaped(at index: Int, from lineStart: Int) -> Bool {
        let skeleton = storage.skeletonString
        var esc = 0
        var k = index - 1
        while k >= lineStart, skeleton[k] == FC.backSlash {
            esc += 1
            k -= 1
        }
        return (esc % 2) == 1
    }

    // opener '/' を含む（/.../flags）
    private func scanRegexLiteralInLine(slashIndex: Int, in lineRange: Range<Int>) -> (closed: Bool, nextIndex: Int, endInClass: Int) {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = slashIndex + 1
        var inClass = 0

        while i < end {
            let c = skeleton[i]

            if c == FC.leftBracket {
                if !isEscaped(at: i, from: lineRange.lowerBound) { inClass += 1 }
                i += 1
                continue
            }
            if c == FC.rightBracket, inClass > 0 {
                if !isEscaped(at: i, from: lineRange.lowerBound) { inClass -= 1 }
                i += 1
                continue
            }

            if c == FC.slash, inClass == 0 {
                if !isEscaped(at: i, from: lineRange.lowerBound) {
                    i += 1
                    // フラグをざっくり読み飛ばす
                    while i < end, skeleton[i].isAsciiAlpha { i += 1 }
                    return (closed: true, nextIndex: i, endInClass: 0)
                }
            }

            i += 1
        }

        return (closed: false, nextIndex: end, endInClass: inClass)
    }

    // opener を含まない（前行から継続している regex 本体）
    private func scanRegexBodyInLine(startIndex: Int, in lineRange: Range<Int>, inClass: Int) -> (closed: Bool, closeIndex: Int?, nextIndex: Int, endInClass: Int) {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = startIndex
        var cls = inClass

        while i < end {
            let c = skeleton[i]

            if c == FC.leftBracket {
                if !isEscaped(at: i, from: lineRange.lowerBound) { cls += 1 }
                i += 1
                continue
            }
            if c == FC.rightBracket, cls > 0 {
                if !isEscaped(at: i, from: lineRange.lowerBound) { cls -= 1 }
                i += 1
                continue
            }

            if c == FC.slash, cls == 0 {
                if !isEscaped(at: i, from: lineRange.lowerBound) {
                    let close = i
                    i += 1
                    while i < end, skeleton[i].isAsciiAlpha { i += 1 }
                    return (closed: true, closeIndex: close, nextIndex: i, endInClass: 0)
                }
            }

            i += 1
        }

        return (closed: false, closeIndex: nil, nextIndex: end, endInClass: cls)
    }

    private func scanPercentRegexBodyInLine(
        startIndex: Int,
        in lineRange: Range<Int>,
        close: UInt8,
        allowNesting: Bool,
        depth: Int
    ) -> (closed: Bool, closeIndex: Int?, nextIndex: Int, endDepth: Int) {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = startIndex
        var d = depth

        while i < end {
            let c = skeleton[i]

            if c == close && !isEscaped(at: i, from: lineRange.lowerBound) {
                d -= 1
                if d == 0 {
                    let closePos = i
                    i += 1
                    while i < end, skeleton[i].isAsciiAlpha { i += 1 } // flags
                    return (closed: true, closeIndex: closePos, nextIndex: i, endDepth: 0)
                }
                i += 1
                continue
            }

            if allowNesting {
                // opener は close の対になるものだけネスト対象にする（{[(
                if close == FC.rightParen, c == FC.leftParen, !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
                if close == FC.rightBracket, c == FC.leftBracket, !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
                if close == FC.rightBrace, c == FC.leftBrace, !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
                if close == FC.gt, c == FC.lt, !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
            }

            i += 1
        }

        return (closed: false, closeIndex: nil, nextIndex: end, endDepth: d)
    }

    // neutral 行内で「閉じない /regex/ の開始位置」を探す（見つかったら slash の index を返す）
    private func multiLineRegexSlashStartIndex(lineRange: Range<Int>) -> Int? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound
        var i = lineRange.lowerBound

        while i < end {
            let b = skeleton[i]

            if b == FC.numeric { // '#'
                break
            }

            // %r... は飛ばす（中の / を拾わない）
            if b == FC.percent, i + 1 < end {
                let c = skeleton[i + 1]
                if c == 0x72 || c == 0x52 { // r/R
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FC.backSlash) {
                        case .found(let next):
                            i = next
                        case .stopped, .notFound:
                            return nil
                        }
                    } else {
                        return nil
                    }
                    continue
                }
            }

            // quote は飛ばす（中の / を拾わない）
            if b == FC.doubleQuote || b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
                case .found(let next):
                    i = next
                    continue
                case .stopped, .notFound:
                    return nil
                }
            }

            if b == FC.slash, isRegexLikelyAfterSlash(slashIndex: i, in: lineRange) {
                let rx = scanRegexLiteralInLine(slashIndex: i, in: lineRange)
                if rx.closed {
                    i = rx.nextIndex
                    continue
                }
                return i
            }

            i += 1
        }

        return nil
    }

    private func multiLineRegexPercentStartIndex(lineRange: Range<Int>) -> Int? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound
        var i = lineRange.lowerBound

        while i < end {
            let b = skeleton[i]
            if b == FC.numeric { break } // '#'

            // quote は飛ばす
            if b == FC.doubleQuote || b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
                case .found(let next): i = next; continue
                case .stopped, .notFound: return nil
                }
            }

            if b == FC.percent, i + 1 < end {
                let c = skeleton[i + 1]
                if c == 0x72 || c == 0x52 { // r/R
                    let delimIndex = i + 2
                    if delimIndex >= end { return i }
                    let info = percentDelimiterInfo(for: skeleton[delimIndex])
                    let bodyStart = delimIndex + 1
                    let rr = scanPercentRegexBodyInLine(
                        startIndex: bodyStart,
                        in: bodyStart..<end,
                        close: info.close,
                        allowNesting: info.allowNesting,
                        depth: info.initialDepth
                    )
                    if rr.closed {
                        i = rr.nextIndex
                        continue
                    }
                    return i
                }
            }

            i += 1
        }
        return nil
    }




    // MARK: - Heredoc parsing

    private func parseHeredocAtIntroducer(
        introducerStart: Int,
        in lineRange: Range<Int>
    ) -> (label: [UInt8], allowIndent: Bool, introducerRange: Range<Int>)? {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var j = introducerStart + 2
        if j >= end { return nil }

        // `<<=` は除外
        if skeleton[j] == FC.equals { return nil }

        var allowIndent = false
        if skeleton[j] == FC.minus || skeleton[j] == FC.tilde {
            allowIndent = true
            j += 1
            if j >= end { return nil }
        }

        let c = skeleton[j]

        // quoted label: <<'EOF' / <<"EOF"
        if c == FC.singleQuote || c == FC.doubleQuote {
            if let info = readQuotedLabel(from: j, in: lineRange) {
                return (label: info.label, allowIndent: allowIndent, introducerRange: introducerStart..<info.endExclusive)
            }
            return nil
        }

        // unquoted label: <<EOF
        if !(c.isAsciiUpper || c == FC.underscore) { return nil }

        if let info = readUnquotedLabel(from: j, in: lineRange) {
            return (label: info.label, allowIndent: allowIndent, introducerRange: introducerStart..<info.endExclusive)
        }

        return nil
    }

    private func readQuotedLabel(from quoteIndex: Int, in lineRange: Range<Int>) -> (label: [UInt8], endExclusive: Int)? {
        let skeleton = storage.skeletonString
        let quote = skeleton[quoteIndex]

        var i = quoteIndex + 1
        let end = lineRange.upperBound
        if i >= end { return nil }

        let start = i
        while i < end {
            if skeleton[i] == quote {
                if i <= start { return nil }
                let label = Array(skeleton.bytes(in: start..<i))
                return (label: label, endExclusive: i + 1)
            }
            i += 1
        }

        return nil
    }

    private func readUnquotedLabel(from startIndex: Int, in lineRange: Range<Int>) -> (label: [UInt8], endExclusive: Int)? {
        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = startIndex
        while i < end {
            let b = skeleton[i]
            if !(b.isAsciiUpper || b.isAsciiDigit || b == FC.underscore) {
                break
            }
            i += 1
        }

        if i <= startIndex { return nil }
        let label = Array(skeleton.bytes(in: startIndex..<i))
        return (label: label, endExclusive: i)
    }

    private func isHeredocTerminatorLine(lineRange: Range<Int>, label: [UInt8], allowIndent: Bool) -> Bool {
        if lineRange.isEmpty { return false }
        let skeleton = storage.skeletonString

        var head = lineRange.lowerBound
        let end = lineRange.upperBound

        if allowIndent {
            while head < end {
                let b = skeleton[head]
                if b != FC.space && b != FC.tab { break }
                head += 1
            }
        }

        if label.isEmpty { return false }
        if head + label.count > end { return false }

        if !skeleton.matchesPrefix(label, at: head) { return false }

        let next = head + label.count
        if next >= end { return true }

        let b = skeleton[next]
        return b == FC.space || b == FC.tab
    }
}
