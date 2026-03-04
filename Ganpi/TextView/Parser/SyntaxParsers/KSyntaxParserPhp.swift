//
//  KSyntaxParserPhp.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

/// PHP（テンプレート混在）向け
/// - `<?php ... ?>` / `<?= ... ?>` / `<? ... ?>` を PHP として解釈
/// - PHP 以外（HTML 部分）は comment color でグレーアウト
/// - PHP 内は `//` `#` `/* */` と `'` `"` `` ` ``、heredoc/nowdoc を基本サポート
///
/// 注:
/// - `<?xml ... ?>` は XML の PI として扱い、PHP open と誤認しない。
final class KSyntaxParserPhp: KSyntaxParser {

    // MARK: - Types

    private enum KEndState: Equatable {
        case html
        case phpNeutral
        case phpBlockComment
        case phpSingleQuote
        case phpDoubleQuote
        case phpBacktick
        case phpHeredoc(label: [UInt8], isNowdoc: Bool)
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .php)
    }

    // MARK: - Override

    override var lineCommentPrefix: String? { "//" }

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            let _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .html) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        if plan.lineDelta != 0 {
            applyLineDelta(lines: &_lines,
                           spliceIndex: plan.spliceIndex,
                           lineDelta: plan.lineDelta) { KLineInfo(endState: .html) }
        }

        let rebuilt = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .html) }
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
        guard !range.isEmpty else { return [] }

        let skeleton = storage.skeletonString
        let lineIndex = skeleton.lineIndex(at: range.lowerBound)
        if lineIndex < 0 || lineIndex >= _lines.count { return [] }

        let lineRange = skeleton.lineRange(at: lineIndex)
        let paintRange = range.clamped(to: lineRange)
        if paintRange.isEmpty { return [] }

        let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .html
        let keywordCatalog = keywords   // [[UInt8]]（loadKeywordsで正規化済み）

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(24)

        @inline(__always)
        func emitSpan(_ tokenRange: Range<Int>, _ role: KFunctionalColor) {
            let clipped = tokenRange.clamped(to: paintRange)
            if clipped.isEmpty { return }
            spans.append(makeSpan(range: clipped, role: role))
        }

        let _ = parseLine(lineRange: lineRange,
                          startState: startState,
                          keywords: keywordCatalog,
                          emit: emitSpan)

        return spans
    }

    override func wordRange(at index: Int) -> Range<Int>? {
        // completion は [A-Za-z_][A-Za-z0-9_]* を前提にする。
        // `$foo` の場合は '$' を除いた foo を返す。
        let skeleton = storage.skeletonString
        let n = skeleton.count
        if n == 0 { return nil }
        if index < 0 || index > n { return nil }

        var p: Int? = nil
        if index < n, skeleton[index].isIdentPartAZ09_ { p = index }
        if p == nil, index > 0, skeleton[index - 1].isIdentPartAZ09_ { p = index - 1 }
        guard let pos = p else { return nil }

        var left = pos
        while left > 0, skeleton[left - 1].isIdentPartAZ09_ { left -= 1 }
        if !skeleton[left].isIdentStartAZ_ { return nil }

        var right = pos + 1
        while right < n, skeleton[right].isIdentPartAZ09_ { right += 1 }

        return left..<right
    }
    
    override func outline(in range: Range<Int>?) -> [KOutlineItem] {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let count = bytes.count
        if count == 0 { return [] }

        let scanRange: Range<Int> = {
            if let r = range {
                let lower = max(0, min(r.lowerBound, count))
                let upper = max(0, min(r.upperBound, count))
                return (lower < upper) ? (lower..<upper) : (0..<0)
            }
            return 0..<count
        }()
        if scanRange.isEmpty { return [] }

        ensureUpToDate(for: scanRange)

        // ローカル関数は最小限
        func lowerAscii(_ b: UInt8) -> UInt8 {
            if b >= 0x41 && b <= 0x5A { return b + 0x20 }
            return b
        }

        func matchWordCI(_ word: [UInt8], at index: Int, end: Int) -> Bool {
            if index + word.count > end { return false }
            if index > scanRange.lowerBound, bytes[index - 1].isIdentPartAZ09_ { return false }
            for i in 0..<word.count {
                if lowerAscii(bytes[index + i]) != word[i] { return false }
            }
            let right = index + word.count
            if right < end, bytes[right].isIdentPartAZ09_ { return false }
            return true
        }

        let wNamespace = Array("namespace".utf8)
        let wClass = Array("class".utf8)
        let wInterface = Array("interface".utf8)
        let wTrait = Array("trait".utf8)
        let wEnum = Array("enum".utf8)
        let wFunction = Array("function".utf8)

        enum Mode { case html, php, lineComment, blockComment, sQuote, dQuote, backtick }
        var mode: Mode = .html
        var braceDepth = 0

        var items: [KOutlineItem] = []
        items.reserveCapacity(128)

        var i = scanRange.lowerBound
        let end = scanRange.upperBound

        while i < end {
            let b = bytes[i]

            switch mode {
            case .html:
                // <?xml は除外（短縮タグ誤認回避）
                if b == FC.lt, i + 1 < end, bytes[i + 1] == FC.question {
                    if i + 4 < end {
                        let b2 = lowerAscii(bytes[i + 2])
                        let b3 = lowerAscii(bytes[i + 3])
                        let b4 = lowerAscii(bytes[i + 4])
                        if b2 == 0x78 && b3 == 0x6D && b4 == 0x6C { // xml
                            i += 2
                            continue
                        }
                    }
                    mode = .php
                    i += 2
                    continue
                }
                i += 1

            case .lineComment:
                if b == FC.lf { mode = .php }
                i += 1

            case .blockComment:
                if b == FC.asterisk, i + 1 < end, bytes[i + 1] == FC.slash {
                    mode = .php
                    i += 2
                    continue
                }
                i += 1

            case .sQuote:
                if b == FC.backSlash { i = min(i + 2, end); continue }
                if b == FC.singleQuote { mode = .php }
                i += 1

            case .dQuote:
                if b == FC.backSlash { i = min(i + 2, end); continue }
                if b == FC.doubleQuote { mode = .php }
                i += 1

            case .backtick:
                if b == FC.backSlash { i = min(i + 2, end); continue }
                if b == FC.backtick { mode = .php }
                i += 1

            case .php:
                // ?> で HTMLへ
                if b == FC.question, i + 1 < end, bytes[i + 1] == FC.gt {
                    mode = .html
                    i += 2
                    continue
                }

                // コメント/文字列（軽量版）
                if b == FC.numeric { mode = .lineComment; i += 1; continue } // '#'
                if b == FC.slash, i + 1 < end {
                    let b1 = bytes[i + 1]
                    if b1 == FC.slash { mode = .lineComment; i += 2; continue }
                    if b1 == FC.asterisk { mode = .blockComment; i += 2; continue }
                }
                if b == FC.singleQuote { mode = .sQuote; i += 1; continue }
                if b == FC.doubleQuote { mode = .dQuote; i += 1; continue }
                if b == FC.backtick { mode = .backtick; i += 1; continue }

                // ネスト概算（neutral 中のみ）
                if b == FC.leftBrace { braceDepth += 1; i += 1; continue }
                if b == FC.rightBrace { braceDepth = max(0, braceDepth - 1); i += 1; continue }

                // キーワード検出
                if b.isIdentStartAZ_ {
                    // namespace Foo\Bar;
                    if matchWordCI(wNamespace, at: i, end: end) {
                        var p = i + wNamespace.count
                        p = skeleton.skipSpaces(from: p, to: end)
                        if p < end, bytes[p] == FC.backSlash { p += 1 }
                        if p < end, bytes[p].isIdentStartAZ_ {
                            var q = p + 1
                            while q < end {
                                let c = bytes[q]
                                if c.isIdentPartAZ09_ { q += 1; continue }
                                if c == FC.backSlash, q + 1 < end, bytes[q + 1].isIdentStartAZ_ { q += 2; continue }
                                break
                            }
                            items.append(KOutlineItem(kind: .module, nameRange: p..<q, level: braceDepth, isSingleton: false))
                        }
                        i += wNamespace.count
                        continue
                    }

                    // class/interface/trait/enum Name
                    let kindWordLen: (KOutlineItem.Kind, Int)? = {
                        if matchWordCI(wClass, at: i, end: end) { return (.class, wClass.count) }
                        if matchWordCI(wInterface, at: i, end: end) { return (.class, wInterface.count) }
                        if matchWordCI(wTrait, at: i, end: end) { return (.class, wTrait.count) }
                        if matchWordCI(wEnum, at: i, end: end) { return (.class, wEnum.count) }
                        return nil
                    }()

                    if let (kind, len) = kindWordLen {
                        var p = i + len
                        p = skeleton.skipSpaces(from: p, to: end)
                        if p < end, bytes[p].isIdentStartAZ_ {
                            var q = p + 1
                            while q < end, bytes[q].isIdentPartAZ09_ { q += 1 }
                            items.append(KOutlineItem(kind: kind, nameRange: p..<q, level: braceDepth, isSingleton: false))
                        }
                        i += len
                        continue
                    }

                    // function name(...) （無名 function(...) は除外）
                    if matchWordCI(wFunction, at: i, end: end) {
                        var p = i + wFunction.count
                        p = skeleton.skipSpaces(from: p, to: end)
                        if p < end, bytes[p] == FC.ampersand {
                            p += 1
                            p = skeleton.skipSpaces(from: p, to: end)
                        }
                        if p < end, bytes[p] == FC.leftParen {
                            i += wFunction.count
                            continue
                        }
                        if p < end, bytes[p].isIdentStartAZ_ {
                            var q = p + 1
                            while q < end, bytes[q].isIdentPartAZ09_ { q += 1 }
                            items.append(KOutlineItem(kind: .method, nameRange: p..<q, level: braceDepth, isSingleton: false))
                        }
                        i += wFunction.count
                        continue
                    }

                    // 識別子を飛ばす
                    var q = i + 1
                    while q < end, bytes[q].isIdentPartAZ09_ { q += 1 }
                    i = q
                    continue
                }

                i += 1
            }
        }

        return items
    }

    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let count = bytes.count
        if count == 0 { return (nil, nil) }

        let pos = max(0, min(index, count))
        if count >= 1 {
            let ensureLower = max(0, min(pos, count - 1))
            ensureUpToDate(for: ensureLower..<(ensureLower + 1))
        }

        let items = outline(in: nil)
        if items.isEmpty { return (nil, nil) }

        func toString(_ r: Range<Int>) -> String {
            if r.isEmpty { return "" }
            return String(decoding: bytes[r], as: UTF8.self)
        }

        var outer: String? = nil
        var inner: String? = nil

        for item in items {
            if item.nameRange.lowerBound > pos { break }
            switch item.kind {
            case .module, .class:
                outer = toString(item.nameRange)
            case .method:
                inner = toString(item.nameRange)
            case .heading:
                break
            }
        }
        if let o = outer, let i = inner {
            return ("\(o) :: ", i)
        }
        return (outer, inner)
    }

    // MARK: - Private (scan)

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        if _lines.isEmpty { return }

        var state: KEndState = (startLine > 0) ? _lines[startLine - 1].endState : .html

        var line = startLine
        while line < _lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let old = _lines[line].endState
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
        // no-op
    }

    // MARK: - Private (lexer)

    /// 1行（LFを含まない）を走査して span 生成＋行末状態を返す
    /// - keywords=nil の場合は keyword 判定を行わない（scan用途）
    private func parseLine(
        lineRange: Range<Int>,
        startState: KEndState,
        keywords: [[UInt8]]?,
        emit: (Range<Int>, KFunctionalColor) -> Void
    ) -> KEndState {

        if lineRange.isEmpty { return startState }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let end = lineRange.upperBound
        var i = lineRange.lowerBound
        var state = startState

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func skipIndent(_ from: Int) -> Int {
            return skeleton.skipSpaces(from: from, to: end)
        }

        @inline(__always)
        func scanToUnescapedQuote(_ quote: UInt8, from start: Int) -> Int? {
            if start >= end { return nil }
            switch skeleton.scan(in: start..<end, targets: [quote], escape: FC.backSlash) {
            case .hit(let index, _):
                return index
            case .notFound:
                return nil
            }
        }

        @inline(__always)
        func scanToBlockCommentEnd(from start: Int) -> Int? {
            return skeleton.firstIndex(ofSequence: [FC.asterisk, FC.slash], in: start..<end)
        }

        @inline(__always)
        func findPhpOpen(from start: Int) -> Int? {
            return skeleton.firstIndex(ofSequence: [FC.lt, FC.question], in: start..<end)
        }

        @inline(__always)
        func isPhpCloseTag(at index: Int) -> Bool {
            if index + 1 >= end { return false }
            return bytes[index] == FC.question && bytes[index + 1] == FC.gt
        }

        @inline(__always)
        func isXmlProcessingInstruction(at openIndex: Int) -> Bool {
            if openIndex + 4 >= end { return false }
            let b2 = bytes[openIndex + 2]
            let b3 = bytes[openIndex + 3]
            let b4 = bytes[openIndex + 4]
            let x = (b2 == 0x78 || b2 == 0x58) // x/X
            let m = (b3 == 0x6D || b3 == 0x4D) // m/M
            let l = (b4 == 0x6C || b4 == 0x4C) // l/L
            return x && m && l
        }

        @inline(__always)
        func scanNumber(from start: Int) -> Int {
            var j = start
            if j >= end { return j }

            func isDigitOrUnderscore(_ b: UInt8) -> Bool {
                return b.isAsciiDigit || b == FC.underscore
            }

            if bytes[j] == 0x30, j + 1 < end { // '0'
                let b1 = bytes[j + 1]
                if b1 == 0x78 || b1 == 0x58 { // x/X
                    j += 2
                    while j < end {
                        let b = bytes[j]
                        if b.isAsciiDigit || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66) || b == FC.underscore {
                            j += 1
                            continue
                        }
                        break
                    }
                    return j
                }
                if b1 == 0x62 || b1 == 0x42 { // b/B
                    j += 2
                    while j < end {
                        let b = bytes[j]
                        if b == 0x30 || b == 0x31 || b == FC.underscore { j += 1; continue }
                        break
                    }
                    return j
                }
                if b1 == 0x6F || b1 == 0x4F { // o/O
                    j += 2
                    while j < end {
                        let b = bytes[j]
                        if (b >= 0x30 && b <= 0x37) || b == FC.underscore { j += 1; continue }
                        break
                    }
                    return j
                }
            }

            while j < end, isDigitOrUnderscore(bytes[j]) { j += 1 }

            if j + 1 < end, bytes[j] == FC.period, bytes[j + 1].isAsciiDigit {
                j += 1
                while j < end, isDigitOrUnderscore(bytes[j]) { j += 1 }
            }

            if j < end {
                let b = bytes[j]
                if b == 0x65 || b == 0x45 { // e/E
                    var k = j + 1
                    if k < end, bytes[k] == FC.plus || bytes[k] == FC.minus { k += 1 }
                    var hasDigit = false
                    while k < end, isDigitOrUnderscore(bytes[k]) { hasDigit = true; k += 1 }
                    if hasDigit { j = k }
                }
            }

            return j
        }

        @inline(__always)
        func scanIdentifier(from start: Int) -> Int {
            var j = start + 1
            while j < end, bytes[j].isIdentPartAZ09_ { j += 1 }
            return j
        }

        while i < end {
            switch state {
            case .html:
                guard let open = findPhpOpen(from: i) else {
                    emit(i..<end, .tag)
                    return .html
                }

                if isXmlProcessingInstruction(at: open) {
                    // "<?" だけ消費して次を探す（XHTML前提でも安全側に寄せる）
                    let next = min(open + 2, end)
                    if next > i { emit(i..<next, .tag) }
                    i = next
                    continue
                }

                if open > i {
                    emit(i..<open, .tag)
                }

                // open tag length
                var openLen = 2 // "<?"
                if open + 2 < end, bytes[open + 2] == FC.equals {
                    openLen = 3 // "<?="
                } else if open + 4 < end {
                    // <?php (case-insensitive)
                    let b2 = bytes[open + 2]
                    let b3 = bytes[open + 3]
                    let b4 = bytes[open + 4]
                    let p = (b2 == 0x70 || b2 == 0x50) // p/P
                    let h = (b3 == 0x68 || b3 == 0x48) // h/H
                    let p2 = (b4 == 0x70 || b4 == 0x50)
                    if p && h && p2 { openLen = 5 }
                }

                let tagEnd = min(open + openLen, end)
                emit(open..<tagEnd, .keyword)
                i = tagEnd
                state = .phpNeutral
                continue

            case .phpBlockComment:
                if let close = scanToBlockCommentEnd(from: i) {
                    let endIndex = min(close + 2, end)
                    emit(i..<endIndex, .comment)
                    i = endIndex
                    state = .phpNeutral
                    continue
                }
                emit(i..<end, .comment)
                return .phpBlockComment

            case .phpSingleQuote:
                if let q = scanToUnescapedQuote(FC.singleQuote, from: i) {
                    let endIndex = min(q + 1, end)
                    emit(i..<endIndex, .string)
                    i = endIndex
                    state = .phpNeutral
                    continue
                }
                emit(i..<end, .string)
                return .phpSingleQuote

            case .phpDoubleQuote:
                if let q = scanToUnescapedQuote(FC.doubleQuote, from: i) {
                    let endIndex = min(q + 1, end)
                    emit(i..<endIndex, .string)
                    i = endIndex
                    state = .phpNeutral
                    continue
                }
                emit(i..<end, .string)
                return .phpDoubleQuote

            case .phpBacktick:
                if let q = scanToUnescapedQuote(FC.backtick, from: i) {
                    let endIndex = min(q + 1, end)
                    emit(i..<endIndex, .string)
                    i = endIndex
                    state = .phpNeutral
                    continue
                }
                emit(i..<end, .string)
                return .phpBacktick

            case .phpHeredoc(let label, _):
                let head = skipIndent(i)
                if head + label.count <= end, skeleton.matchesPrefix(label, at: head) {
                    let after = head + label.count
                    if after == end || bytes[after] == FC.semicolon || isSpaceOrTab(bytes[after]) {
                        emit(i..<after, .string)
                        i = after
                        state = .phpNeutral
                        continue
                    }
                }
                emit(i..<end, .string)
                return state

            case .phpNeutral:
                let b = bytes[i]

                if isPhpCloseTag(at: i) {
                    emit(i..<(i + 2), .keyword)
                    i += 2
                    state = .html
                    continue
                }

                if isSpaceOrTab(b) {
                    i += 1
                    continue
                }

                if b == FC.numeric { // '#'
                    emit(i..<end, .comment)
                    return .phpNeutral
                }

                if b == FC.slash {
                    if i + 1 < end {
                        let b1 = bytes[i + 1]
                        if b1 == FC.slash {
                            emit(i..<end, .comment)
                            return .phpNeutral
                        }
                        if b1 == FC.asterisk {
                            let bodyStart = i + 2
                            if bodyStart < end, let close = scanToBlockCommentEnd(from: bodyStart) {
                                let endIndex = min(close + 2, end)
                                emit(i..<endIndex, .comment)
                                i = endIndex
                                continue
                            }
                            emit(i..<end, .comment)
                            return .phpBlockComment
                        }
                    }
                    i += 1
                    continue
                }

                if b == FC.singleQuote {
                    let start = i
                    let bodyStart = i + 1
                    if let q = scanToUnescapedQuote(FC.singleQuote, from: bodyStart) {
                        let endIndex = min(q + 1, end)
                        emit(start..<endIndex, .string)
                        i = endIndex
                        continue
                    }
                    emit(start..<end, .string)
                    return .phpSingleQuote
                }

                if b == FC.doubleQuote {
                    let start = i
                    let bodyStart = i + 1
                    if let q = scanToUnescapedQuote(FC.doubleQuote, from: bodyStart) {
                        let endIndex = min(q + 1, end)
                        emit(start..<endIndex, .string)
                        i = endIndex
                        continue
                    }
                    emit(start..<end, .string)
                    return .phpDoubleQuote
                }

                if b == FC.backtick {
                    let start = i
                    let bodyStart = i + 1
                    if let q = scanToUnescapedQuote(FC.backtick, from: bodyStart) {
                        let endIndex = min(q + 1, end)
                        emit(start..<endIndex, .string)
                        i = endIndex
                        continue
                    }
                    emit(start..<end, .string)
                    return .phpBacktick
                }

                // heredoc / nowdoc: <<<LABEL / <<<'LABEL' / <<<"LABEL"
                if b == FC.lt, (i + 2) < end, bytes[i + 1] == FC.lt, bytes[i + 2] == FC.lt {
                    var j = i + 3
                    j = skeleton.skipSpaces(from: j, to: end)
                    if j < end {
                        var isNowdoc = false
                        var labelStart = j
                        var labelEnd = j

                        if bytes[j] == FC.singleQuote || bytes[j] == FC.doubleQuote {
                            let q = bytes[j]
                            let bodyStart = j + 1
                            if bodyStart < end, let qpos = skeleton.firstIndex(of: q, in: bodyStart..<end) {
                                labelStart = bodyStart
                                labelEnd = qpos
                                isNowdoc = (q == FC.singleQuote)
                            } else {
                                i += 3
                                continue
                            }
                        } else {
                            if !bytes[j].isIdentStartAZ_ {
                                i += 3
                                continue
                            }
                            labelStart = j
                            j += 1
                            while j < end, bytes[j].isIdentPartAZ09_ { j += 1 }
                            labelEnd = j
                        }

                        if labelEnd > labelStart {
                            let labelBytes = Array(bytes[labelStart..<labelEnd])
                            emit(i..<end, .string)
                            return .phpHeredoc(label: labelBytes, isNowdoc: isNowdoc)
                        }
                    }
                }

                if b == FC.dollar {
                    let start = i
                    var j = i + 1
                    if j < end, bytes[j].isIdentStartAZ_ {
                        j += 1
                        while j < end, bytes[j].isIdentPartAZ09_ { j += 1 }
                        emit(start..<j, .variable)
                        i = j
                        continue
                    }
                    emit(start..<(start + 1), .variable)
                    i += 1
                    continue
                }

                if b.isAsciiDigit {
                    let start = i
                    let j = scanNumber(from: i)
                    if j > start {
                        emit(start..<j, .number)
                        i = j
                        continue
                    }
                }

                if b.isIdentStartAZ_ {
                    let start = i
                    let j = scanIdentifier(from: i)
                    let wordRange = start..<j
                    if let keywords, skeleton.matches(words: keywords, in: wordRange) {
                        emit(wordRange, .keyword)
                    }
                    i = j
                    continue
                }

                i += 1
                continue
            }
        }

        return state
    }
}
