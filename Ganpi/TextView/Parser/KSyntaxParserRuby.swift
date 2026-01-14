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
        let rebuilt = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
        if _lines.isEmpty { return }

        let plan = consumeRescanPlan(for: range)

        let startLine = rebuilt ? 0 : plan.startLine
        scanFrom(line: startLine, minLine: plan.minLine)
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
        if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentBeginBytes)
            || isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentEndBytes) {
            return [makeSpan(range: paintRange, role: .comment)]
        }

        switch startState {
        case .inMultiComment:
            return [makeSpan(range: paintRange, role: .comment)]

        case .inHeredoc:
            return [makeSpan(range: paintRange, role: .string)]

        case .inDoubleQuote:
            // 行頭から閉じ " まで（無ければ行末まで）
            switch skeleton.scan(in: lineRange, targets: [FuncChar.doubleQuote], escape: FuncChar.backSlash) {
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
            return scanLineForMultiLineState(lineRange: lineRange, startInDoubleQuote: true)

        case .neutral:
            if isLineHeadDirective(lineRange: lineRange, directiveBytes: _commentBeginBytes) {
                return .inMultiComment
            }
            return scanLineForMultiLineState(lineRange: lineRange, startInDoubleQuote: false)
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
        return b == FuncChar.space || b == FuncChar.tab
    }


    // MARK: - Multi-line state scan (double-quote / heredoc)

    private func scanLineForMultiLineState(lineRange: Range<Int>, startInDoubleQuote: Bool) -> KEndState {
        if lineRange.isEmpty {
            return startInDoubleQuote ? .inDoubleQuote : .neutral
        }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound

        // 行頭が「すでに " の中」なら、この行で閉じを探す
        if startInDoubleQuote {
            switch skeleton.scan(in: i..<end, targets: [FuncChar.doubleQuote], escape: FuncChar.backSlash) {
            case .notFound:
                return .inDoubleQuote

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

            // single quote: 単行だけ飛ばす（複数行は後で）
            if b == FuncChar.singleQuote {
                switch skeleton.skipSingleQuotedInLine(in: i..<end, escape: FuncChar.backSlash) {
                case .found(let next):
                    i = next
                case .stopped:
                    // lineRange に LF は無い想定だが安全側
                    return .neutral
                case .notFound:
                    i = end
                }
                continue
            }

            // %r... 正規表現リテラル内は飛ばす（" や << を拾わないため）
            if b == FuncChar.percent, i + 1 < end {
                let c = skeleton[i + 1]
                if c == 0x72 || c == 0x52 { // 'r' or 'R'
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FuncChar.backSlash) {
                        case .found(let next):
                            i = next
                        case .stopped:
                            return .neutral
                        case .notFound:
                            i = end
                        }
                    } else {
                        i = end
                    }
                    continue
                }
            }

            // double quote: 単行で閉じるなら飛ばす、閉じないなら複数行へ
            if b == FuncChar.doubleQuote {
                switch skeleton.skipDoubleQuotedInLine(in: i..<end, escape: FuncChar.backSlash) {
                case .found(let next):
                    i = next
                    continue
                case .stopped, .notFound:
                    return .inDoubleQuote
                }
            }

            // heredoc start candidate（クォート/正規表現/コメント外のみ）
            if b == FuncChar.lt, i + 1 < end, skeleton[i + 1] == FuncChar.lt {
                if let hd = parseHeredocAtIntroducer(introducerStart: i, in: lineRange) {
                    return .inHeredoc(label: hd.label, allowIndent: hd.allowIndent)
                }
            }

            i += 1
        }

        return .neutral
    }


    private func multiLineDoubleQuoteStartIndex(lineRange: Range<Int>) -> Int? {
        if lineRange.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let end = lineRange.upperBound

        var i = lineRange.lowerBound
        while i < end {
            let b = skeleton[i]

            if b == FC.numeric { // '#'
                break
            }

            if b == FuncChar.singleQuote {
                switch skeleton.skipSingleQuotedInLine(in: i..<end, escape: FuncChar.backSlash) {
                case .found(let next):
                    i = next
                case .stopped:
                    return nil
                case .notFound:
                    i = end
                }
                continue
            }

            if b == FuncChar.percent, i + 1 < end {
                let c = skeleton[i + 1]
                if c == 0x72 || c == 0x52 { // 'r' or 'R'
                    let openerIndex = i + 2
                    if openerIndex < end {
                        switch skeleton.skipDelimitedInLine(in: openerIndex..<end, allowNesting: true, escape: FuncChar.backSlash) {
                        case .found(let next):
                            i = next
                        case .stopped:
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

            if b == FuncChar.doubleQuote {
                switch skeleton.skipDoubleQuotedInLine(in: i..<end, escape: FuncChar.backSlash) {
                case .found(let next):
                    i = next          // 単行で閉じたので次へ
                case .stopped, .notFound:
                    return i          // 閉じない＝複数行の開始
                }
                continue
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
        if skeleton[j] == FuncChar.equals { return nil }

        var allowIndent = false
        if skeleton[j] == FuncChar.minus || skeleton[j] == FuncChar.tilde {
            allowIndent = true
            j += 1
            if j >= end { return nil }
        }

        let c = skeleton[j]

        // quoted label: <<'EOF' / <<"EOF"
        if c == FuncChar.singleQuote || c == FuncChar.doubleQuote {
            if let info = readQuotedLabel(from: j, in: lineRange) {
                return (label: info.label, allowIndent: allowIndent, introducerRange: introducerStart..<info.endExclusive)
            }
            return nil
        }

        // unquoted label: <<EOF
        if !(c.isAsciiUpper || c == FuncChar.underscore) { return nil }

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
            if !(b.isAsciiUpper || b.isAsciiDigit || b == FuncChar.underscore) {
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
                if b != FuncChar.space && b != FuncChar.tab { break }
                head += 1
            }
        }

        if label.isEmpty { return false }
        if head + label.count > end { return false }

        if !skeleton.matchesPrefix(label, at: head) { return false }

        let next = head + label.count
        if next >= end { return true }

        let b = skeleton[next]
        return b == FuncChar.space || b == FuncChar.tab
    }
}
