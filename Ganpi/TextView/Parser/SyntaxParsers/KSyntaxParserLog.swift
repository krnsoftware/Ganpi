//
//  KSyntaxParserLog.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/03/08,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

/// Generic log highlighter.
///
/// Targets common patterns across:
/// - syslog-like lines
/// - network equipment logs (Cisco/Yamaha/Juniper style)
/// - key=value logs (firewall/proxy/cloud)
/// - one-line JSON logs (NDJSON)
///
/// Design:
/// - line-oriented, no endState chain
/// - avoid expensive global regex
/// - prefer skeleton-based scanning
final class KSyntaxParserLog: KSyntaxParser {

    // MARK: - Tokens

    private let _tokenError:   [UInt8] = Array("error".utf8)
    private let _tokenWarn:    [UInt8] = Array("warn".utf8)
    private let _tokenWarning: [UInt8] = Array("warning".utf8)
    private let _tokenInfo:    [UInt8] = Array("info".utf8)
    private let _tokenDebug:   [UInt8] = Array("debug".utf8)
    private let _tokenNotice:  [UInt8] = Array("notice".utf8)
    private let _tokenCrit:    [UInt8] = Array("crit".utf8)
    private let _tokenAlert:   [UInt8] = Array("alert".utf8)
    private let _tokenEmerg:   [UInt8] = Array("emerg".utf8)
    private let _tokenFatal:   [UInt8] = Array("fatal".utf8)

    private let _tokenSrc:     [UInt8] = Array("src".utf8)
    private let _tokenDst:     [UInt8] = Array("dst".utf8)
    private let _tokenSpt:     [UInt8] = Array("spt".utf8)
    private let _tokenDpt:     [UInt8] = Array("dpt".utf8)
    private let _tokenProto:   [UInt8] = Array("proto".utf8)
    private let _tokenAction:  [UInt8] = Array("action".utf8)

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .log)
    }

    // MARK: - Detection

    override class func detectScore(content: String) -> Int? {
        if content.isEmpty { return nil }

        let maxLines = 200
        var checked = 0

        var timestampHits = 0
        var severityHits = 0
        var keyValueHits = 0
        var ipHits = 0
        var ciscoHits = 0

        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if checked >= maxLines { break }
            checked += 1

            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if looksLikeIsoTimestamp(line) || looksLikeSyslogTimestamp(line) {
                timestampHits += 1
            }

            let lower = line.lowercased()
            if lower.contains(" error") || lower.contains(" error:") || lower.contains(" fatal") {
                severityHits += 1
            } else if lower.contains(" warn") || lower.contains(" warning") || lower.contains(" crit") || lower.contains(" alert") {
                severityHits += 1
            } else if lower.contains(" info") || lower.contains(" debug") || lower.contains(" notice") {
                severityHits += 1
            }

            if lower.contains("=") {
                var eq = 0
                for ch in lower where ch == "=" { eq += 1 }
                if eq >= 2 { keyValueHits += 1 }
            }

            if lower.contains("%") && lower.contains(":") {
                ciscoHits += 1
            }

            if containsIpv4Like(lower) { ipHits += 1 }
        }

        var score = 0
        if timestampHits >= 2 { score += 20 }
        if severityHits >= 2 { score += 20 }
        if keyValueHits >= 2 { score += 20 }
        if ipHits >= 2 { score += 10 }
        if ciscoHits >= 1 { score += 10 }

        if score >= 30 { return score }
        return nil
    }

    private class func looksLikeIsoTimestamp(_ line: String) -> Bool {
        if line.count < 10 { return false }
        let p = Array(line.prefix(10))
        if p.count < 10 { return false }
        if !p[0].isNumber || !p[1].isNumber || !p[2].isNumber || !p[3].isNumber { return false }
        if p[4] != "-" && p[4] != "/" { return false }
        return true
    }

    private class func looksLikeSyslogTimestamp(_ line: String) -> Bool {
        if line.count < 15 { return false }
        let p3 = line.prefix(3).lowercased()
        let months: Set<String> = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
        return months.contains(String(p3))
    }

    private class func containsIpv4Like(_ lower: String) -> Bool {
        var dots = 0
        var digits = 0
        for ch in lower {
            if ch == "." { dots += 1 }
            else if ch.isNumber { digits += 1 }
        }
        return dots >= 3 && digits >= 4
    }

    // MARK: - Highlighting

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let lineRange = skeleton.lineRange(contains: range)
        if lineRange.isEmpty { return [] }

        let startLine = skeleton.lineIndex(at: lineRange.lowerBound)
        let endLine = skeleton.lineIndex(at: max(lineRange.upperBound - 1, lineRange.lowerBound))

        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(64)

        @inline(__always)
        func emit(_ r: Range<Int>, _ role: KFunctionalColor) {
            let clipped = r.clamped(to: range)
            if clipped.isEmpty { return }
            spans.append(makeSpan(range: clipped, role: role))
        }

        for line in startLine...endLine {
            let lr = skeleton.lineRange(at: line)
            if lr.isEmpty { continue }

            let head = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
            if head >= lr.upperBound { continue }

            // comment line (#...)
            if bytes[head] == FC.numeric {
                emit(lr, .comment)
                continue
            }

            // quoted strings
            let stringRanges = findQuotedStrings(in: head..<lr.upperBound)
            for sr in stringRanges { emit(sr, .string) }

            // timestamp near head
            if let ts = findTimestampRange(in: head..<lr.upperBound) {
                emit(ts, .number)
            }

            // Cisco %FAC-SEV-MNEMONIC:
            for pr in findCiscoPercentMessage(in: head..<lr.upperBound, stringRanges: stringRanges) {
                emit(pr, .keyword)
            }

            // key=value
            let pairs = findKeyValuePairs(in: head..<lr.upperBound, stringRanges: stringRanges)
            for (k, v) in pairs {
                emit(k, .variable)
                if let vr = v {
                    if isQuoted(range: vr) {
                        emit(vr, .string)
                    } else {
                        emit(vr, .number)
                    }
                }
            }

            // token scan

            // token scan
            let tokens = scanTokens(in: head..<lr.upperBound, stringRanges: stringRanges)

            // severity tokens
            for tr in tokens {
                if isSeverityToken(bytes: bytes, range: tr) {
                    emit(tr, .keyword)
                }
            }

            // port numbers: "port 55234" / "dport 443" style (non key=value)
            for i in 0..<(max(0, tokens.count - 1)) {
                let t0 = tokens[i]
                if isPortKeyToken(bytes: bytes, range: t0) {
                    let t1 = tokens[i + 1]
                    if isPortNumberToken(bytes: bytes, range: t1) {
                        emit(t1, .number)
                    }
                }
            }

            // IPv4 / MAC
            for ip in findIPv4Ranges(in: head..<lr.upperBound, stringRanges: stringRanges) {
                emit(ip, .number)
            }
            for mac in findMacRanges(in: head..<lr.upperBound, stringRanges: stringRanges) {
                emit(mac, .number)
            }

            // common keys (for logs like "src 1.2.3.4")
            for tr in tokens {
                if isCommonKeyToken(bytes: bytes, range: tr) {
                    emit(tr, .keyword)
                }
            }

        }

        return spans
    }

    // MARK: - wordRange / context / outline

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
            if b == FC.equals { return true }
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
        while start > 0, isWordByte(bytes[start - 1]) { start -= 1 }

        var end = pos + 1
        while end < n, isWordByte(bytes[end]) { end += 1 }

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
        let lr = skeleton.lineRange(at: lineIndex)
        if lr.isEmpty { return (nil, nil) }

        func trimmed(_ r: Range<Int>) -> String {
            storage.string(in: r).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let innerStr = trimmed(lr)
        let inner: String? = innerStr.isEmpty ? nil : innerStr

        let head = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
        if head >= lr.upperBound { return (nil, inner) }

        // skip optional PRI (<134>)
        var p = head
        if bytes[p] == FC.lt {
            if let gt = findByte(FC.gt, in: (p + 1)..<lr.upperBound) {
                p = gt + 1
                p = skeleton.skipSpaces(from: p, to: lr.upperBound)
            }
        }

        // skip timestamp token if found
        if let ts = findTimestampRange(in: p..<lr.upperBound) {
            p = ts.upperBound
            p = skeleton.skipSpaces(from: p, to: lr.upperBound)
        } else {
            // syslog month format: consume first 3 tokens (Mon dd hh:mm:ss)
            let toks = scanTokens(in: p..<lr.upperBound, stringRanges: [])
            if toks.count >= 3, isMonthToken(bytes: bytes, range: toks[0]) {
                p = toks[2].upperBound
                p = skeleton.skipSpaces(from: p, to: lr.upperBound)
            }
        }

        let toks2 = scanTokens(in: p..<lr.upperBound, stringRanges: [])
        if toks2.isEmpty { return (nil, inner) }

        let host = toks2[0]
        var outerRange: Range<Int> = host

        if toks2.count >= 2 {
            let tag = toks2[1]
            if let colon = findByte(FC.colon, in: tag.lowerBound..<min(tag.upperBound + 1, lr.upperBound)) {
                outerRange = host.lowerBound..<(colon + 1)
            } else {
                outerRange = host.lowerBound..<tag.upperBound
            }
        }

        let outerStr = trimmed(outerRange)
        let outer: String? = outerStr.isEmpty ? nil : outerStr

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
            if bytes[head] == FC.numeric { continue }

            let tokens = scanTokens(in: head..<lr.upperBound, stringRanges: [])
            if tokens.isEmpty { continue }

            var rank: Int? = nil
            for tr in tokens {
                if let r = severityRank(bytes: bytes, range: tr) {
                    rank = max(rank ?? 0, r)
                }
            }

            // include WARN and above
            if let r = rank, r >= 3 {
                let name = trimmedLineRange(lr)
                if !name.isEmpty {
                    items.append(KOutlineItem(kind: .heading, nameRange: name, level: 0, isSingleton: false))
                }
            }
        }

        return items
    }

    // MARK: - Helpers

    private func trimmedLineRange(_ lr: Range<Int>) -> Range<Int> {
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
            if start < end { tokens.append(start..<end) }
        }

        return tokens
    }

    private func findTimestampRange(in range: Range<Int>) -> Range<Int>? {
        if range.isEmpty { return nil }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        let limit = min(range.lowerBound + 80, range.upperBound)
        let i = range.lowerBound

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        // 先頭から次の空白までを token として切る
        @inline(__always)
        func consumeToken(from start: Int) -> Range<Int>? {
            if start >= range.upperBound { return nil }
            var j = start
            while j < range.upperBound {
                let b = bytes[j]
                if isSpaceOrTab(b) { break }
                j += 1
            }
            if start >= j { return nil }
            return start..<j
        }

        @inline(__always)
        func skipSpaces(_ p: Int) -> Int {
            skeleton.skipSpaces(from: p, to: range.upperBound)
        }

        @inline(__always)
        func looksLikeIsoDateToken(_ r: Range<Int>) -> Bool {
            // "YYYY-MM-DD" or "YYYY/MM/DD"
            if r.count < 10 { return false }
            let p = r.lowerBound
            if p + 9 >= r.upperBound { return false }

            if !bytes[p].isAsciiDigit || !bytes[p + 1].isAsciiDigit || !bytes[p + 2].isAsciiDigit || !bytes[p + 3].isAsciiDigit {
                return false
            }
            let sep = bytes[p + 4]
            if sep != FC.minus && sep != FC.slash { return false }

            // MM
            if !bytes[p + 5].isAsciiDigit || !bytes[p + 6].isAsciiDigit { return false }
            // sep
            if bytes[p + 7] != sep { return false }
            // DD
            if !bytes[p + 8].isAsciiDigit || !bytes[p + 9].isAsciiDigit { return false }

            return true
        }

        @inline(__always)
        func looksLikeTimeToken(_ r: Range<Int>) -> Bool {
            // "HH:MM:SS" or "HH:MM:SS.mmm"
            let p = r.lowerBound
            if r.count < 8 { return false }
            if p + 7 >= r.upperBound { return false }

            if !bytes[p].isAsciiDigit || !bytes[p + 1].isAsciiDigit { return false }
            if bytes[p + 2] != FC.colon { return false }
            if !bytes[p + 3].isAsciiDigit || !bytes[p + 4].isAsciiDigit { return false }
            if bytes[p + 5] != FC.colon { return false }
            if !bytes[p + 6].isAsciiDigit || !bytes[p + 7].isAsciiDigit { return false }

            // optional ".mmm"
            if p + 8 < r.upperBound {
                if bytes[p + 8] == FC.period {
                    // . + at least 1 digit
                    if p + 9 >= r.upperBound { return false }
                    if !bytes[p + 9].isAsciiDigit { return false }
                }
            }
            return true
        }

        @inline(__always)
        func mergeDateAndTimeIfPossible(_ dateToken: Range<Int>) -> Range<Int> {
            var p = dateToken.upperBound
            p = skipSpaces(p)
            if let timeToken = consumeToken(from: p) {
                if looksLikeTimeToken(timeToken) {
                    return dateToken.lowerBound..<timeToken.upperBound
                }
            }
            return dateToken
        }

        // PRI + ISO: <134>2026-03-08...
        if bytes[i] == FC.lt {
            if let gt = findByte(FC.gt, in: (i + 1)..<min(limit, range.upperBound)) {
                var p = gt + 1
                p = skipSpaces(p)
                if let t0 = consumeToken(from: p) {
                    if looksLikeIsoDateToken(t0) {
                        return mergeDateAndTimeIfPossible(t0)
                    }
                    // <PRI>2026-03-08T10:... のように空白無しでも token 全体を返す
                    if bytes[t0.lowerBound].isAsciiDigit, t0.count >= 10 {
                        let sep = bytes[t0.lowerBound + 4]
                        if sep == FC.minus || sep == FC.slash {
                            return t0
                        }
                    }
                }
            }
        }

        // ISO at head: YYYY-MM-DD ...
        if let t0 = consumeToken(from: i) {
            if looksLikeIsoDateToken(t0) {
                return mergeDateAndTimeIfPossible(t0)
            }

            // ISO 8601 "YYYY-MM-DDT..." のように空白無し（token全体）
            if t0.count >= 10, bytes[t0.lowerBound].isAsciiDigit {
                let sep = bytes[t0.lowerBound + 4]
                if sep == FC.minus || sep == FC.slash {
                    return t0
                }
            }
        }

        // syslog month format: "Mar  8 12:34:56"
        if range.upperBound - range.lowerBound >= 15 {
            let month = i..<(i + 3)
            if isMonthToken(bytes: bytes, range: month) {
                let j = min(i + 15, range.upperBound)
                return i..<j
            }
        }

        return nil
    }

    private func isMonthToken(bytes: [UInt8], range: Range<Int>) -> Bool {
        if range.count != 3 { return false }
        guard let s = String(bytes: Array(bytes[range]), encoding: .utf8)?.lowercased() else { return false }
        return ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"].contains(s)
    }

    private func findCiscoPercentMessage(in range: Range<Int>, stringRanges: [Range<Int>]) -> [Range<Int>] {
        if range.isEmpty { return [] }

        let bytes = storage.skeletonString.bytes

        @inline(__always)
        func isInString(_ pos: Int) -> Bool {
            for r in stringRanges {
                if pos >= r.lowerBound && pos < r.upperBound { return true }
            }
            return false
        }

        var res: [Range<Int>] = []
        res.reserveCapacity(1)

        var i = range.lowerBound
        while i < range.upperBound {
            if isInString(i) { i += 1; continue }

            if bytes[i] == FC.percent {
                var j = i + 1
                var sawDashDigitDash = false
                var lastDash: Int? = nil

                while j < range.upperBound {
                    let b = bytes[j]
                    if b == FC.colon {
                        if sawDashDigitDash {
                            res.append(i..<(j + 1))
                        }
                        break
                    }
                    if b == FC.space || b == FC.tab { break }

                    if b == FC.minus {
                        if let ld = lastDash {
                            if j - ld == 2 {
                                let d = bytes[ld + 1]
                                if d.isAsciiDigit { sawDashDigitDash = true }
                            }
                        }
                        lastDash = j
                    }
                    j += 1
                }

                i = j
                continue
            }

            i += 1
        }

        return res
    }

    private func findKeyValuePairs(in range: Range<Int>, stringRanges: [Range<Int>]) -> [(Range<Int>, Range<Int>?)] {
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

        @inline(__always)
        func isKeyByte(_ b: UInt8) -> Bool {
            if b.isAsciiAlpha || b.isAsciiDigit { return true }
            if b == FC.underscore { return true }
            if b == FC.minus { return true }
            if b == FC.period { return true }
            return false
        }

        var res: [(Range<Int>, Range<Int>?)] = []
        res.reserveCapacity(16)

        var i = range.lowerBound
        while i < range.upperBound {
            if isInString(i) { i += 1; continue }
            if bytes[i] != FC.equals { i += 1; continue }

            let kEnd = i
            var kStart = i
            while kStart > range.lowerBound {
                let b = bytes[kStart - 1]
                if isSpaceOrTab(b) { break }
                if !isKeyByte(b) { break }
                kStart -= 1
            }
            if kStart == kEnd { i += 1; continue }

            let keyRange = kStart..<kEnd

            var vStart = i + 1
            while vStart < range.upperBound, isSpaceOrTab(bytes[vStart]) { vStart += 1 }
            if vStart >= range.upperBound {
                res.append((keyRange, nil))
                break
            }

            var vEnd = vStart
            if bytes[vStart] == FC.doubleQuote || bytes[vStart] == FC.singleQuote {
                if let sr = stringRanges.first(where: { $0.lowerBound == vStart }) {
                    res.append((keyRange, sr))
                    i = sr.upperBound
                    continue
                }

                let quote = bytes[vStart]
                vEnd += 1
                while vEnd < range.upperBound {
                    let b = bytes[vEnd]
                    if b == FC.backSlash {
                        vEnd += 2
                        continue
                    }
                    if b == quote {
                        vEnd += 1
                        break
                    }
                    vEnd += 1
                }
                res.append((keyRange, vStart..<vEnd))
                i = vEnd
                continue
            }

            while vEnd < range.upperBound {
                let b = bytes[vEnd]
                if isSpaceOrTab(b) { break }
                vEnd += 1
            }
            res.append((keyRange, vStart..<vEnd))
            i = vEnd
        }

        return res
    }

    private func findIPv4Ranges(in range: Range<Int>, stringRanges: [Range<Int>]) -> [Range<Int>] {
        if range.isEmpty { return [] }

        let bytes = storage.skeletonString.bytes

        @inline(__always)
        func isInString(_ pos: Int) -> Bool {
            for r in stringRanges {
                if pos >= r.lowerBound && pos < r.upperBound { return true }
            }
            return false
        }

        var res: [Range<Int>] = []
        res.reserveCapacity(8)

        var i = range.lowerBound
        while i < range.upperBound {
            if isInString(i) { i += 1; continue }
            if !bytes[i].isAsciiDigit { i += 1; continue }

            let start = i
            var dots = 0
            var j = i
            while j < range.upperBound {
                let b = bytes[j]
                if b.isAsciiDigit { j += 1; continue }
                if b == FC.period { dots += 1; j += 1; continue }
                break
            }

            if dots == 3, j > start, bytes[j - 1].isAsciiDigit {
                res.append(start..<j)
            }

            i = max(j, start + 1)
        }

        return res
    }

    private func findMacRanges(in range: Range<Int>, stringRanges: [Range<Int>]) -> [Range<Int>] {
        if range.isEmpty { return [] }

        let bytes = storage.skeletonString.bytes

        @inline(__always)
        func isInString(_ pos: Int) -> Bool {
            for r in stringRanges {
                if pos >= r.lowerBound && pos < r.upperBound { return true }
            }
            return false
        }

        @inline(__always)
        func isHex(_ b: UInt8) -> Bool {
            if b.isAsciiDigit { return true }
            if b >= 0x41 && b <= 0x46 { return true }
            if b >= 0x61 && b <= 0x66 { return true }
            return false
        }

        var res: [Range<Int>] = []
        res.reserveCapacity(4)

        var i = range.lowerBound
        while i + 16 < range.upperBound {
            if isInString(i) { i += 1; continue }

            var ok = true
            for k in 0..<17 {
                let b = bytes[i + k]
                if k % 3 == 2 {
                    if b != FC.colon && b != FC.minus { ok = false; break }
                } else {
                    if !isHex(b) { ok = false; break }
                }
            }

            if ok {
                res.append(i..<(i + 17))
                i += 17
                continue
            }

            i += 1
        }

        return res
    }

    private func isQuoted(range: Range<Int>) -> Bool {
        if range.count < 2 { return false }
        let bytes = storage.skeletonString.bytes
        let a = bytes[range.lowerBound]
        let b = bytes[range.upperBound - 1]
        return (a == FC.doubleQuote && b == FC.doubleQuote) || (a == FC.singleQuote && b == FC.singleQuote)
    }

    private func isSeverityToken(bytes: [UInt8], range: Range<Int>) -> Bool {
        let lowered = lowercasedToken(bytes: bytes, range: range)
        if lowered.isEmpty { return false }

        if lowered == _tokenError { return true }
        if lowered == _tokenWarn { return true }
        if lowered == _tokenWarning { return true }
        if lowered == _tokenInfo { return true }
        if lowered == _tokenDebug { return true }
        if lowered == _tokenNotice { return true }
        if lowered == _tokenCrit { return true }
        if lowered == _tokenAlert { return true }
        if lowered == _tokenEmerg { return true }
        if lowered == _tokenFatal { return true }

        if lowered == Array("err".utf8) { return true }
        if lowered == Array("wrn".utf8) { return true }
        if lowered == Array("dbg".utf8) { return true }

        return false
    }

    private func severityRank(bytes: [UInt8], range: Range<Int>) -> Int? {
        // 0=trace,1=debug,2=info,3=warn,4=error,5=critical
        let lowered = lowercasedToken(bytes: bytes, range: range)
        if lowered.isEmpty { return nil }

        if lowered == _tokenWarn || lowered == _tokenWarning { return 3 }
        if lowered == _tokenError || lowered == Array("err".utf8) { return 4 }
        if lowered == _tokenCrit || lowered == _tokenAlert || lowered == _tokenEmerg || lowered == _tokenFatal { return 5 }
        if lowered == _tokenInfo || lowered == _tokenNotice { return 2 }
        if lowered == _tokenDebug { return 1 }
        if lowered == Array("trace".utf8) { return 0 }

        return nil
    }

    private func isCommonKeyToken(bytes: [UInt8], range: Range<Int>) -> Bool {
        let lowered = lowercasedToken(bytes: bytes, range: range)
        if lowered == _tokenSrc { return true }
        if lowered == _tokenDst { return true }
        if lowered == _tokenSpt { return true }
        if lowered == _tokenDpt { return true }
        if lowered == _tokenProto { return true }
        if lowered == _tokenAction { return true }

        if lowered == Array("host".utf8) { return true }
        if lowered == Array("pid".utf8) { return true }
        if lowered == Array("tid".utf8) { return true }
        if lowered == Array("id".utf8) { return true }
        if lowered == Array("level".utf8) { return true }
        if lowered == Array("severity".utf8) { return true }
        if lowered == Array("msg".utf8) { return true }

        return false
    }

    private func lowercasedToken(bytes: [UInt8], range: Range<Int>) -> [UInt8] {
        if range.isEmpty { return [] }
        var res: [UInt8] = []
        res.reserveCapacity(min(32, range.count))

        var i = range.lowerBound
        while i < range.upperBound {
            let b = bytes[i]
            if b >= 0x41 && b <= 0x5A {
                res.append(b + 0x20)
            } else {
                res.append(b)
            }
            i += 1
        }
        return res
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
    
    private func isPortKeyToken(bytes: [UInt8], range: Range<Int>) -> Bool {
        let lowered = lowercasedToken(bytes: bytes, range: range)
        if lowered == Array("port".utf8) { return true }
        if lowered == Array("sport".utf8) { return true }
        if lowered == Array("dport".utf8) { return true }
        if lowered == Array("srcport".utf8) { return true }
        if lowered == Array("dstport".utf8) { return true }
        if lowered == Array("sourceport".utf8) { return true }
        if lowered == Array("destport".utf8) { return true }
        return false
    }

    private func isPortNumberToken(bytes: [UInt8], range: Range<Int>) -> Bool {
        if range.isEmpty { return false }

        var value = 0
        for i in range {
            let b = bytes[i]
            if !b.isAsciiDigit { return false }
            value = value * 10 + Int(b - 0x30)
            if value > 65535 { return false }
        }

        if value <= 0 { return false }
        return true
    }
}
