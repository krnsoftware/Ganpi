//
//  KSyntaxParserYamaha.swift
//
//  Ganpi - macOS Text Editor
//
//  Yamaha Router Config (RTX series etc.) syntax coloring.
//

import AppKit

/// Yamaha ルーター設定向けの軽量カラーリング。
///
/// 方針
/// - フルパースは行わない。
/// - 1行オンデマンドで「コメント」「文字列（クォート）」「値（IP/MAC/数値）」を中心に着色する。
/// - Yamaha はほぼ全行が意味を持つため、命令語や一般語の着色はノイズになりやすい。
///   そのため、命令の判定は outline/currentContext のみに用い、通常の着色では使わない。
final class KSyntaxParserYamaha: KSyntaxParser {

    // MARK: - Properties

    // outline/context 用（頻出トークン）
    private let _tokenPp: [UInt8] = Array("pp".utf8)
    private let _tokenTunnel: [UInt8] = Array("tunnel".utf8)
    private let _tokenSelect: [UInt8] = Array("select".utf8)
    private let _tokenNat: [UInt8] = Array("nat".utf8)
    private let _tokenDescriptor: [UInt8] = Array("descriptor".utf8)
    private let _tokenType: [UInt8] = Array("type".utf8)

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .yamaha)
    }

    // MARK: - Overrides

    override var lineCommentPrefix: String? { "#" }

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let lineRange = skeleton.lineRange(contains: range)
        if lineRange.isEmpty { return [] }

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        @inline(__always)
        func emit(_ r: Range<Int>, _ role: KFunctionalColor, _ out: inout [KAttributedSpan]) {
            let clipped = r.clamped(to: range)
            if clipped.isEmpty { return }
            out.append(makeSpan(range: clipped, role: role))
        }

        // ---- 1) 行頭空白をスキップ
        var head = skeleton.skipSpaces(from: lineRange.lowerBound, to: lineRange.upperBound)
        if head >= lineRange.upperBound { return [] }

        // ---- 2) 行頭コメント（# ; !）
        let headByte = bytes[head]
        if headByte == FC.numeric || headByte == FC.semicolon || headByte == FC.exclamation {
            var spans: [KAttributedSpan] = []
            spans.reserveCapacity(1)
            emit(lineRange, .comment, &spans)
            return spans
        }

        // ---- 3) インラインコメント開始位置（クォートを避けて探索）
        let commentStart = findCommentStart(in: lineRange, head: head, bytes: bytes)
        let codeEnd = commentStart ?? lineRange.upperBound
        let codeRange = head..<codeEnd

        // ---- 4) 命令（行頭トークン）自体は着色しない
        // 値スキャンでは行頭から処理するため、commandTokenEnd は head にしてスキップ無しにする。
        let commandTokenEnd = head

        // ---- 5) 文字列（"..." / '...') を抽出（コメントより前のみ）
        let stringRanges = findQuotedStrings(in: codeRange)

        // ---- 6) spans 構築
        var spans: [KAttributedSpan] = []
        spans.reserveCapacity(16)

        // 6-1) 文字列
        for sr in stringRanges {
            emit(sr, .string, &spans)
        }

        // 6-2) token 走査（コメント手前、文字列はスキップ）
        scanTokens(in: head..<codeEnd,
                   commandTokenEnd: commandTokenEnd,
                   stringRanges: stringRanges,
                   emit: { tokenRange, role in
                       emit(tokenRange, role, &spans)
                   })

        // 6-4) コメント末尾
        if let cs = commentStart {
            emit(cs..<lineRange.upperBound, .comment, &spans)
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
        func isTokenByte(_ b: UInt8) -> Bool {
            if b.isAsciiAlpha || b.isAsciiDigit { return true }
            if b == FC.underscore { return true }
            if b == FC.minus { return true }
            if b == FC.period { return true }
            if b == FC.slash { return true }
            if b == FC.colon { return true }
            return false
        }

        var p: Int? = nil
        if index < n, isTokenByte(bytes[index]) {
            p = index
        } else if index > 0, isTokenByte(bytes[index - 1]) {
            p = index - 1
        }
        guard let pos = p else { return nil }

        var left = pos
        while left > 0, isTokenByte(bytes[left - 1]) { left -= 1 }

        var right = pos + 1
        while right < n, isTokenByte(bytes[right]) { right += 1 }

        return left..<right
    }

    override func outline(in range: Range<Int>?) -> [KOutlineItem] {
        // Yamaha は "select" による擬似ブロックがあるため、そこだけ拾う。
        // - pp select <n>
        // - tunnel select <n>
        // - nat descriptor type <n>
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        if bytes.isEmpty { return [] }

        let lineCount = skeletonLineCount()
        if lineCount <= 0 { return [] }

        var items: [KOutlineItem] = []
        items.reserveCapacity(64)

        for line in 0..<lineCount {
            let lr = skeleton.lineRange(at: line)
            if lr.isEmpty { continue }

            let i0 = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
            if i0 >= lr.upperBound { continue }

            // コメント行は無視
            let hb = bytes[i0]
            if hb == FC.numeric || hb == FC.semicolon || hb == FC.exclamation { continue }

            // 先頭トークン列を取り出し
            let tokens = scanTokenRanges(in: i0..<lr.upperBound, maxTokens: 5)
            if tokens.isEmpty { continue }

            // pp select <n>
            if tokens.count >= 2,
               skeleton.matches(word: _tokenPp, in: tokens[0]),
               skeleton.matches(word: _tokenSelect, in: tokens[1]) {
                let nameEnd = (tokens.count >= 3) ? tokens[2].upperBound : tokens[1].upperBound
                items.append(KOutlineItem(kind: .heading,
                                          nameRange: tokens[0].lowerBound..<nameEnd,
                                          level: 0,
                                          isSingleton: false))
                continue
            }

            // tunnel select <n>
            if tokens.count >= 2,
               skeleton.matches(word: _tokenTunnel, in: tokens[0]),
               skeleton.matches(word: _tokenSelect, in: tokens[1]) {
                let nameEnd = (tokens.count >= 3) ? tokens[2].upperBound : tokens[1].upperBound
                items.append(KOutlineItem(kind: .heading,
                                          nameRange: tokens[0].lowerBound..<nameEnd,
                                          level: 0,
                                          isSingleton: false))
                continue
            }

            // nat descriptor type <n>
            if tokens.count >= 3,
               skeleton.matches(word: _tokenNat, in: tokens[0]),
               skeleton.matches(word: _tokenDescriptor, in: tokens[1]),
               skeleton.matches(word: _tokenType, in: tokens[2]) {
                let nameEnd = (tokens.count >= 4) ? tokens[3].upperBound : tokens[2].upperBound
                items.append(KOutlineItem(kind: .heading,
                                          nameRange: tokens[0].lowerBound..<nameEnd,
                                          level: 0,
                                          isSingleton: false))
                continue
            }
        }

        return items
    }

    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        // caret の直前まで遡り、直近の select を outer として返す。
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        if bytes.isEmpty { return (nil, nil) }

        let n = bytes.count
        let clamped = max(0, min(index, n))
        let caretLine = skeleton.lineIndex(at: clamped)

        let lineCount = skeletonLineCount()
        if lineCount <= 0 { return (nil, nil) }

        // 通常の設定でも十分だが、巨大ファイルの最悪ケースを避ける
        let maxBackLines = 2000

        var scanned = 0
        var line = min(caretLine, lineCount - 1)

        while line >= 0 && scanned < maxBackLines {
            let lr = skeleton.lineRange(at: line)
            if lr.isEmpty { line -= 1; scanned += 1; continue }

            let i0 = skeleton.skipSpaces(from: lr.lowerBound, to: lr.upperBound)
            if i0 >= lr.upperBound { line -= 1; scanned += 1; continue }

            // コメント行は無視
            let hb = bytes[i0]
            if hb == FC.numeric || hb == FC.semicolon || hb == FC.exclamation {
                line -= 1
                scanned += 1
                continue
            }

            let tokens = scanTokenRanges(in: i0..<lr.upperBound, maxTokens: 5)
            if tokens.count >= 2 {
                // pp select <n>
                if skeleton.matches(word: _tokenPp, in: tokens[0]),
                   skeleton.matches(word: _tokenSelect, in: tokens[1]) {
                    let nameEnd = (tokens.count >= 3) ? tokens[2].upperBound : tokens[1].upperBound
                    let outer = storage.string(in: tokens[0].lowerBound..<nameEnd)
                    return (outer, nil)
                }
                // tunnel select <n>
                if skeleton.matches(word: _tokenTunnel, in: tokens[0]),
                   skeleton.matches(word: _tokenSelect, in: tokens[1]) {
                    let nameEnd = (tokens.count >= 3) ? tokens[2].upperBound : tokens[1].upperBound
                    let outer = storage.string(in: tokens[0].lowerBound..<nameEnd)
                    return (outer, nil)
                }
            }

            scanned += 1
            line -= 1
        }

        return (nil, nil)
    }

    // MARK: - Private

    private func findCommentStart(in lineRange: Range<Int>, head: Int, bytes: [UInt8]) -> Int? {
        if head >= lineRange.upperBound { return nil }

        var quote: UInt8 = 0
        var escaped = false
        var i = head

        while i < lineRange.upperBound {
            let b = bytes[i]

            if escaped {
                escaped = false
                i += 1
                continue
            }

            if b == FC.backSlash {
                escaped = true
                i += 1
                continue
            }

            if quote != 0 {
                if b == quote { quote = 0 }
                i += 1
                continue
            }

            // quote open
            if b == FC.singleQuote || b == FC.doubleQuote {
                quote = b
                i += 1
                continue
            }

            // comment mark
            if b == FC.numeric || b == FC.semicolon {
                if i == head {
                    return i
                }
                let prev = bytes[i - 1]
                if prev == FC.space || prev == FC.tab {
                    return i
                }
            }

            i += 1
        }

        return nil
    }

    private func findQuotedStrings(in range: Range<Int>) -> [Range<Int>] {
        if range.isEmpty { return [] }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        var res: [Range<Int>] = []
        res.reserveCapacity(2)

        var i = range.lowerBound
        while i < range.upperBound {
            let b = bytes[i]
            if b == FC.singleQuote || b == FC.doubleQuote {
                let start = i
                let rr = i..<range.upperBound
                switch skeleton.skipQuotedInLine(for: b, in: rr, escape: FC.backSlash) {
                case .found(let next):
                    res.append(start..<next)
                    i = next
                    continue
                case .stopped(let at):
                    // 同一行で止まるのは通常 LF だが、codeRange は LF を含まない。
                    // 念のため安全にクリップして扱う。
                    let end = max(start + 1, min(at, range.upperBound))
                    res.append(start..<end)
                    i = end
                    continue
                case .notFound:
                    res.append(start..<range.upperBound)
                    return res
                }
            }
            i += 1
        }

        return res
    }

    private func scanTokenRanges(in range: Range<Int>, maxTokens: Int) -> [Range<Int>] {
        if range.isEmpty { return [] }
        if maxTokens <= 0 { return [] }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        var res: [Range<Int>] = []
        res.reserveCapacity(min(maxTokens, 8))

        var i = skeleton.skipSpaces(from: range.lowerBound, to: range.upperBound)
        while i < range.upperBound && res.count < maxTokens {
            let start = i
            while i < range.upperBound && !isSpaceOrTab(bytes[i]) {
                i += 1
            }
            if start < i {
                res.append(start..<i)
            }
            i = skeleton.skipSpaces(from: i, to: range.upperBound)
        }

        return res
    }

    private func scanTokens(
        in range: Range<Int>,
        commandTokenEnd: Int,
        stringRanges: [Range<Int>],
        emit: (Range<Int>, KFunctionalColor) -> Void
    ) {
        if range.isEmpty { return }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes

        @inline(__always)
        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        // 文字列の範囲をスキップするためのポインタ
        var sIdx = 0
        let sCount = stringRanges.count

        func advanceStringIndexIfNeeded(_ pos: Int) {
            while sIdx < sCount {
                let sr = stringRanges[sIdx]
                if pos >= sr.upperBound {
                    sIdx += 1
                    continue
                }
                break
            }
        }

        func isInsideString(_ pos: Int) -> Bool {
            if sIdx >= sCount { return false }
            let sr = stringRanges[sIdx]
            return sr.contains(pos)
        }

        // token scan
        var i = skeleton.skipSpaces(from: range.lowerBound, to: range.upperBound)
        while i < range.upperBound {
            advanceStringIndexIfNeeded(i)
            if isInsideString(i) {
                // 文字列の末尾へジャンプ
                let jump = stringRanges[sIdx].upperBound
                i = skeleton.skipSpaces(from: jump, to: range.upperBound)
                continue
            }

            let start = i
            while i < range.upperBound {
                let b = bytes[i]
                if isSpaceOrTab(b) { break }
                // 文字列開始は token から除外（別途 stringRanges で塗る）
                if b == FC.singleQuote || b == FC.doubleQuote { break }
                i += 1
            }
            let tokenRange = start..<i

            // 空 token はスキップ
            if tokenRange.isEmpty {
                i += 1
                i = skeleton.skipSpaces(from: i, to: range.upperBound)
                continue
            }

            // command head のトークン（固定語）は既に塗っている想定。
            // ただし pp select 1 の "1" などは commandTokenEnd 以降なので対象。
            if tokenRange.upperBound <= commandTokenEnd {
                i = skeleton.skipSpaces(from: i, to: range.upperBound)
                continue
            }

            // ---- IP / MAC / numbers (token 内の部分値も含む) ----
            if emitValueTokens(in: tokenRange, bytes: bytes, emit: emit) {
                i = skeleton.skipSpaces(from: i, to: range.upperBound)
                continue
            }

            if isDecimalOrRangeNumber(tokenRange, bytes: bytes) || isCronLikeToken(tokenRange, bytes: bytes) {
                emit(tokenRange, .number)
                i = skeleton.skipSpaces(from: i, to: range.upperBound)
                continue
            }

            i = skeleton.skipSpaces(from: i, to: range.upperBound)
        }
    }

    private func emitValueTokens(
        in tokenRange: Range<Int>,
        bytes: [UInt8],
        emit: (Range<Int>, KFunctionalColor) -> Void
    ) -> Bool {
        // token の中に複数の値が含まれる場合があるため、部分範囲を抽出して塗る。
        // 対象:
        // - IPv4 / IPv4+prefix
        // - IPv4-IPv4 / IPv4-IPv4/prefix
        // - key=value 形式 (例: dns=192.168.0.1)
        // - MAC address (xx:xx:xx:xx:xx:xx)

        if isIPv4Token(tokenRange, bytes: bytes) {
            emit(tokenRange, .number)
            return true
        }

        if isMacAddressToken(tokenRange, bytes: bytes) {
            emit(tokenRange, .number)
            return true
        }

        if let eq = findByte(FC.equals, in: tokenRange, bytes: bytes) {
            let right = (eq + 1)..<tokenRange.upperBound
            if !right.isEmpty {
                if isIPv4Token(right, bytes: bytes) || isIPv4RangeToken(right, bytes: bytes) || isMacAddressToken(right, bytes: bytes) {
                    emit(right, .number)
                    return true
                }
            }
        }

        if isIPv4RangeToken(tokenRange, bytes: bytes) {
            // 左右を分割して塗る
            if let dash = findByte(FC.minus, in: tokenRange, bytes: bytes) {
                let left = tokenRange.lowerBound..<dash
                let right = (dash + 1)..<tokenRange.upperBound

                if isIPv4Token(left, bytes: bytes) {
                    emit(left, .number)
                }
                if isIPv4Token(right, bytes: bytes) {
                    emit(right, .number)
                } else if let slash = findByte(FC.slash, in: right, bytes: bytes) {
                    let ipPart = right.lowerBound..<slash
                    let prefixPart = (slash + 1)..<right.upperBound
                    if isIPv4Token(ipPart, bytes: bytes) {
                        emit(ipPart, .number)
                    }
                    if isDecimalOrRangeNumber(prefixPart, bytes: bytes) {
                        emit(prefixPart, .number)
                    }
                }
                return true
            }
        }

        return false
    }

    private func findByte(_ target: UInt8, in range: Range<Int>, bytes: [UInt8]) -> Int? {
        if range.isEmpty { return nil }
        var i = range.lowerBound
        while i < range.upperBound {
            if bytes[i] == target { return i }
            i += 1
        }
        return nil
    }

    private func isIPv4RangeToken(_ range: Range<Int>, bytes: [UInt8]) -> Bool {
        // 例: 192.168.0.1-192.168.0.254
        //     192.168.0.100-192.168.0.199/24
        if range.isEmpty { return false }
        guard let dash = findByte(FC.minus, in: range, bytes: bytes) else { return false }
        if dash == range.lowerBound { return false }
        if dash + 1 >= range.upperBound { return false }

        let left = range.lowerBound..<dash
        let right = (dash + 1)..<range.upperBound

        // right は IPv4 または IPv4/prefix を許可
        return isIPv4Token(left, bytes: bytes) && isIPv4Token(right, bytes: bytes)
    }

    private func isMacAddressToken(_ range: Range<Int>, bytes: [UInt8]) -> Bool {
        // 例: 00:11:22:33:44:55
        if range.count != 17 { return false }

        @inline(__always)
        func isHex(_ b: UInt8) -> Bool {
            if b.isAsciiDigit { return true }
            if b.isAsciiLower { return b >= 0x61 && b <= 0x66 } // a-f
            if b.isAsciiUpper { return b >= 0x41 && b <= 0x46 } // A-F
            return false
        }

        var i = range.lowerBound
        for seg in 0..<6 {
            if i + 1 >= range.upperBound { return false }
            if !isHex(bytes[i]) { return false }
            if !isHex(bytes[i + 1]) { return false }
            i += 2
            if seg < 5 {
                if i >= range.upperBound { return false }
                if bytes[i] != FC.colon { return false }
                i += 1
            }
        }
        return i == range.upperBound
    }

    private func isIPv4Token(_ range: Range<Int>, bytes: [UInt8]) -> Bool {
        // 例: 192.168.0.1, 192.168.0.1/24
        // 厳密な 0-255 チェックは行わず、形式のみ。
        if range.isEmpty { return false }
        if range.count < 7 { return false } // 0.0.0.0

        var i = range.lowerBound
        let end = range.upperBound

        @inline(__always)
        func readDigits(_ i: inout Int) -> Int {
            let start = i
            while i < end, bytes[i].isAsciiDigit { i += 1 }
            return i - start
        }

        // segment1
        if readDigits(&i) == 0 { return false }
        if i >= end || bytes[i] != FC.period { return false }
        i += 1
        // segment2
        if readDigits(&i) == 0 { return false }
        if i >= end || bytes[i] != FC.period { return false }
        i += 1
        // segment3
        if readDigits(&i) == 0 { return false }
        if i >= end || bytes[i] != FC.period { return false }
        i += 1
        // segment4
        if readDigits(&i) == 0 { return false }

        if i == end { return true }

        // optional: /prefix
        if bytes[i] != FC.slash { return false }
        i += 1
        if i >= end { return false }
        if readDigits(&i) == 0 { return false }
        return i == end
    }

    private func isDecimalOrRangeNumber(_ range: Range<Int>, bytes: [UInt8]) -> Bool {
        // 例: 1, +1, -1, 100-200
        if range.isEmpty { return false }

        var i = range.lowerBound
        let end = range.upperBound

        // optional '+' / '-'
        if bytes[i] == FC.minus || bytes[i] == FC.plus {
            i += 1
            if i >= end { return false }
        }

        // first digits
        var digits = 0
        while i < end, bytes[i].isAsciiDigit {
            digits += 1
            i += 1
        }
        if digits == 0 { return false }

        if i == end { return true }

        // range: <digits>-<digits>
        if bytes[i] != FC.minus { return false }
        i += 1
        if i >= end { return false }

        var tailDigits = 0
        while i < end, bytes[i].isAsciiDigit {
            tailDigits += 1
            i += 1
        }
        if tailDigits == 0 { return false }

        return i == end
    }
    
    private func isCronLikeToken(_ range: Range<Int>, bytes: [UInt8]) -> Bool {
        // 例: */1, 0, 3, *, 1-5, 0,15,30,45
        // 方針:
        // - 許可文字: [0-9 * / , -]
        // - 少なくとも 1 文字は数字 or '*' を含む（完全な記号だけは弾く）
        if range.isEmpty { return false }

        var hasDigit = false
        var hasAsterisk = false

        var i = range.lowerBound
        while i < range.upperBound {
            let b = bytes[i]
            if b.isAsciiDigit {
                hasDigit = true
                i += 1
                continue
            }
            if b == FC.asterisk {
                hasAsterisk = true
                i += 1
                continue
            }
            if b == FC.slash || b == FC.comma || b == FC.minus {
                i += 1
                continue
            }
            return false
        }

        return hasDigit || hasAsterisk
    }
}
