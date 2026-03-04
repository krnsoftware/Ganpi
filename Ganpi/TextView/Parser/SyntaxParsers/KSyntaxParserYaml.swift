//
//  KSyntaxParserYaml.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/03/04,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

/// YAML 向けの軽量カラーリング。
///
/// 方針
/// - フルパースは行わない。
/// - endState はブロックスカラー（| / >）のみ追跡。
/// - それ以外は 1行オンデマンドで判定。
final class KSyntaxParserYaml: KSyntaxParser {

    // MARK: - Types

    private enum KEndState: Equatable {
        case neutral
        case inBlockScalar(baseIndent: Int, contentIndent: Int) // contentIndent: -1 means unknown
    }

    private struct KLineInfo {
        var endState: KEndState
    }

    // MARK: - Properties

    private var _lines: [KLineInfo] = []

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .yaml)
    }

    // MARK: - Override

    override var lineCommentPrefix: String? { "#" }

    override func ensureUpToDate(for range: Range<Int>) {
        if _lines.isEmpty {
            let _ = syncLineBuffer(lines: &_lines) { KLineInfo(endState: .neutral) }
            if _lines.isEmpty { return }
        }

        let plan = consumeRescanPlan(for: range)

        // 行数差分を反映（改行追加/削除）
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

        let _ = parseLine(lineRange: lineRange,
                          startState: startState,
                          emit: emitSpan)

        return spans
    }

    // MARK: - Private

    private func scanFrom(line startLine: Int, minLine: Int) {
        let skeleton = storage.skeletonString
        if _lines.isEmpty { return }

        var state: KEndState = (startLine > 0) ? _lines[startLine - 1].endState : .neutral

        var line = startLine
        while line < _lines.count {
            let lineRange = skeleton.lineRange(at: line)

            let old = _lines[line].endState
            let new = parseLine(lineRange: lineRange,
                                startState: state,
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

    /// 1行（LFを含まない）を走査して span 生成＋行末状態を返す。
    private func parseLine(lineRange: Range<Int>,
                           startState: KEndState,
                           emit: (Range<Int>, KFunctionalColor) -> Void) -> KEndState {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let start = lineRange.lowerBound
        let end = lineRange.upperBound
        if start >= end {
            // 空行（LFのみ）の場合も状態は維持する。
            return startState
        }

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func computeIndent(lineStart: Int) -> (indent: Int, firstNonWS: Int) {
            var col = 0
            var i = lineStart
            while i < end {
                let b = bytes[i]
                if b == FC.space {
                    col += 1
                    i += 1
                    continue
                }
                if b == FC.tab {
                    // YAML はTABインデント非推奨だが、表示上は 4 で近似する。
                    col += 4
                    i += 1
                    continue
                }
                break
            }
            return (indent: col, firstNonWS: i)
        }

        let (indent, firstNonWS) = computeIndent(lineStart: start)

        // ------------------------------------------------------------
        // 1) ブロックスカラー本文（| / >）
        // ------------------------------------------------------------
        if case .inBlockScalar(let baseIndent, let contentIndent0) = startState {
            // 空白だけの行は本文扱い（インデント確定を邪魔しない）
            if firstNonWS >= end {
                emit(lineRange, .string)
                return startState
            }

            let required = (contentIndent0 >= 0) ? contentIndent0 : (baseIndent + 1)

            // contentIndent が確定した後は、そこより浅いインデントで終了。
            if indent < required {
                // ここでブロックスカラー終了。現在行は通常解析へ。
                // fallthrough
            } else {
                let contentIndent = (contentIndent0 >= 0) ? contentIndent0 : indent
                emit(lineRange, .string)
                return .inBlockScalar(baseIndent: baseIndent, contentIndent: contentIndent)
            }
        }

        // ------------------------------------------------------------
        // 2) 通常行の軽量解析
        // ------------------------------------------------------------
        if firstNonWS >= end { return .neutral }

        var state: KEndState = .neutral

        // 先頭トークン解析用
        var head = firstNonWS

        // ドキュメント境界（--- / ...）
        var isDocBoundary = false
        if end - head >= 3 {
            let b0 = bytes[head]
            let b1 = bytes[head + 1]
            let b2 = bytes[head + 2]

            if b0 == FC.minus && b1 == FC.minus && b2 == FC.minus {
                let after = head + 3
                if after == end || isSpaceOrTab(bytes[after]) {
                    emit(head..<after, .tag)
                    isDocBoundary = true
                    head = after
                }
            } else if b0 == FC.period && b1 == FC.period && b2 == FC.period {
                let after = head + 3
                if after == end || isSpaceOrTab(bytes[after]) {
                    emit(head..<after, .tag)
                    isDocBoundary = true
                    head = after
                }
            }
        }

        // リストマーカー（- ）
        var hasListMarker = false
        var valueStartAfterDash: Int? = nil
        if !isDocBoundary {
            if bytes[head] == FC.minus {
                let afterDash = head + 1
                if afterDash == end || isSpaceOrTab(bytes[afterDash]) {
                    emit(head..<afterDash, .keyword)
                    hasListMarker = true
                    valueStartAfterDash = afterDash
                    head = afterDash
                }
            }
        }

        // key 検出の起点
        // - "- key: value" の場合は "-" の後ろから
        // - それ以外は行頭（インデント後）
        var keyStart = firstNonWS
        if hasListMarker, let v = valueStartAfterDash {
            var i = v
            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
            keyStart = i
        }

        // 行内スキャン状態
        var commentStart: Int? = nil
        var keySep: Int? = nil

        var i = firstNonWS
        var inDouble = false
        var inSingle = false
        var quoteStart = 0

        @inline(__always)
        func isEscapedQuote(at index: Int, limit: Int) -> Bool {
            // 直前の '\\' の連続数が奇数ならエスケープ扱い
            if index <= limit { return false }
            var backslashCount = 0
            var j = index - 1
            while j >= limit && bytes[j] == FC.backSlash {
                backslashCount += 1
                if j == 0 { break }
                j -= 1
            }
            return (backslashCount & 1) == 1
        }

        @inline(__always)
        func isYamlNameChar(_ b: UInt8) -> Bool {
            // 軽量版：ASCII の識別子 + "-" "." "/"
            if b.isIdentPartAZ09_ { return true }
            if b == FC.minus || b == FC.period || b == FC.slash { return true }
            return false
        }

        while i < end {
            let b = bytes[i]

            // ------------------------
            // クォート内
            // ------------------------
            if inDouble {
                if b == FC.doubleQuote && !isEscapedQuote(at: i, limit: quoteStart) {
                    emit(quoteStart..<(i + 1), .string)
                    inDouble = false
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            if inSingle {
                if b == FC.singleQuote {
                    // YAML の '' エスケープ（簡易）
                    if i + 1 < end && bytes[i + 1] == FC.singleQuote {
                        i += 2
                        continue
                    }
                    emit(quoteStart..<(i + 1), .string)
                    inSingle = false
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            // ------------------------
            // コメント開始（クォート外）
            // - "http://a#b" を誤爆しやすいので、直前が空白/行頭のときだけコメント扱い
            // ------------------------
            if b == FC.numeric {
                if i == start || isSpaceOrTab(bytes[i - 1]) {
                    commentStart = i
                    break
                }
            }

            // ------------------------
            // クォート開始
            // ------------------------
            if b == FC.doubleQuote {
                quoteStart = i
                inDouble = true
                i += 1
                continue
            }
            if b == FC.singleQuote {
                quoteStart = i
                inSingle = true
                i += 1
                continue
            }

            // ------------------------
            // key separator（最初の ':' だけ）
            // - ':' の直後が空白/行末のときだけ採用（誤爆抑制）
            // ------------------------
            if keySep == nil && !isDocBoundary {
                if i >= keyStart && b == FC.colon {
                    let after = i + 1
                    if after == end || isSpaceOrTab(bytes[after]) {
                        keySep = i
                        // 続行（タグ等も拾う）
                    }
                }
            }

            // ------------------------
            // anchor / alias / tag
            // ------------------------
            if b == FC.ampersand || b == FC.asterisk || b == FC.exclamation {
                let tokenStart = i
                let role: KFunctionalColor = (b == FC.exclamation) ? .tag : .variable

                i += 1
                while i < end {
                    let c = bytes[i]
                    if isSpaceOrTab(c) { break }
                    if c == FC.comma || c == FC.colon || c == FC.rightBracket || c == FC.rightBrace || c == FC.numeric { break }
                    if !isYamlNameChar(c) && c != FC.exclamation { break } // !!str を許す
                    i += 1
                }

                if i > tokenStart + 1 {
                    emit(tokenStart..<i, role)
                    continue
                } else {
                    // 記号単体は無視
                    continue
                }
            }

            i += 1
        }

        // 行末でクォートが閉じなかった場合は行末までを文字列扱い
        // （複数行クォートは追跡しない）
        if inDouble || inSingle {
            emit(quoteStart..<end, .string)
        }

        let scanEnd = commentStart ?? end

        // key span
        if let sep = keySep {
            if keyStart < sep {
                // 先頭がクォートの key は、文字列色に任せて key 色は付けない（重なり事故回避）
                let headByte = bytes[keyStart]
                if headByte != FC.doubleQuote && headByte != FC.singleQuote && headByte != FC.question {
                    var keyEnd = sep
                    while keyEnd > keyStart && isSpaceOrTab(bytes[keyEnd - 1]) { keyEnd -= 1 }
                    if keyStart < keyEnd {
                        emit(keyStart..<keyEnd, .keyword)
                    }
                }
            }
        }

        // ブロックスカラー開始判定（| / >）
        if !isDocBoundary {
            var valueStart: Int? = nil
            if let sep = keySep {
                valueStart = sep + 1
            } else if hasListMarker, let v = valueStartAfterDash {
                valueStart = v
            }

            if let v0 = valueStart {
                var j = v0
                while j < scanEnd && isSpaceOrTab(bytes[j]) { j += 1 }
                if j < scanEnd {
                    let c = bytes[j]
                    if c == FC.pipe || c == FC.gt {
                        // indicator 自体を強調
                        emit(j..<(j + 1), .string)
                        state = .inBlockScalar(baseIndent: indent, contentIndent: -1)
                    }
                }
            }
        }

        // comment span
        if let cs = commentStart {
            emit(cs..<end, .comment)
        }

        return state
    }
}
