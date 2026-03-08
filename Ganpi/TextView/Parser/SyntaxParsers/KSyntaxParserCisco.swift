//
//  KSyntaxParserCisco.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/03/08,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
//
//  Cisco IOS / IOS XE running-config syntax coloring.
//

import AppKit

/// Cisco IOS / IOS XE (running-config) 向けの軽量カラーリング。
///
/// 方針
/// - フルパースは行わない。
/// - インデントは構造情報としては使わない（見た目の補助に過ぎないため）。
/// - 行頭の構造コマンド（interface/router/line/...）と、否定形 no を見やすくする。
/// - banner は delimiter で囲まれる複数行文字列として特別扱いする。
final class KSyntaxParserCisco: KSyntaxParser {

    // MARK: - Properties

    // ---- Detect / outline 用トークン
    private let _tokenInterface: [UInt8] = Array("interface".utf8)
    private let _tokenRouter: [UInt8] = Array("router".utf8)
    private let _tokenLine: [UInt8] = Array("line".utf8)
    private let _tokenIp: [UInt8] = Array("ip".utf8)
    private let _tokenAccessList: [UInt8] = Array("access-list".utf8)
    private let _tokenRouteMap: [UInt8] = Array("route-map".utf8)
    private let _tokenPolicyMap: [UInt8] = Array("policy-map".utf8)
    private let _tokenClassMap: [UInt8] = Array("class-map".utf8)
    private let _tokenBanner: [UInt8] = Array("banner".utf8)
    private let _tokenNo: [UInt8] = Array("no".utf8)

    // banner の探索で遡る最大行数（巨大ファイルでも軽快さを優先）
    private let _bannerLookbackMaxLines: Int = 200

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .cisco)
    }

    // MARK: - Overrides

    override class func detectScore(content: String) -> Int? {
        if content.isEmpty { return nil }

        let maxLines = 250

        func hasPrefix(_ tokens: [String], _ expected: [String]) -> Bool {
            if tokens.count < expected.count { return false }
            for i in expected.indices {
                if tokens[i] != expected[i] { return false }
            }
            return true
        }

        var score = 0
        var strong = 0
        var medium = 0
        var checked = 0

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if checked >= maxLines { break }
            checked += 1

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("!") { continue }

            let tokens = line.split { $0 == " " || $0 == "\t" }.map { $0.lowercased() }
            if tokens.isEmpty { continue }

            if hasPrefix(tokens, ["line", "vty"]) {
                score += 45
                strong += 1
                continue
            }

            if hasPrefix(tokens, ["enable", "secret"]) {
                score += 45
                strong += 1
                continue
            }

            if hasPrefix(tokens, ["ip", "access-list"]) {
                score += 45
                strong += 1
                continue
            }

            if hasPrefix(tokens, ["banner", "motd"]) {
                score += 45
                strong += 1
                continue
            }

            if hasPrefix(tokens, ["router", "ospf"]) || hasPrefix(tokens, ["router", "bgp"]) {
                score += 40
                strong += 1
                continue
            }

            if hasPrefix(tokens, ["interface"]) {
                score += 35
                strong += 1
                continue
            }

            if hasPrefix(tokens, ["route-map"]) || hasPrefix(tokens, ["policy-map"]) || hasPrefix(tokens, ["class-map"]) {
                score += 28
                medium += 1
                continue
            }

            if hasPrefix(tokens, ["hostname"]) {
                score += 18
                medium += 1
                continue
            }

            if hasPrefix(tokens, ["service", "password-encryption"]) {
                score += 18
                medium += 1
                continue
            }

            if hasPrefix(tokens, ["no", "shutdown"]) {
                score += 12
                medium += 1
                continue
            }
        }

        // それらしい行が少ない場合は確信できない
        if strong >= 2 { return score }
        if strong >= 1, medium >= 2 { return score }
        if medium >= 5 { return score }

        return nil
    }

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let lineRange = skeleton.lineRange(contains: range)
        if lineRange.isEmpty { return [] }

        @inline(__always)
        func emit(_ r: Range<Int>, _ role: KFunctionalColor, _ out: inout [KAttributedSpan]) {
            let clipped = r.clamped(to: range)
            if clipped.isEmpty { return }
            out.append(makeSpan(range: clipped, role: role))
        }

        // ---- 1) banner 範囲を先に抽出（複数行）
        let bannerRanges = findBannerRanges(covering: lineRange)

        // ---- 2) 行ごとの軽量着色
        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(32)

        let startLine = skeleton.lineIndex(at: lineRange.lowerBound)
        let endLine = skeleton.lineIndex(at: max(lineRange.upperBound - 1, lineRange.lowerBound))

        for line in startLine...endLine {
            let lr = skeleton.lineRange(at: line)
            if lr.isEmpty { continue }

            // banner 内部は string として扱う
            for br in bannerRanges {
                let inter = lr.clamped(to: br)
                if !inter.isEmpty {
                    emit(inter, .string, &spans)
                }
            }

            // banner 内の行はそれ以上の解析をしない（banner の方が優先）
            if bannerRanges.contains(where: { !$0.clamped(to: lr).isEmpty }) {
                continue
            }

            // 行頭空白をスキップ
            let head = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
            if head >= lr.upperBound { continue }

            // 行頭コメント（!）
            if bytes[head] == FC.exclamation {
                emit(lr, .comment, &spans)
                continue
            }

            // ---- クォート文字列
            let stringRanges = findQuotedStrings(in: head..<lr.upperBound)
            for sr in stringRanges {
                emit(sr, .string, &spans)
            }

            // ---- 行頭キーワード / no
            let headTokens = scanTokens(in: head..<lr.upperBound, stringRanges: stringRanges)
            if let first = headTokens.first {
                // 行頭 no
                if tokenEquals(bytes, first, _tokenNo) {
                    emit(first, .keyword, &spans)
                } else {
                    // 構造語は先頭トークンだけ強調（ip access-list は 2トークン目まで）
                    if tokenEquals(bytes, first, _tokenIp) {
                        if headTokens.count >= 2 {
                            let second = headTokens[1]
                            if tokenEquals(bytes, second, _tokenAccessList) {
                                emit(first.lowerBound..<second.upperBound, .keyword, &spans)
                            } else {
                                emit(first, .keyword, &spans)
                            }
                        } else {
                            emit(first, .keyword, &spans)
                        }
                    } else if tokenEquals(bytes, first, _tokenInterface)
                                || tokenEquals(bytes, first, _tokenRouter)
                                || tokenEquals(bytes, first, _tokenLine)
                                || tokenEquals(bytes, first, _tokenRouteMap)
                                || tokenEquals(bytes, first, _tokenPolicyMap)
                                || tokenEquals(bytes, first, _tokenClassMap)
                                || tokenEquals(bytes, first, _tokenBanner) {
                        emit(first, .keyword, &spans)
                    }
                }
            }

            // ---- 数値 / IP 系
            for tr in headTokens {
                if isNumericToken(bytes: bytes, range: tr) {
                    emit(tr, .number, &spans)
                }
            }
        }

        return spans
    }

    override func wordRange(at index: Int) -> Range<Int>? {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return nil }
        if index < 0 || index > n { return nil }

        @inline(__always)
        func isWordByte(_ b: UInt8) -> Bool {
            if b.isAsciiAlpha || b.isAsciiDigit { return true }
            if b == FC.underscore { return true }
            if b == FC.minus { return true }
            if b == FC.period { return true }
            if b == FC.slash { return true }
            if b == FC.colon { return true }
            return false
        }

        var p: Int? = nil
        if index < n, isWordByte(bytes[index]) {
            p = index
        } else if index > 0, isWordByte(bytes[index - 1]) {
            p = index - 1
        }
        guard let pos = p else { return nil }

        var start = pos
        while start > 0, isWordByte(bytes[start - 1]) {
            start -= 1
        }

        var end = pos + 1
        while end < n, isWordByte(bytes[end]) {
            end += 1
        }

        if start >= end { return nil }
        return start..<end
    }

    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return (nil, nil) }

        let clamped = max(0, min(index, n))
        let lineIndex = skeleton.lineIndex(at: clamped)
        let lineRange = skeleton.lineRange(at: lineIndex)

        func trimmedLineString(_ r: Range<Int>) -> String {
            let s = storage.string(in: r)
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // inner: 現在行（コメント/空行は除外）
        var inner: String? = nil
        do {
            let head = skeleton.skipSpaces(from: lineRange.lowerBound, to: lineRange.upperBound)
            if head < lineRange.upperBound, bytes[head] != FC.exclamation {
                let t = trimmedLineString(lineRange)
                if !t.isEmpty { inner = t }
            }
        }

        // outer: 近傍のブロック開始行を後方探索
        var outer: String? = nil
        var l = lineIndex
        while l >= 0 {
            let r = skeleton.lineRange(at: l)
            if r.isEmpty { l -= 1; continue }

            let head = skeleton.skipSpaces(from: r.lowerBound, to: r.upperBound)
            if head >= r.upperBound { l -= 1; continue }
            if bytes[head] == FC.exclamation { l -= 1; continue }

            let tokens = scanTokens(in: head..<r.upperBound, stringRanges: [])
            if tokens.isEmpty { l -= 1; continue }

            if tokenEquals(bytes, tokens[0], _tokenInterface)
                || tokenEquals(bytes, tokens[0], _tokenRouter)
                || tokenEquals(bytes, tokens[0], _tokenLine)
                || tokenEquals(bytes, tokens[0], _tokenRouteMap)
                || tokenEquals(bytes, tokens[0], _tokenPolicyMap)
                || tokenEquals(bytes, tokens[0], _tokenClassMap) {
                outer = trimmedLineString(r)
                break
            }

            if tokenEquals(bytes, tokens[0], _tokenIp), tokens.count >= 2 {
                if tokenEquals(bytes, tokens[1], _tokenAccessList) {
                    outer = trimmedLineString(r)
                    break
                }
            }

            l -= 1
        }

        if outer == inner { inner = nil }
        return (outer, inner)
    }

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let lineCount = skeletonLineCount()
        if lineCount <= 0 { return [] }

        let startLine: Int
        let endLine: Int
        if let r = range {
            let a = max(0, min(r.lowerBound, bytes.count))
            let b = max(0, min(max(r.upperBound - 1, r.lowerBound), bytes.count))
            startLine = skeleton.lineIndex(at: a)
            endLine = skeleton.lineIndex(at: b)
        } else {
            startLine = 0
            endLine = lineCount - 1
        }

        var items: [KOutlineItem] = []
        items.reserveCapacity(64)

        for line in startLine...endLine {
            let lr = skeleton.lineRange(at: line)
            if lr.isEmpty { continue }

            let head = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
            if head >= lr.upperBound { continue }
            if bytes[head] == FC.exclamation { continue }

            let tokens = scanTokens(in: head..<lr.upperBound, stringRanges: [])
            if tokens.isEmpty { continue }

            if tokenEquals(bytes, tokens[0], _tokenInterface)
                || tokenEquals(bytes, tokens[0], _tokenRouter)
                || tokenEquals(bytes, tokens[0], _tokenLine)
                || tokenEquals(bytes, tokens[0], _tokenRouteMap)
                || tokenEquals(bytes, tokens[0], _tokenPolicyMap)
                || tokenEquals(bytes, tokens[0], _tokenClassMap) {
                let name = lrTrimmedRange(lr)
                items.append(KOutlineItem(kind: .heading, nameRange: name, level: 0, isSingleton: false))
                continue
            }

            if tokenEquals(bytes, tokens[0], _tokenIp), tokens.count >= 2 {
                if tokenEquals(bytes, tokens[1], _tokenAccessList) {
                    let name = lrTrimmedRange(lr)
                    items.append(KOutlineItem(kind: .heading, nameRange: name, level: 0, isSingleton: false))
                    continue
                }
            }
        }

        return items
    }

    // MARK: - Helpers

    private func lrTrimmedRange(_ lr: Range<Int>) -> Range<Int> {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        var start = lr.lowerBound
        var end = lr.upperBound

        start = skeleton.skipSpaces(from: start, to: end)
        while end > start {
            let b = bytes[end - 1]
            if b == FC.space || b == FC.tab {
                end -= 1
                continue
            }
            break
        }

        if start >= end { return lr.lowerBound..<lr.lowerBound }
        return start..<end
    }

    private func findQuotedStrings(in range: Range<Int>) -> [Range<Int>] {
        if range.isEmpty { return [] }

        let bytes = storage.skeletonString.bytes

        var res: [Range<Int>] = []
        res.reserveCapacity(4)

        var i = range.lowerBound
        var inDouble = false
        var inSingle = false
        var start = 0

        while i < range.upperBound {
            let b = bytes[i]

            if inDouble {
                if b == FC.backSlash {
                    i += 2
                    continue
                }
                if b == FC.doubleQuote {
                    res.append(start..<(i + 1))
                    inDouble = false
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            if inSingle {
                if b == FC.backSlash {
                    i += 2
                    continue
                }
                if b == FC.singleQuote {
                    res.append(start..<(i + 1))
                    inSingle = false
                    i += 1
                    continue
                }
                i += 1
                continue
            }

            if b == FC.doubleQuote {
                inDouble = true
                start = i
                i += 1
                continue
            }

            if b == FC.singleQuote {
                inSingle = true
                start = i
                i += 1
                continue
            }

            i += 1
        }

        return res
    }

    private func scanTokens(in range: Range<Int>, stringRanges: [Range<Int>]) -> [Range<Int>] {
        if range.isEmpty { return [] }

        let bytes = storage.skeletonString.bytes

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func isInString(_ pos: Int) -> Bool {
            for r in stringRanges {
                if pos >= r.lowerBound && pos < r.upperBound { return true }
            }
            return false
        }

        var tokens: [Range<Int>] = []
        tokens.reserveCapacity(16)

        var i = range.lowerBound
        while i < range.upperBound {
            while i < range.upperBound, isSpaceOrTab(bytes[i]) { i += 1 }
            if i >= range.upperBound { break }

            if isInString(i) {
                if let sr = stringRanges.first(where: { i >= $0.lowerBound && i < $0.upperBound }) {
                    i = sr.upperBound
                    continue
                }
            }

            let start = i
            while i < range.upperBound {
                let b = bytes[i]
                if isSpaceOrTab(b) { break }
                i += 1
            }
            let end = i
            if start < end {
                tokens.append(start..<end)
            }
        }

        return tokens
    }

    private func tokenEquals(_ bytes: [UInt8], _ range: Range<Int>, _ token: [UInt8]) -> Bool {
        let len = range.count
        if len != token.count { return false }
        if len == 0 { return true }

        var i = 0
        for p in range {
            if bytes[p] != token[i] { return false }
            i += 1
        }
        return true
    }

    private func isNumericToken(bytes: [UInt8], range: Range<Int>) -> Bool {
        if range.isEmpty { return false }

        var hasDigit = false
        var hasDot = false
        var hasSlash = false

        for i in range {
            let b = bytes[i]

            if b.isAsciiDigit {
                hasDigit = true
                continue
            }
            if b == FC.period {
                hasDot = true
                continue
            }
            if b == FC.slash {
                hasSlash = true
                continue
            }

            if b.isAsciiAlpha {
                return false
            }
            return false
        }

        if !hasDigit { return false }
        if hasDot { return true }
        if hasSlash { return true }
        return true
    }

    private func findBannerRanges(covering lineRange: Range<Int>) -> [Range<Int>] {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let startLine = skeleton.lineIndex(at: lineRange.lowerBound)
        let endLine = skeleton.lineIndex(at: max(lineRange.upperBound - 1, lineRange.lowerBound))

        let lookbackStartLine = max(0, startLine - _bannerLookbackMaxLines)

        var res: [Range<Int>] = []
        res.reserveCapacity(1)

        var inBanner = false
        var delimiter: UInt8 = 0
        var bannerStart: Int = 0

        for line in lookbackStartLine...endLine {
            let lr = skeleton.lineRange(at: line)
            if lr.isEmpty { continue }

            var head = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
            if head >= lr.upperBound { continue }

            if bytes[head] == FC.exclamation {
                if inBanner {
                    // banner 内の ! は文字列扱い
                } else {
                    continue
                }
            }

            if inBanner {
                if let end = findByte(delimiter, in: head..<lr.upperBound) {
                    let bannerEnd = end + 1
                    let block = bannerStart..<bannerEnd
                    if !block.clamped(to: lineRange).isEmpty {
                        res.append(block)
                    }
                    inBanner = false
                    delimiter = 0
                    bannerStart = 0
                } else {
                    let block = head..<lr.upperBound
                    if !block.clamped(to: lineRange).isEmpty {
                        res.append(block)
                    }
                }
                continue
            }

            let tokens = scanTokens(in: head..<lr.upperBound, stringRanges: [])
            if tokens.isEmpty { continue }

            if !tokenEquals(bytes, tokens[0], _tokenBanner) { continue }

            // delimiter 取得：banner + type token の次の 1byte
            var p = tokens[0].upperBound
            p = skeleton.skipSpaces(from: p, to: lr.upperBound)

            while p < lr.upperBound {
                let b = bytes[p]
                if b == FC.space || b == FC.tab { break }
                p += 1
            }
            p = skeleton.skipSpaces(from: p, to: lr.upperBound)
            if p >= lr.upperBound { continue }

            delimiter = bytes[p]
            inBanner = true
            bannerStart = p

            if let end = findByte(delimiter, in: (p + 1)..<lr.upperBound) {
                let bannerEnd = end + 1
                let block = bannerStart..<bannerEnd
                if !block.clamped(to: lineRange).isEmpty {
                    res.append(block)
                }
                inBanner = false
                delimiter = 0
                bannerStart = 0
            } else {
                let block = bannerStart..<lr.upperBound
                if !block.clamped(to: lineRange).isEmpty {
                    res.append(block)
                }
            }
        }

        if res.count <= 1 { return res }

        res.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Int>] = []
        merged.reserveCapacity(res.count)

        var cur = res[0]
        for r in res.dropFirst() {
            if r.lowerBound <= cur.upperBound {
                cur = cur.lowerBound..<max(cur.upperBound, r.upperBound)
            } else {
                merged.append(cur)
                cur = r
            }
        }
        merged.append(cur)

        return merged
    }

    private func findByte(_ b: UInt8, in range: Range<Int>) -> Int? {
        if range.isEmpty { return nil }

        let bytes = storage.skeletonString.bytes
        var i = range.lowerBound
        while i < range.upperBound {
            if bytes[i] == b { return i }
            i += 1
        }
        return nil
    }
}
