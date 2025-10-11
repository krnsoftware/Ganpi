//
//  KSyntaxParserIni.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/11,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

/// INI 専用の軽量パーサ（アウトライン無し）
/// - ポリシー: キャッシュを持たない / 見えている行だけ毎回解析 / 行越え状態は保持しない
final class KSyntaxParserIni: KSyntaxParserProtocol {

    // MARK: - Required by protocol

    let storage: KTextStorageReadable

    // コメント用のプレフィクス（プロトコル上は単一）。歴史的経緯に合わせて「;」を返す。
    // 「#」は attributes(in:) の字句解析で行内コメントとして扱う。
    var lineCommentPrefix: String? { ";" }

    // MARK: - Init

    init(storage: KTextStorageReadable) {
        self.storage = storage
    }

    // MARK: - Incremental hooks（INIは行依存が無いので実質NOP）

    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        // 何もしない（毎回 attributes(in:) 側で必要分を解析する）
    }

    func ensureUpToDate(for range: Range<Int>) {
        // 何もしない
    }

    // 一括パースが必要な場面は無いが、プロトコル準拠のため定義だけ置く
    func parse(range: Range<Int>) {
        // 何もしない（都度 attributes(in:) で行う）
    }

    // MARK: - Painter hook

    /// 可視レンジに対して、物理行境界に丸めた上で毎回解析する。
    /// 返却は元の range と交差するスパンのみ。
    // KSyntaxParserIni.swift / class KSyntaxParserIni 内にそのまま置き換え
    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
            let bytes: [UInt8] = storage.skeletonString.bytes
            let n = bytes.count
            if n == 0 { return [] }

            // 1) 可視レンジを物理行境界に拡大
            let lo = max(0, min(range.lowerBound, n - 1))
            let hi = max(0, min(range.upperBound, n))
            let lineLo = findLineHead(bytes, from: lo)
            let lineHi = findLineTail(bytes, from: hi)

            // 2) 行ごとにスキャンしてスパン生成
            var out: [KAttributedSpan] = []
            var i = lineLo
            while i < lineHi {
                let lineStart = i
                let lineEnd = findLineEnd(bytes, from: i, limit: lineHi)
                scanOneLine(bytes,
                            start: lineStart,
                            end: lineEnd,
                            into: &out)
                i = lineEnd < n ? lineEnd + 1 : lineEnd // 改行を飛ばす
            }

            // 3) 元の可視レンジと交差するスパンだけ返す
            if range.lowerBound <= lineLo && lineHi <= range.upperBound {
                return out
            } else {
                let vis = range
                return out.compactMap { span in
                    let a = max(span.range.lowerBound, vis.lowerBound)
                    let b = min(span.range.upperBound,   vis.upperBound)
                    return (a < b) ? KAttributedSpan(range: a..<b, attributes: span.attributes) : nil
                }
            }
        }
    
    var baseTextColor: NSColor {
        get {
            _colorBase
        }
    }
    
    // KSyntaxParserIni 内（他の private func と同じ場所）に追加
    private func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        if ranges.isEmpty { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        var cur = sorted[0]
        for r in sorted.dropFirst() {
            if r.lowerBound <= cur.upperBound { // 隣接/重複を結合（upperBound一致も結合扱い）
                cur = cur.lowerBound..<max(cur.upperBound, r.upperBound)
            } else {
                out.append(cur)
                cur = r
            }
        }
        out.append(cur)
        return out
    }

    // MARK: - Word

    /// INI向けの単語拡張: [A-Za-z0-9_.-] を単語とみなす。区切りは = : [ ] ; # と空白。
    func wordRange(at index: Int) -> Range<Int>? {
        let bytes: [UInt8] = storage.skeletonString.bytes
        let n = bytes.count
        if n == 0 || index < 0 || index >= n { return nil }

        func isWord(_ c: UInt8) -> Bool {
            // 0-9 A-Z a-z _ . -
            return (c >= 0x30 && c <= 0x39)
                || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A)
                || c == 0x5F || c == 0x2E || c == 0x2D
        }

        var lo = index
        var hi = index

        while lo > 0, isWord(bytes[lo - 1]) { lo -= 1 }
        while hi < n, isWord(bytes[hi])     { hi += 1 }

        return (lo < hi) ? (lo..<hi) : nil
    }

    // MARK: - Outline（未対応）

    func outline(in range: Range<Int>? = nil) -> [KOutlineItem] { [] }
    func currentContext(at index: Int) -> [KOutlineItem] { [] }

    // MARK: - Completion（最小実装：ブール定型のみ）

    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?) {
        // 何もしない（定型候補のみ）
    }

    /// 最小構成：定型値（true/false/on/off/yes/no）のみ。大小区別、前方一致。
    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry] {
        if prefix.isEmpty { return [] }
        let candidates = ["true", "false", "on", "off", "yes", "no"]
        let filtered = candidates.filter { $0.hasPrefix(prefix) }
                                 .sorted()
                                 .prefix(limit)
        return filtered.map {
            KCompletionEntry(text: $0, kind: .keyword, detail: nil, score: 0)
        }
    }

    // MARK: - 色（簡易固定。テーマ連動は将来拡張）

    private let _colorBase     = NSColor.darkGray
    private let _colorSection  = NSColor.systemBlue
    private let _colorKey      = NSColor(hexString: "#7A4E00") ?? .black
    private let _colorDelim    = NSColor.systemGray
    private let _colorValue    = NSColor.labelColor
    private let _colorComment  = NSColor(hexString: "#0B5A00") ?? .black
    private let _colorNumber   = NSColor(hexString: "#070093") ?? .black
    private let _colorBoolean  = NSColor.systemOrange

    // MARK: - 1行スキャナ本体（行内で完結）

    /// 行 [start, end]（end は改行直前の位置を想定）を解析して、色スパンを out に追加する。
    /// 仕様：
    /// - セクション: `^\s*$begin:math:display$[^]]+$end:math:display$`
    /// - コメント行: `^\s*[;#]`
    /// - キー=値   : 最初の '=' または ':' で左右に分割
    /// - 行内コメント: 値のクォート **外** に現れる ';' or '#'
    private func scanOneLine(_ p: [UInt8], start: Int, end: Int, into out: inout [KAttributedSpan]) {
        if start >= end { return }

        // 先頭空白スキップ
        var i = start
        while i < end, isSpace(p[i]) { i += 1 }
        if i >= end { return }

        // ---- コメント行（; / #） ----
        if p[i] == 0x3B || p[i] == 0x23 { // ';' or '#'
            appendSpan(i, end, _colorComment, into: &out)
            return
        }

        // ---- セクション行 ----
        if p[i] == 0x5B { // '['
            // 右括弧を探す（不正でも [〜 行末 をセクション色で塗る）
            var j = i + 1
            while j < end, p[j] != 0x5D { j += 1 } // ']'
            let sectionEnd = (j < end) ? (j + 1) : end
            appendSpan(i, sectionEnd, _colorSection, into: &out)

            // セクション後ろに行内コメントが来る場合
            var k = sectionEnd
            while k < end, isSpace(p[k]) { k += 1 }
            if k < end, (p[k] == 0x3B || p[k] == 0x23) {
                appendSpan(k, end, _colorComment, into: &out)
            }
            return
        }

        // ---- キー = 値 ----
        // 最初に現れた '=' または ':' を区切りとみなす
        var sep = -1
        var j = i
        while j < end {
            let c = p[j]
            if c == 0x3D || c == 0x3A { // '=' or ':'
                sep = j
                break
            }
            if c == 0x3B || c == 0x23 { // ';' or '#': 行頭からここまでに区切りが無ければコメント行扱い
                appendSpan(j, end, _colorComment, into: &out)
                return
            }
            j += 1
        }

        if sep < 0 {
            // 区切り無し: 何もしない（将来、薄い警告をつけるならここ）
            return
        }

        // 左辺（キー）
        let keyStart = i
        var keyEnd = sep
        // 左辺末尾の空白は除く
        while keyEnd > keyStart, isSpace(p[keyEnd - 1]) { keyEnd -= 1 }
        if keyStart < keyEnd {
            appendSpan(keyStart, keyEnd, _colorKey, into: &out)
        }

        // 区切り
        appendSpan(sep, sep + 1, _colorDelim, into: &out)

        // 右辺（値）: クォート内外を判定、行内コメントを切り分け
        var k = sep + 1
        // 右辺先頭の空白はスキップ
        while k < end, isSpace(p[k]) { k += 1 }
        if k >= end { return }

        // クォート外で ';' / '#' が現れたら行内コメント開始
        var inSingle = false
        var inDouble = false
        var valStart = k
        var x = k
        var commentStart: Int? = nil

        while x < end {
            let c = p[x]
            if inSingle {
                if c == 0x27 { inSingle = false } // '
                x += 1
                continue
            }
            if inDouble {
                if c == 0x22 { inDouble = false } // "
                else if c == 0x5C { // バックスラッシュ
                    x += (x + 1 < end) ? 2 : 1
                    continue
                }
                x += 1
                continue
            }
            // クォート外
            if c == 0x27 { inSingle = true; x += 1; continue } // '
            if c == 0x22 { inDouble = true; x += 1; continue } // "
            if c == 0x3B || c == 0x23 { // ';' or '#'
                commentStart = x
                break
            }
            x += 1
        }

        let valEnd = commentStart ?? end
        if valStart < valEnd {
            // 値の型っぽさ（任意の弱い色分け）
            if isBooleanLiteral(p, valStart, valEnd) {
                appendSpan(valStart, valEnd, _colorBoolean, into: &out)
            } else if isNumericLiteral(p, valStart, valEnd) {
                appendSpan(valStart, valEnd, _colorNumber, into: &out)
            } else {
                appendSpan(valStart, valEnd, _colorValue, into: &out)
            }
        }

        if let cs = commentStart {
            appendSpan(cs, end, _colorComment, into: &out)
        }
    }

    // MARK: - Helpers（private func は _ を付けない規約）

    private func isSpace(_ c: UInt8) -> Bool {
        // space, tab, CR, LF
        return c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    }

    private func appendSpan(_ lo: Int, _ hi: Int, _ color: NSColor, into out: inout [KAttributedSpan]) {
        if lo >= hi { return }
        out.append(
            KAttributedSpan(
                range: lo..<hi,
                attributes: [.foregroundColor: color]
            )
        )
    }

    private func findLineHead(_ p: [UInt8], from i0: Int) -> Int {
        var i = min(i0, p.count - 1)
        while i > 0, p[i - 1] != 0x0A { i -= 1 } // LF
        return i
    }

    private func findLineTail(_ p: [UInt8], from i0: Int) -> Int {
        var i = min(max(0, i0), p.count)
        while i < p.count, p[i] != 0x0A { i += 1 } // LF
        return i
    }

    private func findLineEnd(_ p: [UInt8], from i0: Int, limit: Int) -> Int {
        var i = i0
        let lim = min(limit, p.count)
        while i < lim, p[i] != 0x0A { i += 1 }
        return min(i, lim)
    }

    private func isBooleanLiteral(_ p: [UInt8], _ lo: Int, _ hi: Int) -> Bool {
        // 前後空白を除去したスライスで判定（true/false/on/off/yes/no）
        var a = lo
        var b = hi
        while a < b, isSpace(p[a]) { a += 1 }
        while b > a, isSpace(p[b - 1]) { b -= 1 }
        let len = b - a
        if len == 2 { // no, on
            return (p[a] == 0x6E && p[a+1] == 0x6F) || // "no"
                   (p[a] == 0x6F && p[a+1] == 0x6E)    // "on"
        } else if len == 3 { // yes, off
            return (p[a] == 0x79 && p[a+1] == 0x65 && p[a+2] == 0x73) || // "yes"
                   (p[a] == 0x6F && p[a+1] == 0x66 && p[a+2] == 0x66)    // "off"
        } else if len == 4 { // true
            return (p[a] == 0x74 && p[a+1] == 0x72 && p[a+2] == 0x75 && p[a+3] == 0x65)
        } else if len == 5 { // false
            return (p[a] == 0x66 && p[a+1] == 0x61 && p[a+2] == 0x6C && p[a+3] == 0x73 && p[a+4] == 0x65)
        }
        return false
    }

    private func isNumericLiteral(_ p: [UInt8], _ lo: Int, _ hi: Int) -> Bool {
        // 前後空白を除去し、[-+]? ( \d+(\.\d+)? | \.\d+ ) ( [eE][-+]?\d+ )?
        var a = lo
        var b = hi
        while a < b, isSpace(p[a]) { a += 1 }
        while b > a, isSpace(p[b - 1]) { b -= 1 }
        if a >= b { return false }

        var i = a

        // 符号
        if p[i] == 0x2B || p[i] == 0x2D { i += 1 } // + -

        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        var gotDigit = false
        if i < b, p[i] == 0x2E { // .
            i += 1
            let start = i
            while i < b, isDigit(p[i]) { i += 1 }
            if i == start { return false }
            gotDigit = true
        } else {
            let start = i
            while i < b, isDigit(p[i]) { i += 1 }
            if i > start { gotDigit = true }
            if i < b, p[i] == 0x2E {
                i += 1
                while i < b, isDigit(p[i]) { i += 1 }
            }
        }
        if !gotDigit { return false }

        // 指数部
        if i < b, p[i] == 0x65 || p[i] == 0x45 { // e or E
            i += 1
            if i < b, (p[i] == 0x2B || p[i] == 0x2D) { i += 1 }
            let start = i
            while i < b, isDigit(p[i]) { i += 1 }
            if i == start { return false }
        }
        return i == b
    }
}
