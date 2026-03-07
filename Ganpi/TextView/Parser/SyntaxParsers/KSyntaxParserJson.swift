//
//  KSyntaxParserJson.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/03/07,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

/// JSON 向けの軽量シンタックスハイライト。
///
/// 方針
/// - フルパースは行わない。
/// - 文字列（\"...\"）だけは endState として追跡し、行を跨いだ未閉鎖状態でも表示が破綻しないようにする。
/// - キー（\"key\":）は .variable、値の文字列は .string。
/// - 数値は .number、キーワード（true/false/null）は .keyword。
///
/// 注意
/// - JSON は本来 multi-line string を許容しないが、編集途中の未閉鎖を考慮して行を跨いで追跡する。
final class KSyntaxParserJson: KSyntaxParser {

    // MARK: - Types

    private enum KEndState: Equatable {
        case neutral
        case inString
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    private enum KContainerKind {
        case object
        case array
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    private let _maxBackCharsForContext: Int = 200_000
    private let _maxScanCharsForStringBounds: Int = 200_000
    private let _maxOutlineItems: Int = 5_000

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .json)
    }

    // MARK: - Override

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            let _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        // 行数差分（改行追加/削除）を反映
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
        ensureUpToDate(for: range)
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let lineIndex = skeleton.lineIndex(at: range.lowerBound)
        if lineIndex < 0 || lineIndex >= _lines.count { return [] }

        let lineRange = skeleton.lineRange(at: lineIndex)
        let paintRange = range.clamped(to: lineRange)
        if paintRange.isEmpty { return [] }

        let startState: KEndState = (lineIndex > 0) ? _lines[lineIndex - 1].endState : .neutral

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(16)

        @inline(__always)
        func emitSpan(_ tokenRange: Range<Int>, role: KFunctionalColor) {
            let clipped = tokenRange.clamped(to: paintRange)
            if clipped.isEmpty { return }
            spans.append(makeSpan(range: clipped, role: role))
        }

        let _ = parseLine(lineRange: lineRange, startState: startState, emit: emitSpan)

        return spans
    }

    override func wordRange(at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count

        if index < 0 || index > n { return nil }
        if n == 0 { return nil }

        // caret は「文字と文字の間」なので、基本は直前を優先する
        var pos = index
        if pos == n { pos = n - 1 }
        if pos > 0 {
            // index が単語境界のことが多いので、直前を優先
            let b = bytes[pos]
            if !(b.isIdentPartAZ09_ || b.isAsciiDigit || b == FC.minus || b == FC.doubleQuote) {
                pos = pos - 1
            }
        }
        if pos < 0 || pos >= n { return nil }

        // 文字列判定は行 state に依存するため、最低限 caret 付近を up-to-date にする
        ensureUpToDate(for: pos..<(min(pos + 1, n)))

        // 1) 文字列内なら（"..." の中）を返す
        if let bounds = findStringBounds(containing: pos) {
            let content = (bounds.startQuote + 1)..<bounds.endQuote
            if !content.isEmpty { return content }
            // 空文字列は nil（選択が増えないため）
            return nil
        }

        // 2) keyword / identifier
        if let r = asciiIdentifierRange(bytes: bytes, at: pos) {
            return r
        }

        // 3) number
        if let r = numberRange(bytes: bytes, at: pos) {
            return r
        }

        return nil
    }

    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return (nil, nil) }

        let clamped = max(0, min(index, n))
        let safePos: Int = {
            if clamped == 0 { return 0 }
            if clamped >= n { return max(0, n - 1) }
            return max(0, clamped - 1)
        }()

        // endState を使うため、少なくとも caret 付近を up-to-date にする
        if n > 0 {
            ensureUpToDate(for: safePos..<(min(safePos + 1, n)))
        }

        // 1) caret が「キー文字列」内にある場合を優先
        if let str = findStringBounds(containing: safePos) {
            if isKeyString(endingQuoteAt: str.endQuote) {
                let keyRange = (str.startQuote + 1)..<str.endQuote
                let parentKeyRange = findParentKeyRange(forContainerStart: findEnclosingContainerStart(before: str.startQuote, preferred: .object)?.index)

                let keyText = storage.string(in: keyRange)
                if let parentKeyRange {
                    let parentText = storage.string(in: parentKeyRange)
                    return (outer: parentText, inner: "." + keyText)
                }
                return (outer: keyText, inner: nil)
            }
        }

        // 2) 値側にいる場合：直近の "key": を探す
        if let hit = findNearestKeyForValue(before: safePos) {
            let keyText = storage.string(in: hit.keyRange)
            let parentKeyRange = findParentKeyRange(forContainerStart: hit.containerStart)

            if let parentKeyRange {
                let parentText = storage.string(in: parentKeyRange)
                return (outer: parentText, inner: "." + keyText)
            }
            return (outer: keyText, inner: nil)
        }

        // 3) それでも見つからない場合：所属コンテナ（object/array）が key の値ならそれを返す
        if let container = findEnclosingContainerStart(before: safePos, preferred: nil) {
            if let parentKeyRange = findParentKeyRange(forContainerStart: container.index) {
                let parentText = storage.string(in: parentKeyRange)
                return (outer: parentText, inner: nil)
            }
        }

        return (nil, nil)
    }

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return [] }

        let target: Range<Int> = {
            if let r = range {
                let lower = max(0, min(r.lowerBound, n))
                let upper = max(0, min(r.upperBound, n))
                if lower >= upper { return 0..<0 }
                return lower..<upper
            }
            return 0..<n
        }()
        if target.isEmpty { return [] }

        var items: [KOutlineItem] = []
        items.reserveCapacity(min(256, _maxOutlineItems))

        // JSON 全体を一度走査して、object の key だけを拾う。
        // - root が array の場合も、array 内の object key は拾う（ユーティリティ目的）。

        struct ContainerState {
            var kind: KContainerKind
            var expectKey: Bool
        }

        var stack: [ContainerState] = []
        stack.reserveCapacity(64)

        var objectDepth = 0

        var inString = false
        var isEscaped = false
        var stringStart = 0
        var stringIsCandidateKey = false

        @inline(__always)
        func isWhitespace(_ b: UInt8) -> Bool {
            b == FC.space || b == FC.tab || b == FC.lf || b == FC.cr
        }

        @inline(__always)
        func objectLevel() -> Int {
            // root object の key を level 0 に揃える
            return max(0, objectDepth - 1)
        }

        var i = target.lowerBound
        let end = target.upperBound

        while i < end {
            let b = bytes[i]

            if inString {
                if isEscaped {
                    isEscaped = false
                    i += 1
                    continue
                }
                if b == FC.backSlash {
                    isEscaped = true
                    i += 1
                    continue
                }
                if b == FC.doubleQuote {
                    inString = false

                    if stringIsCandidateKey {
                        // "key" の直後の ':' を探す（空白/改行は許容）
                        var p = i + 1
                        while p < end, isWhitespace(bytes[p]) { p += 1 }
                        if p < end, bytes[p] == FC.colon {
                            // outline に追加（nameRange は引用符を含めない）
                            let nameRange = (stringStart + 1)..<i
                            items.append(KOutlineItem(kind: .module,
                                                      nameRange: nameRange,
                                                      level: objectLevel(),
                                                      isSingleton: false))
                            if items.count >= _maxOutlineItems { break }

                            // object は次は value を期待
                            if !stack.isEmpty, stack[stack.count - 1].kind == .object {
                                stack[stack.count - 1].expectKey = false
                            }
                        }
                    }

                    stringIsCandidateKey = false
                    i += 1
                    continue
                }

                i += 1
                continue
            }

            // not in string
            if b == FC.doubleQuote {
                inString = true
                isEscaped = false
                stringStart = i

                if let top = stack.last, top.kind == .object, top.expectKey {
                    stringIsCandidateKey = true
                } else {
                    stringIsCandidateKey = false
                }

                i += 1
                continue
            }

            switch b {
            case FC.leftBrace:
                stack.append(ContainerState(kind: .object, expectKey: true))
                objectDepth += 1

            case FC.rightBrace:
                if let last = stack.last, last.kind == .object {
                    stack.removeLast()
                    objectDepth = max(0, objectDepth - 1)
                } else {
                    // 壊れた入力：後方に object があればそこまで縮める
                    if let idx = stack.lastIndex(where: { $0.kind == .object }) {
                        stack.removeSubrange(idx..<stack.count)
                        objectDepth = max(0, objectDepth - 1)
                    }
                }

            case FC.leftBracket:
                stack.append(ContainerState(kind: .array, expectKey: false))

            case FC.rightBracket:
                if let last = stack.last, last.kind == .array {
                    stack.removeLast()
                } else {
                    if let idx = stack.lastIndex(where: { $0.kind == .array }) {
                        stack.removeSubrange(idx..<stack.count)
                    }
                }

            case FC.comma:
                // object の場合は次の key
                if !stack.isEmpty, stack[stack.count - 1].kind == .object {
                    stack[stack.count - 1].expectKey = true
                }

            default:
                break
            }

            i += 1
        }

        return items
    }

    // MARK: - Line scan

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        var state: KEndState = (startLine > 0) ? _lines[startLine - 1].endState : .neutral

        for line in startLine..<_lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let oldEnd = _lines[line].endState
            let newEnd = scanOneLine(lineRange: lineRange, startState: state)

            _lines[line].endState = newEnd
            state = newEnd

            // 連鎖が止まっても、minLine までは必ず走査する
            if oldEnd == newEnd && line >= minLine {
                break
            }
        }
    }

    private func scanOneLine(lineRange: Range<Int>, startState: KEndState) -> KEndState {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        if lineRange.isEmpty { return startState }

        var inString = (startState == .inString)
        var isEscaped = false

        var i = lineRange.lowerBound
        let end = lineRange.upperBound

        while i < end {
            let b = bytes[i]

            if inString {
                if isEscaped {
                    isEscaped = false
                    i += 1
                    continue
                }
                if b == FC.backSlash {
                    isEscaped = true
                    i += 1
                    continue
                }
                if b == FC.doubleQuote {
                    inString = false
                    i += 1
                    continue
                }

                i += 1
                continue
            }

            if b == FC.doubleQuote {
                inString = true
                isEscaped = false
                i += 1
                continue
            }

            i += 1
        }

        return inString ? .inString : .neutral
    }

    // MARK: - Parse (per line)

    @discardableResult
    private func parseLine(lineRange: Range<Int>,
                           startState: KEndState,
                           emit: (Range<Int>, KFunctionalColor) -> Void) -> KEndState {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count

        if lineRange.isEmpty { return startState }

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func isWhitespace(_ b: UInt8) -> Bool {
            b == FC.space || b == FC.tab || b == FC.lf || b == FC.cr
        }

        @inline(__always)
        func isNumberPart(_ b: UInt8) -> Bool {
            b.isAsciiDigit || b == FC.period || b == FC.minus || b == FC.plus || b == 0x65 || b == 0x45 // e/E
        }

        @inline(__always)
        func isKeywordToken(_ start: Int, _ end: Int) -> Bool {
            let len = end - start
            if len <= 0 { return false }
            for kw in keywords {
                if kw.count != len { continue }
                var ok = true
                var k = 0
                while k < len {
                    if bytes[start + k] != kw[k] { ok = false; break }
                    k += 1
                }
                if ok { return true }
            }
            return false
        }

        @inline(__always)
        func keyRoleForString(endingQuoteAt endQuote: Int) -> KFunctionalColor {
            // "..." の直後に ':' が来るなら key
            // - 見た目優先：少し先（空白/改行）だけ見る
            var p = endQuote + 1
            let limit = min(n, p + 64)
            while p < limit {
                let b = bytes[p]
                if isWhitespace(b) {
                    p += 1
                    continue
                }
                return (b == FC.colon) ? .variable : .string
            }
            return .string
        }

        var i = lineRange.lowerBound
        let end = lineRange.upperBound

        var inString = (startState == .inString)
        var isEscaped = false
        var stringStart = i

        while i < end {
            let b = bytes[i]

            if inString {
                if isEscaped {
                    isEscaped = false
                    i += 1
                    continue
                }
                if b == FC.backSlash {
                    isEscaped = true
                    i += 1
                    continue
                }
                if b == FC.doubleQuote {
                    // 文字列終端（閉じ）
                    emit(stringStart..<(i + 1), .string)
                    inString = false
                    i += 1
                    continue
                }

                i += 1
                continue
            }

            // ---- string
            if b == FC.doubleQuote {
                stringStart = i
                var j = i + 1
                var esc = false

                while j < end {
                    let bj = bytes[j]
                    if esc {
                        esc = false
                        j += 1
                        continue
                    }
                    if bj == FC.backSlash {
                        esc = true
                        j += 1
                        continue
                    }
                    if bj == FC.doubleQuote {
                        let role = keyRoleForString(endingQuoteAt: j)
                        emit(i..<(j + 1), role)
                        i = j + 1
                        break
                    }
                    j += 1
                }

                if j >= end {
                    // 未閉鎖：行末まで string 扱い
                    emit(i..<end, .string)
                    return .inString
                }

                continue
            }

            // ---- number
            if b.isAsciiDigit || (b == FC.minus && (i + 1) < end && bytes[i + 1].isAsciiDigit) {
                let start = i
                var j = i + 1
                while j < end {
                    let bj = bytes[j]
                    if !isNumberPart(bj) { break }
                    j += 1
                }
                emit(start..<j, .number)
                i = j
                continue
            }

            // ---- keyword (true/false/null)
            if b.isIdentStartAZ_ {
                let start = i
                var j = i + 1
                while j < end {
                    let bj = bytes[j]
                    if !bj.isIdentPartAZ09_ { break }
                    j += 1
                }
                if isKeywordToken(start, j) {
                    emit(start..<j, .keyword)
                }
                i = j
                continue
            }

            // skip
            if isSpaceOrTab(b) {
                i += 1
                continue
            }

            i += 1
        }

        if inString {
            // 未閉鎖（編集途中など）：行末まで string 扱い
            emit(stringStart..<end, .string)
            return .inString
        }

        return .neutral
    }

    // MARK: - Context helpers

    private func findNearestKeyForValue(before index: Int) -> (keyRange: Range<Int>, containerStart: Int)? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }

        let startPos = max(0, min(index, n - 1))

        // 現在位置が文字列中か（line state ベース）
        let initialInString = isInString(at: startPos)

        var inString = initialInString
        var braceNeed = 0
        var bracketNeed = 0

        var scanned = 0
        var i = startPos

        while i >= 0 && scanned < _maxBackCharsForContext {
            let b = bytes[i]

            if b == FC.doubleQuote {
                if !isEscapedQuote(at: i, bytes: bytes) {
                    inString.toggle()
                }
                i -= 1
                scanned += 1
                continue
            }

            if inString {
                i -= 1
                scanned += 1
                continue
            }

            switch b {
            case FC.rightBrace:
                braceNeed += 1
            case FC.leftBrace:
                if braceNeed > 0 { braceNeed -= 1 }
            case FC.rightBracket:
                bracketNeed += 1
            case FC.leftBracket:
                if bracketNeed > 0 { bracketNeed -= 1 }
            case FC.colon:
                if braceNeed == 0 && bracketNeed == 0 {
                    // key は直前の "..." を想定（空白/改行は許容）
                    var p = i - 1
                    while p >= 0 {
                        let bp = bytes[p]
                        if bp == FC.space || bp == FC.tab || bp == FC.lf || bp == FC.cr { p -= 1; continue }
                        break
                    }

                    if p >= 0, bytes[p] == FC.doubleQuote, !isEscapedQuote(at: p, bytes: bytes) {
                        let endQuote = p
                        if let startQuote = findMatchingQuoteStart(endingAt: endQuote, bytes: bytes) {
                            let keyRange = (startQuote + 1)..<endQuote
                            if let objStart = findEnclosingContainerStart(before: startQuote, preferred: .object)?.index {
                                return (keyRange: keyRange, containerStart: objStart)
                            }
                            return (keyRange: keyRange, containerStart: -1)
                        }
                    }
                }
            default:
                break
            }

            i -= 1
            scanned += 1
        }

        return nil
    }

    private func findParentKeyRange(forContainerStart containerStart: Int?) -> Range<Int>? {
        guard let containerStart, containerStart >= 0 else { return nil }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }

        var p = containerStart - 1
        if p < 0 { return nil }

        // "parent" : { ... }
        while p >= 0 {
            let b = bytes[p]
            if b == FC.space || b == FC.tab || b == FC.lf || b == FC.cr { p -= 1; continue }
            break
        }
        if p < 0 || bytes[p] != FC.colon { return nil }

        p -= 1
        while p >= 0 {
            let b = bytes[p]
            if b == FC.space || b == FC.tab || b == FC.lf || b == FC.cr { p -= 1; continue }
            break
        }
        if p < 0 || bytes[p] != FC.doubleQuote { return nil }
        if isEscapedQuote(at: p, bytes: bytes) { return nil }

        let endQuote = p
        guard let startQuote = findMatchingQuoteStart(endingAt: endQuote, bytes: bytes) else { return nil }
        return (startQuote + 1)..<endQuote
    }

    private func isKeyString(endingQuoteAt endQuote: Int) -> Bool {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if endQuote < 0 || endQuote >= n { return false }

        var p = endQuote + 1
        let limit = min(n, p + 256)

        while p < limit {
            let b = bytes[p]
            if b == FC.space || b == FC.tab || b == FC.lf || b == FC.cr {
                p += 1
                continue
            }
            return b == FC.colon
        }
        return false
    }

    private func findStringBounds(containing index: Int) -> (startQuote: Int, endQuote: Int)? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }
        if index < 0 || index >= n { return nil }

        // まず「今が文字列内か」を line-state で判定
        if !isInString(at: index) { return nil }

        // startQuote
        var scanned = 0
        var i = index
        while i >= 0 && scanned < _maxScanCharsForStringBounds {
            if bytes[i] == FC.doubleQuote, !isEscapedQuote(at: i, bytes: bytes) {
                break
            }
            i -= 1
            scanned += 1
        }
        if i < 0 || bytes[i] != FC.doubleQuote { return nil }
        let startQuote = i

        // endQuote
        var j = index
        scanned = 0
        var isEscaped = false

        // 文字列内部から開始なので、開始直後に quote が来るケースにも対応
        while j < n && scanned < _maxScanCharsForStringBounds {
            let b = bytes[j]

            if j == startQuote {
                // 開始 quote 自身は飛ばす
                j += 1
                scanned += 1
                continue
            }

            if isEscaped {
                isEscaped = false
                j += 1
                scanned += 1
                continue
            }

            if b == FC.backSlash {
                isEscaped = true
                j += 1
                scanned += 1
                continue
            }

            if b == FC.doubleQuote {
                // end
                return (startQuote: startQuote, endQuote: j)
            }

            j += 1
            scanned += 1
        }

        return nil
    }

    private func findEnclosingContainerStart(before index: Int, preferred: KContainerKind?) -> (kind: KContainerKind, index: Int)? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }

        let startPos = max(0, min(index, n - 1))

        var inString = isInString(at: startPos)
        var braceNeed = 0
        var bracketNeed = 0

        var scanned = 0
        var i = startPos

        while i >= 0 && scanned < _maxBackCharsForContext {
            let b = bytes[i]

            if b == FC.doubleQuote {
                if !isEscapedQuote(at: i, bytes: bytes) {
                    inString.toggle()
                }
                i -= 1
                scanned += 1
                continue
            }

            if inString {
                i -= 1
                scanned += 1
                continue
            }

            switch b {
            case FC.rightBrace:
                braceNeed += 1
            case FC.leftBrace:
                if braceNeed > 0 {
                    braceNeed -= 1
                } else {
                    // object start
                    if preferred == nil || preferred == .object {
                        return (kind: .object, index: i)
                    }
                }
            case FC.rightBracket:
                bracketNeed += 1
            case FC.leftBracket:
                if bracketNeed > 0 {
                    bracketNeed -= 1
                } else {
                    if preferred == nil || preferred == .array {
                        return (kind: .array, index: i)
                    }
                }
            default:
                break
            }

            i -= 1
            scanned += 1
        }

        return nil
    }

    private func isInString(at index: Int) -> Bool {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return false }
        if index < 0 || index >= n { return false }

        let line = skeleton.lineIndex(at: index)
        if line < 0 { return false }

        // endState を使う
        let startState: KEndState = {
            if line == 0 { return .neutral }
            let prev = line - 1
            if prev >= 0 && prev < _lines.count {
                return _lines[prev].endState
            }
            return .neutral
        }()

        let lr = skeleton.lineRange(at: line)
        if lr.isEmpty { return startState == .inString }

        var inString = (startState == .inString)
        var isEscaped = false

        var i = lr.lowerBound
        let end = min(lr.upperBound, index + 1)

        while i < end {
            let b = bytes[i]

            if inString {
                if isEscaped {
                    isEscaped = false
                    i += 1
                    continue
                }
                if b == FC.backSlash {
                    isEscaped = true
                    i += 1
                    continue
                }
                if b == FC.doubleQuote {
                    inString = false
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            if b == FC.doubleQuote {
                inString = true
                isEscaped = false
                i += 1
                continue
            }

            i += 1
        }

        return inString
    }

    // MARK: - Low-level helpers

    @inline(__always)
    private func isEscapedQuote(at quoteIndex: Int, bytes: [UInt8]) -> Bool {
        if quoteIndex <= 0 { return false }

        var count = 0
        var i = quoteIndex - 1
        while i >= 0 {
            if bytes[i] != FC.backSlash { break }
            count += 1
            if i == 0 { break }
            i -= 1
        }
        return (count & 1) == 1
    }

    private func findMatchingQuoteStart(endingAt endQuote: Int, bytes: [UInt8]) -> Int? {
        if endQuote <= 0 { return nil }

        var i = endQuote - 1
        while i >= 0 {
            if bytes[i] == FC.doubleQuote, !isEscapedQuote(at: i, bytes: bytes) {
                return i
            }
            if i == 0 { break }
            i -= 1
        }
        return nil
    }

    private func asciiIdentifierRange(bytes: [UInt8], at index: Int) -> Range<Int>? {
        let n = bytes.count
        if n == 0 { return nil }
        if index < 0 || index >= n { return nil }

        // index または index-1 が識別子に触れているか
        var p: Int? = nil

        if bytes[index].isIdentPartAZ09_ {
            p = index
        } else if index > 0, bytes[index - 1].isIdentPartAZ09_ {
            p = index - 1
        }

        guard let pos = p else { return nil }

        var left = pos
        while left > 0 {
            let b = bytes[left - 1]
            if !b.isIdentPartAZ09_ { break }
            left -= 1
        }

        if !bytes[left].isIdentStartAZ_ { return nil }

        var right = pos + 1
        while right < n {
            let b = bytes[right]
            if !b.isIdentPartAZ09_ { break }
            right += 1
        }

        return left..<right
    }

    private func numberRange(bytes: [UInt8], at index: Int) -> Range<Int>? {
        let n = bytes.count
        if n == 0 { return nil }
        if index < 0 || index >= n { return nil }

        @inline(__always)
        func isNumberPart(_ b: UInt8) -> Bool {
            b.isAsciiDigit || b == FC.period || b == FC.minus || b == FC.plus || b == 0x65 || b == 0x45 // e/E
        }

        let b0 = bytes[index]
        if !(b0.isAsciiDigit || b0 == FC.minus || b0 == FC.period) {
            if index > 0 {
                let b1 = bytes[index - 1]
                if !(b1.isAsciiDigit || b1 == FC.minus || b1 == FC.period) { return nil }
            } else {
                return nil
            }
        }

        var left = index
        while left > 0, isNumberPart(bytes[left - 1]) { left -= 1 }

        var right = index + 1
        while right < n, isNumberPart(bytes[right]) { right += 1 }

        // 少なくとも数字を含む
        var hasDigit = false
        var i = left
        while i < right {
            if bytes[i].isAsciiDigit { hasDigit = true; break }
            i += 1
        }
        if !hasDigit { return nil }

        return left..<right
    }
}
