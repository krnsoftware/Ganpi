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
        case afterEnd
        case inMultiComment
        case inHeredoc(label: [UInt8], allowIndent: Bool)
        case inDoubleQuote
        case inSingleQuote
        case inRegexSlash(inClass: Int)
        case inRegexPercent(close: UInt8, allowNesting: Bool, depth: Int)
        case inPercentLiteral(close: UInt8, allowNesting: Bool, depth: Int)
    }



    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    private let _commentBeginBytes = Array("=begin".utf8)
    private let _commentEndBytes   = Array("=end".utf8)
    private let _endDirectiveBytes = Array("__END__".utf8)
    
    private let _regexStartKeywordBytes: [[UInt8]] = [
        Array("and".utf8),
        Array("case".utf8),
        Array("do".utf8),
        Array("elsif".utf8),
        Array("if".utf8),
        Array("in".utf8),
        Array("not".utf8),
        Array("or".utf8),
        Array("raise".utf8),
        Array("return".utf8),
        Array("then".utf8),
        Array("unless".utf8),
        Array("until".utf8),
        Array("when".utf8),
        Array("while".utf8),
    ]
    
    // percent literal type bytes
    // - string系: %q %Q %w %W %i %I %s %S %x %X
    // - regex系:  %r %R（こちらは既存の regex ルートで処理）
    private let _percentStringTypeBytes: [UInt8] = Array("qQwWiIsSxX".utf8)
    private let _percentRegexTypeBytes: [UInt8] = Array("rR".utf8)

    // “percent literal 全般”をスキップするための集合（誤検出防止に使う）
    private let _percentAllTypeBytes: [UInt8] = Array("qQwWiIsSxXrR".utf8)




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

    override func wordRange(at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let n = skeleton.count

        if index < 0 || index > n { return nil }
        if n == 0 { return nil }

        func isSuffix(_ b: UInt8) -> Bool {
            b == FC.question || b == FC.exclamation || b == FC.equals
        }

        // 1) カーソル位置（index）または直前（index-1）が「単語に触れている」か判定
        var p: Int? = nil

        if index < n {
            let b = skeleton[index]
            if b.isIdentPartAZ09_ || isSuffix(b) {
                p = index
            }
        }

        if p == nil, index > 0 {
            let b = skeleton[index - 1]
            if b.isIdentPartAZ09_ || isSuffix(b) {
                p = index - 1
            }
        }

        guard let pos = p else { return nil }

        // 2) pos が suffix の場合：直前が識別子本体でなければ単語ではない
        var corePos = pos
        if isSuffix(skeleton[pos]) {
            if pos == 0 { return nil }
            let prev = skeleton[pos - 1]
            if !prev.isIdentPartAZ09_ { return nil }
            corePos = pos - 1
        }

        // 3) 左へ：識別子本体（[A-Za-z0-9_]）を伸ばす
        var left = corePos
        while left > 0 {
            let b = skeleton[left - 1]
            if !b.isIdentPartAZ09_ { break }
            left -= 1
        }

        // 先頭は [A-Za-z_] 必須
        if !skeleton[left].isIdentStartAZ_ { return nil }

        // 4) 右へ：識別子本体を伸ばす
        var right = corePos + 1
        while right < n {
            let b = skeleton[right]
            if !b.isIdentPartAZ09_ { break }
            right += 1
        }

        // 5) 末尾に限り ? / ! / = を 0〜1 個だけ許す
        if right < n, isSuffix(skeleton[right]) {
            right += 1
        }

        return left..<right
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
        // - "=begin" は neutral のときだけコメント色（文字列/正規表現/heredoc 内では無視）
        // - "=end"   は multi comment 中（前行 endState が inMultiComment）のときだけコメント色
        if startState == .neutral {
            if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentBeginBytes) {
                return [makeSpan(range: paintRange, role: .comment)]
            }
            if isLineHeadDirective(lineRange: lineRange, directiveBytes: _endDirectiveBytes) {
                return [makeSpan(range: paintRange, role: .comment)]
            }
        }
        if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentEndBytes) {
            if startState == .inMultiComment {
                return [makeSpan(range: paintRange, role: .comment)]
            }
        }

        switch startState {
        case .afterEnd:
            return [makeSpan(range: paintRange, role: .comment)]
            
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

                // 閉じた後の残り（コメントを追加し、comment手前までを次走査範囲にする）
                let restAll = (closeIndex + 1)..<lineRange.upperBound
                let rest = appendTrailingComment(spans: &spans,
                                                 rest: restAll,
                                                 paintRange: paintRange,
                                                 lineEnd: lineRange.upperBound)

                // この行の残りに、さらに複数行 " の開始があるならそこから行末まで
                if _lines[lineIndex].endState == .inDoubleQuote {
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

                // 閉じた後の残り
                let restAll = (closeIndex + 1)..<lineRange.upperBound
                let rest = appendTrailingComment(spans: &spans,
                                                 rest: restAll,
                                                 paintRange: paintRange,
                                                 lineEnd: lineRange.upperBound)

                // この行の残りに、さらに複数行 ' の開始があるならそこから行末まで
                if _lines[lineIndex].endState == .inSingleQuote {
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
            let r = scanRegexBodyInLine(startIndex: lineRange.lowerBound, in: lineRange, inClass: inClass)
            if !r.closed {
                return [makeSpan(range: paintRange, role: .string)]
            }

            var spans: [KAttributedSpan] = []

            let closeIndex = r.closeIndex ?? (r.nextIndex - 1)
            let firstRegexRange = lineRange.lowerBound..<(closeIndex + 1)
            let paint1 = paintRange.clamped(to: firstRegexRange)
            if !paint1.isEmpty {
                spans.append(makeSpan(range: paint1, role: .string))
            }

            let restAll = r.nextIndex..<lineRange.upperBound
            let rest = appendTrailingComment(spans: &spans,
                                             rest: restAll,
                                             paintRange: paintRange,
                                             lineEnd: lineRange.upperBound)

            // 同一行の残りに、さらに multi-line regex の開始があるならそこから行末まで
            if isInRegex(_lines[lineIndex].endState) {
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
            if !paint1.isEmpty {
                spans.append(makeSpan(range: paint1, role: .string))
            }

            let restAll = r.nextIndex..<lineRange.upperBound
            let rest = appendTrailingComment(spans: &spans,
                                             rest: restAll,
                                             paintRange: paintRange,
                                             lineEnd: lineRange.upperBound)

            if isInRegex(_lines[lineIndex].endState) {
                if let start = multiLineRegexPercentStartIndex(lineRange: rest) {
                    let paint2 = paintRange.clamped(to: start..<lineRange.upperBound)
                    if !paint2.isEmpty {
                        spans.append(makeSpan(range: paint2, role: .string))
                    }
                }
            }

            return spans
            
        case .inPercentLiteral(let close, let allowNesting, let depth):
            let r = scanPercentLiteralBodyInLine(
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
            if !paint1.isEmpty {
                spans.append(makeSpan(range: paint1, role: .string))
            }

            let restAll = r.nextIndex..<lineRange.upperBound
            let rest = appendTrailingComment(spans: &spans,
                                             rest: restAll,
                                             paintRange: paintRange,
                                             lineEnd: lineRange.upperBound)

            // 同一行の残りに、さらに multi-line percent literal の開始があるならそこから行末まで
            if case .inPercentLiteral = _lines[lineIndex].endState {
                if let start = multiLinePercentLiteralStartIndex(lineRange: rest) {
                    let paint2 = paintRange.clamped(to: start..<lineRange.upperBound)
                    if !paint2.isEmpty {
                        spans.append(makeSpan(range: paint2, role: .string))
                    }
                }
            }

            return spans
            
        case .neutral:
            // まず neutral 行の中の "..." / '...' / /.../ / %... / #comment を span 化
            var spans = neutralLineSpans(lineRange: lineRange, paintRange: paintRange)

            // heredoc の開始行なら、「<<...LABEL」部分だけ string 色で追加
            if case .inHeredoc = _lines[lineIndex].endState {
                if let introducerRange = heredocIntroducerRangeInLine(lineRange: lineRange) {
                    let paint = paintRange.clamped(to: introducerRange)
                    if !paint.isEmpty {
                        spans.append(makeSpan(range: paint, role: .string))
                    }
                }
            }

            return spans

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
        case .afterEnd:
            return .afterEnd

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

        case .inPercentLiteral(let close, let allowNesting, let depth):
            return scanLineStartingInPercentLiteral(lineRange: lineRange, close: close, allowNesting: allowNesting, depth: depth)

        case .neutral:
            if isLineHeadDirective(lineRange: lineRange, directiveBytes: _endDirectiveBytes) {
                return .afterEnd
            }
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

            // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X/%r/%R
            // - 単行で閉じれば読み飛ばす
            // - 閉じなければ endState
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]

                // %r/%R : 正規表現（既存ルート）
                if _percentRegexTypeBytes.contains(type) {
                    let delimIndex = i + 2
                    if delimIndex >= end {
                        return .inRegexPercent(close: FC.percent, allowNesting: false, depth: 1)
                    }

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
                    return .inRegexPercent(close: info.close, allowNesting: info.allowNesting, depth: rr.endDepth)
                }

                // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X : 文字列系（新ルート）
                if _percentStringTypeBytes.contains(type) {
                    let delimIndex = i + 2
                    if delimIndex >= end {
                        return .inPercentLiteral(close: FC.percent, allowNesting: false, depth: 1)
                    }

                    let info = percentDelimiterInfo(for: skeleton[delimIndex])
                    let bodyStart = delimIndex + 1

                    let rr = scanPercentLiteralBodyInLine(
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
                    return .inPercentLiteral(close: info.close, allowNesting: info.allowNesting, depth: rr.endDepth)
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
    
    private func scanLineStartingInPercentLiteral(lineRange: Range<Int>, close: UInt8, allowNesting: Bool, depth: Int) -> KEndState {
        if lineRange.isEmpty { return .inPercentLiteral(close: close, allowNesting: allowNesting, depth: depth) }

        let r = scanPercentLiteralBodyInLine(startIndex: lineRange.lowerBound, in: lineRange, close: close, allowNesting: allowNesting, depth: depth)

        if !r.closed {
            return .inPercentLiteral(close: close, allowNesting: allowNesting, depth: r.endDepth)
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

            // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X/%r/%R は飛ばす（中の quote を拾わない）
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]
                if _percentAllTypeBytes.contains(type) {
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FC.backSlash) {
                        case .found(let next):
                            i = next
                            continue
                        case .stopped, .notFound:
                            return nil
                        }
                    }
                    return nil
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
                    switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
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
    
    private func commentStartIndexInLine(lineRange: Range<Int>) -> Int? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound
        var i = lineRange.lowerBound

        while i < end {
            let b = skeleton[i]

            // '#' 以降はコメント
            if b == FC.numeric { // '#'
                return i
            }

            // %... は飛ばす（中の # を拾わない）
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]
                if _percentAllTypeBytes.contains(type) {
                    let delimIndex = i + 2
                    if delimIndex >= end { return nil }

                    switch skeleton.skipDelimitedInLine(in: delimIndex..<end, allowNesting: true, escape: FC.backSlash) {
                    case .found(let next):
                        i = next
                        continue
                    case .stopped, .notFound:
                        return nil
                    }
                }
            }

            // quote は飛ばす（中の # を拾わない）
            if b == FC.doubleQuote || b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
                case .found(let next):
                    i = next
                    continue
                case .stopped, .notFound:
                    return nil
                }
            }

            // /regex/ は飛ばす（中の # を拾わない）
            if b == FC.slash, isRegexLikelyAfterSlash(slashIndex: i, in: lineRange) {
                let rx = scanRegexLiteralInLine(slashIndex: i, in: lineRange)
                if rx.closed {
                    i = rx.nextIndex
                    continue
                }
                return nil
            }

            i += 1
        }

        return nil
    }
    
    private func appendTrailingComment(spans: inout [KAttributedSpan],
                                       rest: Range<Int>,
                                       paintRange: Range<Int>,
                                       lineEnd: Int) -> Range<Int> {
        if rest.isEmpty { return rest }

        if let commentStart = commentStartIndexInLine(lineRange: rest) {
            let commentRange = commentStart..<lineEnd
            let paintC = paintRange.clamped(to: commentRange)
            if !paintC.isEmpty {
                spans.append(makeSpan(range: paintC, role: .comment))
            }
            return rest.lowerBound..<commentStart
        }
        return rest
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

    private func isRegexLikelyAfterSlash(slashIndex: Int, in lineRange: Range<Int>) -> Bool {
        let skeleton = storage.skeletonString

        // 直前の空白を飛ばす
        var j = slashIndex - 1
        while j >= lineRange.lowerBound {
            let b = skeleton[j]
            if b != FC.space && b != FC.tab { break }
            j -= 1
        }
        if j < lineRange.lowerBound {
            return true // 行頭は regex 寄り
        }

        // 直前の空白を飛ばしたあと、j は直前の非空白位置

        let prev = skeleton[j]

        // ★先に「キーワード直後」を見る（ここが重要）
        if prev.isAsciiLower {
            var k = j
            while k >= lineRange.lowerBound, skeleton[k].isAsciiLower { k -= 1 }
            let wordRange = (k + 1)..<(j + 1)
            if skeleton.matches(words: _regexStartKeywordBytes, in: wordRange) {
                return true
            }
        }

        // ここから「除算寄り」の早期 return をして良い
        if prev == FC.period { return false }   // FC.period がある前提
        if prev.isIdentStartAZ_ || prev.isAsciiDigit { return false }
        if prev == FC.rightParen || prev == FC.rightBracket || prev == FC.rightBrace { return false }

        // 2) 明確に「regex開始寄り」な直前記号
        switch prev {
        case FC.equals, FC.plus, FC.asterisk, FC.percent,
             FC.caret, FC.pipe, FC.ampersand, FC.minus,
             FC.exclamation, FC.question, FC.colon, FC.semicolon,
             FC.comma, FC.leftParen, FC.leftBracket, FC.leftBrace,
             FC.lt, FC.gt:
            return true
        default:
            break
        }

        // 3) キーワード直後（if/elsif/when/while/until/unless）を regex 寄りにする
        //    直前が英小文字の連続なら、その単語を拾って判定
        if prev.isAsciiLower {
            var k = j
            while k >= lineRange.lowerBound, skeleton[k].isAsciiLower { k -= 1 }
            let wordRange = (k + 1)..<(j + 1)

            if skeleton.matches(words: _regexStartKeywordBytes, in: wordRange) {
                return true
            }
        }

        // 4) ここまで来たら「regex寄り」に倒す（色付けとして破綻しにくい側）
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
    
    private func scanPercentLiteralBodyInLine(
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
                    let next = i + 1
                    return (closed: true, closeIndex: closePos, nextIndex: next, endDepth: 0)
                }
                i += 1
                continue
            }

            if allowNesting {
                // opener は close の対になるものだけネスト対象にする（{[(<）
                if close == FC.rightParen,   c == FC.leftParen,   !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
                if close == FC.rightBracket, c == FC.leftBracket, !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
                if close == FC.rightBrace,   c == FC.leftBrace,   !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
                if close == FC.gt,           c == FC.lt,          !isEscaped(at: i, from: lineRange.lowerBound) { d += 1; i += 1; continue }
            }

            i += 1
        }

        return (closed: false, closeIndex: nil, nextIndex: end, endDepth: d)
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

            // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X/%r/%R は飛ばす（中の / を拾わない）
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]
                if _percentAllTypeBytes.contains(type) {
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FC.backSlash) {
                        case .found(let next):
                            i = next
                            continue
                        case .stopped, .notFound:
                            return nil
                        }
                    }
                    return nil
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
                case .found(let next):
                    i = next
                    continue
                case .stopped, .notFound:
                    return nil
                }
            }

            // %q... 等は “誤検出防止として” 単行で飛ばすが、閉じない場合は nil（この関数の担当外）
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]

                // %r/%R だけが対象
                if _percentRegexTypeBytes.contains(type) {
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

                // 他の %q... は単行で閉じるなら飛ばす
                if _percentStringTypeBytes.contains(type) {
                    let delimIndex = i + 2
                    if delimIndex >= end { return nil }

                    switch skeleton.skipDelimitedInLine(in: delimIndex..<end, allowNesting: true, escape: FC.backSlash) {
                    case .found(let next):
                        i = next
                        continue
                    case .stopped, .notFound:
                        return nil
                    }
                }
            }

            i += 1
        }

        return nil
    }


    private func multiLinePercentLiteralStartIndex(lineRange: Range<Int>) -> Int? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound
        var i = lineRange.lowerBound

        while i < end {
            let b = skeleton[i]

            // '#' comment 以降は無視
            if b == FC.numeric { break }

            // quote は飛ばす（中の % を拾わない）
            if b == FC.doubleQuote || b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
                case .found(let next):
                    i = next
                    continue
                case .stopped(_), .notFound:
                    return nil
                }
            }

            // /regex/ は飛ばす（閉じないならこの行は regex 継続で、percent literal 開始ではない）
            if b == FC.slash {
                if isRegexLikelyAfterSlash(slashIndex: i, in: lineRange) {
                    let rx = scanRegexLiteralInLine(slashIndex: i, in: lineRange)
                    if rx.closed {
                        i = rx.nextIndex
                        continue
                    }
                    return nil
                }
            }

            // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X を探す
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]

                // %r/%R を含む “percent 全般” は中身を飛ばす（誤検出防止）
                if _percentAllTypeBytes.contains(type) {
                    let delimIndex = i + 2
                    if delimIndex >= end {
                        // 行末で途切れている：ここが開始位置になり得るのは string 系のみ
                        return _percentStringTypeBytes.contains(type) ? i : nil
                    }

                    // delimiter から閉じまでを「単行で」スキップできるなら飛ばす
                    switch skeleton.skipDelimitedInLine(in: delimIndex..<end, allowNesting: true, escape: FC.backSlash) {
                    case .found(let next):
                        i = next
                        continue
                    case .stopped(_), .notFound:
                        // 単行で閉じなかった：string 系なら開始位置
                        return _percentStringTypeBytes.contains(type) ? i : nil
                    }
                }
            }

            i += 1
        }

        return nil
    }




    // MARK: - Heredoc parsing
    
    private func heredocIntroducerRangeInLine(lineRange: Range<Int>) -> Range<Int>? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound
        while i < end {
            let b = skeleton[i]

            // # comment: 以降は無視
            if b == FC.numeric { // '#'
                break
            }

            // %... は飛ばす（中の << を拾わない）
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]
                if _percentAllTypeBytes.contains(type) {
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FC.backSlash) {
                        case .found(let next):
                            i = next
                            continue
                        case .stopped(_), .notFound:
                            return nil
                        }
                    }
                    return nil
                }
            }

            // quote は飛ばす（中の << を拾わない）
            if b == FC.doubleQuote || b == FC.singleQuote {
                switch skeleton.skipQuotedInLine(for: b, in: i..<end) {
                case .found(let next):
                    i = next
                    continue
                case .stopped(_), .notFound:
                    return nil
                }
            }

            // /regex/ は飛ばす（中の << を拾わない）
            if b == FC.slash {
                if isRegexLikelyAfterSlash(slashIndex: i, in: lineRange) {
                    let rx = scanRegexLiteralInLine(slashIndex: i, in: lineRange)
                    if rx.closed {
                        i = rx.nextIndex
                        continue
                    }
                    return nil
                }
            }

            // heredoc introducer
            if b == FC.lt, i + 1 < end, skeleton[i + 1] == FC.lt {
                if let hd = parseHeredocAtIntroducer(introducerStart: i, in: lineRange) {
                    return hd.introducerRange
                }
            }

            i += 1
        }

        return nil
    }


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
    
    
    private func neutralLineSpans(lineRange: Range<Int>, paintRange: Range<Int>) -> [KAttributedSpan] {
        if lineRange.isEmpty || paintRange.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        func isSuffix(_ b: UInt8) -> Bool {
            b == FC.question || b == FC.exclamation || b == FC.equals
        }

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(4)

        var i = lineRange.lowerBound
        while i < end {
            let b = skeleton[i]

            // コメント開始
            if b == FC.numeric { // '#'
                let r = i..<end
                let p = paintRange.clamped(to: r)
                if !p.isEmpty {
                    spans.append(makeSpan(range: p, role: .comment))
                }
                break
            }

            // "..."
            if b == FC.doubleQuote {
                let start = i
                i += 1
                while i < end {
                    let c = skeleton[i]
                    if c == FC.backSlash {
                        i += 1
                        if i < end { i += 1 }
                        continue
                    }
                    if c == FC.doubleQuote {
                        i += 1
                        let r = start..<i
                        let p = paintRange.clamped(to: r)
                        if !p.isEmpty { spans.append(makeSpan(range: p, role: .string)) }
                        break
                    }
                    i += 1
                }
                if i >= end {
                    let r = start..<end
                    let p = paintRange.clamped(to: r)
                    if !p.isEmpty { spans.append(makeSpan(range: p, role: .string)) }
                    break
                }
                continue
            }

            // '...'
            if b == FC.singleQuote {
                let start = i
                i += 1
                while i < end {
                    let c = skeleton[i]
                    if c == FC.backSlash {
                        i += 1
                        if i < end { i += 1 }
                        continue
                    }
                    if c == FC.singleQuote {
                        i += 1
                        let r = start..<i
                        let p = paintRange.clamped(to: r)
                        if !p.isEmpty { spans.append(makeSpan(range: p, role: .string)) }
                        break
                    }
                    i += 1
                }
                if i >= end {
                    let r = start..<end
                    let p = paintRange.clamped(to: r)
                    if !p.isEmpty { spans.append(makeSpan(range: p, role: .string)) }
                    break
                }
                continue
            }

            // /.../（割り算との誤爆は isRegexLikelyAfterSlash で抑える）
            if b == FC.slash {
                if isRegexLikelyAfterSlash(slashIndex: i, in: lineRange) {
                    let start = i
                    let rx = scanRegexLiteralInLine(slashIndex: i, in: lineRange)
                    let r = start..<(rx.closed ? rx.nextIndex : end)
                    let p = paintRange.clamped(to: r)
                    if !p.isEmpty { spans.append(makeSpan(range: p, role: .string)) }
                    i = rx.closed ? rx.nextIndex : end
                    continue
                }
            }

            // %q/%Q/%w/%W/%i/%I/%s/%S/%x/%X/%r/%R（単行で閉じるものは丸ごと塗る）
            if b == FC.percent, i + 1 < end {
                let type = skeleton[i + 1]
                if _percentAllTypeBytes.contains(type) {
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FC.backSlash) {
                        case .found(let next):
                            let r = i..<next
                            let p = paintRange.clamped(to: r)
                            if !p.isEmpty {
                                // %r/%R は regex（ここでは string 色で統一）
                                spans.append(makeSpan(range: p, role: .string))
                            }
                            i = next
                            continue
                        case .stopped(_), .notFound:
                            // 行内で閉じない → 以降は multi-line 側が効くのでここでは終了
                            let r = i..<end
                            let p = paintRange.clamped(to: r)
                            if !p.isEmpty { spans.append(makeSpan(range: p, role: .string)) }
                            i = end
                            break
                        }
                    } else {
                        // "%q" で行終端など
                        i = end
                    }
                    continue
                }
            }

            // 通常文字
            i += 1
        }

        return spans
    }

}
