//
//  KSyntaxParser.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa
import AppKit

// MARK: - 共有モデル
struct KSyntaxNode {
    let range: Range<Int>
    let kind: KSyntaxKind
}

struct AttributedSpan {
    let range: Range<Int>
    let attributes: [NSAttributedString.Key: Any]
}

enum KSyntaxKind {
    case keyword
    case comment
    case string
    case identifier
    case number
    case punctuation
    case variable        // @var, @@cvar, $global, $1, $!, $_, $$ 等
    case unknown
}

enum KSyntaxType {
    case plain
    case ruby
    case html
}

// MARK: - パーサプロトコル
protocol KSyntaxParserProtocol: AnyObject {
    // TextStorage → Parser 通知
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)
    // 任意：全面パース
    func parse(range: Range<Int>)
    // 描画用：可視範囲の属性スパン（Font は TextStorage 側で合成）
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan]
}

// ショートエイリアス
typealias FC = FuncChar

// MARK: - Ruby パーサ本体
final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // 入力
    private unowned let _storage: KTextStorageReadable
    private var _skeleton: KSkeletonStringInUTF8 { _storage.skeletonString }

    // テーマ（色のみ管理：Font は TextStorage 側）
    private var _stringColor:  NSColor
    private var _commentColor: NSColor
    private var _keywordColor: NSColor
    private var _variableColor: NSColor

    private var _stringAttr:  [NSAttributedString.Key: Any]
    private var _commentAttr: [NSAttributedString.Key: Any]
    private var _keywordAttr: [NSAttributedString.Key: Any]
    private var _variableAttr: [NSAttributedString.Key: Any]

    // 字句テーブル
    private let _identifierSet: Set<UInt8>          // ASCII の識別子集合
    private var _keywordBuckets: [Int: [[UInt8]]]   // 長さ → 候補配列

    // 結果（常時 lowerBound 昇順を維持）
    private var _nodes: [KSyntaxNode] = []
    private var _pendingNodes: [KSyntaxNode] = []
    private let _pendingMergeThreshold = 20_000

    // 変更域（重なりマージ済みの昇順）
    private struct _Dirty {
        private(set) var ranges: [Range<Int>] = []
        mutating func insert(_ r: Range<Int>) {
            guard !r.isEmpty else { return }
            var cur = r
            var out: [Range<Int>] = []
            var placed = false
            for x in ranges {
                if cur.upperBound < x.lowerBound {
                    if !placed { out.append(cur); placed = true }
                    out.append(x)
                } else if x.upperBound < cur.lowerBound {
                    out.append(x)
                } else {
                    cur = min(cur.lowerBound, x.lowerBound)..<max(cur.upperBound, x.upperBound)
                }
            }
            if !placed { out.append(cur) }
            ranges = out
        }
        mutating func takeIntersecting(_ r: Range<Int>) -> [Range<Int>] {
            guard !ranges.isEmpty, !r.isEmpty else { return [] }
            var out: [Range<Int>] = []
            var keep: [Range<Int>] = []
            for x in ranges {
                if x.upperBound <= r.lowerBound || r.upperBound <= x.lowerBound {
                    keep.append(x)
                } else {
                    out.append(x)
                }
            }
            ranges = keep
            return out
        }
        var isEmpty: Bool { ranges.isEmpty }
    }
    private var _dirty = _Dirty()

    // 固定トークン
    private let _kwBegin: [UInt8] = Array("=begin".utf8)
    private let _kwEnd:   [UInt8] = Array("=end".utf8)

    // 初期化
    init(storage: KTextStorageReadable, identifierChars: String, keywords: [String]) {
        _storage = storage

        // 既定色（後で applyTheme で差し替え可）
        let defString  = "#860300".convertToColor() ?? .black
        let defComment = "#0B5A00".convertToColor() ?? .black
        let defKeyword = "#070093".convertToColor() ?? .black
        let defVar     = "#653F00".convertToColor() ?? .darkGray  // ご指定色

        _stringColor  = defString
        _commentColor = defComment
        _keywordColor = defKeyword
        _variableColor = defVar

        _stringAttr   = [.foregroundColor: defString]
        _commentAttr  = [.foregroundColor: defComment]
        _keywordAttr  = [.foregroundColor: defKeyword]
        _variableAttr = [.foregroundColor: defVar]

        _identifierSet = Set(identifierChars.utf8)

        var buckets: [Int: [[UInt8]]] = [:]
        buckets.reserveCapacity(16)
        for s in keywords {
            let w = Array(s.utf8)
            guard !w.isEmpty else { continue }
            buckets[w.count, default: []].append(w)
        }
        _keywordBuckets = buckets
    }

    // テーマ更新
    struct Theme {
        let string: NSColor
        let comment: NSColor
        let keyword: NSColor
        let variable: NSColor?  // 省略時は現状維持
        init(string: NSColor, comment: NSColor, keyword: NSColor, variable: NSColor? = nil) {
            self.string = string; self.comment = comment; self.keyword = keyword; self.variable = variable
        }
    }
    func applyTheme(_ theme: Theme) {
        _stringColor  = theme.string
        _commentColor = theme.comment
        _keywordColor = theme.keyword
        if let v = theme.variable { _variableColor = v }

        _stringAttr   = [.foregroundColor: _stringColor]
        _commentAttr  = [.foregroundColor: _commentColor]
        _keywordAttr  = [.foregroundColor: _keywordColor]
        _variableAttr = [.foregroundColor: _variableColor]
    }

    // キーワード再設定
    @discardableResult
    func resetKeywords(_ keywords: [String]) -> Bool {
        var newBuckets: [Int: [[UInt8]]] = [:]
        newBuckets.reserveCapacity(16)
        for w in keywords {
            let a = Array(w.utf8)
            guard !a.isEmpty else { continue }
            newBuckets[a.count, default: []].append(a)
        }
        if newBuckets != _keywordBuckets {
            _keywordBuckets = newBuckets
            _nodes.removeAll(keepingCapacity: false)
            _dirty = _Dirty()
            return true
        }
        return false
    }

    // MARK: - KSyntaxParserProtocol

    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        // 行境界の揺れ込み対策：左右に 2byte 余裕を持たせる
        let L = max(0, oldRange.lowerBound &- 2)
        let R = min(_storage.count, oldRange.upperBound &+ 2)
        let expanded = L..<R

        let dirtyLines = _skeleton.expandToFullLines(range: expanded)
        _dirty.insert(dirtyLines)

        _invalidatePendingTail(from: dirtyLines.lowerBound)

        let delta = newCount - oldRange.count
        guard delta != 0 else { return }
        _shiftNodes(startingFrom: oldRange.upperBound, by: delta)
    }

    func ensureUpToDate(for range: Range<Int>) {
        let r = _skeleton.expandToFullLines(range: range)

        // まだスキャンしていない領域（on-demand）
        if !_hasOverlap(with: r) {
            let initState = _stateBefore(r.lowerBound)
            _removeNodes(overlapping: r)
            _removePending(overlapping: r)
            let ns = _scan(range: r, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
            _maybeMergePending()
            return
        }

        // 既存 dirty を消化
        let need = _dirty.takeIntersecting(r)
        guard !need.isEmpty else { return }

        for d in need {
            let initState = _stateBefore(d.lowerBound)
            _removeNodes(overlapping: d)
            _removePending(overlapping: d)
            let ns = _scan(range: d, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
        }
        _maybeMergePending()
    }

    func parse(range: Range<Int>) {
        let full = _skeleton.expandToFullLines(range: range)
        _nodes = _scan(range: full, initialState: .neutral)
        _dirty = _Dirty()
    }

    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan] {
        // 範囲内ノード収集（本体＋pending）
        var local: [KSyntaxNode] = []
        if !_nodes.isEmpty {
            let idx = _lowerBoundIndex(ofLowerBound: range.lowerBound)
            var i = max(0, idx - 1)
            while i < _nodes.count, _nodes[i].range.lowerBound < range.upperBound {
                if _nodes[i].range.overlaps(range) { local.append(_nodes[i]) }
                i &+= 1
            }
        }
        if !_pendingNodes.isEmpty {
            for n in _pendingNodes where n.range.overlaps(range) { local.append(n) }
        }
        guard !local.isEmpty else { return [] }

        // 開始位置で安定ソート（同点は長い方を先）
        local.sort {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.range.upperBound > $1.range.upperBound
        }

        // コメント／文字列のマスク（キーワード抑制）
        var masks: [Range<Int>] = []
        for n in local where (n.kind == .comment || n.kind == .string) {
            if let last = masks.last, last.upperBound >= n.range.lowerBound {
                let lo = min(last.lowerBound, n.range.lowerBound)
                let hi = max(last.upperBound, n.range.upperBound)
                masks[masks.count - 1] = lo..<hi
            } else {
                masks.append(n.range)
            }
        }

        var filtered: [KSyntaxNode] = []
    outer:
        for n in local {
            if n.kind == .keyword {
                for m in masks where m.overlaps(n.range) { continue outer }
            }
            filtered.append(n)
        }
        guard !filtered.isEmpty else { return [] }

        // 優先度バケツ：低 → 高（高が後から上書き）
        var low:  [KSyntaxNode] = [] // keyword 等
        var high: [KSyntaxNode] = [] // comment / string / variable（← 文字列より後で上書き）
        for n in filtered {
            switch n.kind {
            case .comment, .string, .variable:
                high.append(n)
            default:
                low.append(n)
            }
        }

        @inline(__always)
        func attrs(for kind: KSyntaxKind) -> [NSAttributedString.Key: Any]? {
            switch kind {
            case .keyword:  return _keywordAttr
            case .comment:  return _commentAttr
            case .string:   return _stringAttr
            case .variable: return _variableAttr   // 既存の変数色（#653F00）を使用
            default:        return nil
            }
        }

        var spans: [AttributedSpan] = []
        spans.reserveCapacity(filtered.count)
        for n in low { if let a = attrs(for: n.kind) { spans.append(.init(range: n.range, attributes: a)) } }
        for n in high { if let a = attrs(for: n.kind) { spans.append(.init(range: n.range, attributes: a)) } }
        return spans
    }

    // MARK: - 内部：状態・ノード操作

    private enum _ParserState {
        case neutral
        case inLineComment
        case inMultiComment
        case inString(quote: UInt8)
        case inHereDoc(id: [UInt8])
        case inRegex(open: UInt8, close: UInt8)  // %r 任意デリミタ用
    }

    // pos-1 を含むノードで文脈復元（コメント/文字列内なら継続開始）
    // 置き換え版：直近の行頭アンカー(=begin/=end)を後方スキャンして文脈復元
    @inline(__always)
    private func _stateBefore(_ pos: Int) -> _ParserState {
        // まず既存ノードからの復元（あれば最速）
        let p = max(0, pos - 1)
        if !_nodes.isEmpty {
            let idx = _lowerBoundIndex(ofLowerBound: p)
            var i = max(0, idx - 1)
            while i < _nodes.count, _nodes[i].range.lowerBound <= p {
                let n = _nodes[i]
                if n.range.contains(p) {
                    switch n.kind {
                    case .comment: return .inMultiComment
                    case .string:  return .inString(quote: 0)
                    default: break
                    }
                }
                i &+= 1
            }
        }
        if !_pendingNodes.isEmpty {
            if let n = _pendingNodes.first(where: { $0.range.contains(p) }) {
                switch n.kind {
                case .comment: return .inMultiComment
                case .string:  return .inString(quote: 0)
                default: break
                }
            }
        }

        // --- ノードに文脈が無い場合：スケルトンを使って後方の行頭アンカーを探索 ---
        // 後方に最大 backBytes だけ遡って行単位で見る（必要なら増やして下さい）
        let backBytes = 64_000
        let start = max(0, pos - backBytes)
        let window = _skeleton.expandToFullLines(range: start..<pos)
        guard window.lowerBound < window.upperBound else { return .neutral }

        let bytes = _skeleton.bytes(in: window)
        let E = bytes.endIndex

        // 行頭へ移動する小ヘルパ
        @inline(__always)
        func firstNonSpaceAtLineStart(_ at: Int) -> Int {
            var s = at
            if !(s == bytes.startIndex || bytes[s - 1] == FC.lf) {
                var j = s &- 1
                while j >= bytes.startIndex && bytes[j] != FC.lf { j &-= 1 }
                s = (j < bytes.startIndex) ? bytes.startIndex : j &+ 1
            }
            while s < E, (bytes[s] == FC.space || bytes[s] == FC.tab) { s &+= 1 }
            return s
        }
        @inline(__always)
        func match(_ at: Int, ascii: [UInt8]) -> Bool {
            let end = at &+ ascii.count
            return end <= E && bytes[at..<end].elementsEqual(ascii)
        }

        // 行単位で後方から走査し、=begin/=end の対応関係を見る
        // 直近で「=begin が未クローズ」の状態なら inMulti と判定
        var k = E - 1
        var balance = 0  // =end を見たら +1、=begin を見たら -1 として積み上げ
        while k >= bytes.startIndex {
            // その行の先頭（空白スキップ後）
            let head = firstNonSpaceAtLineStart(k)

            if head < E {
                if match(head, ascii: _kwEnd) {
                    balance &+= 1
                } else if match(head, ascii: _kwBegin) {
                    if balance == 0 {
                        // 直近に未クローズの =begin がある → いまは複数行コメント内
                        return .inMultiComment
                    } else {
                        balance &-= 1
                    }
                }
            }

            // 前の行へ
            if head == bytes.startIndex { break }
            var j = head &- 1
            while j >= bytes.startIndex && bytes[j] != FC.lf { j &-= 1 }
            if j < bytes.startIndex { break }
            k = j
        }

        return .neutral
    }

    // 範囲に重なる既存ノードを削除（二分探索で局所に限定）
    private func _removeNodes(overlapping rng: Range<Int>) {
        guard !_nodes.isEmpty else { return }
        var lo = _nodes.startIndex, hi = _nodes.endIndex
        while lo < hi {
            let m = (lo + hi) >> 1
            if _nodes[m].range.upperBound > rng.lowerBound { hi = m } else { lo = m &+ 1 }
        }
        let start = lo
        lo = start; hi = _nodes.endIndex
        while lo < hi {
            let m = (lo + hi) >> 1
            if _nodes[m].range.lowerBound < rng.upperBound { lo = m &+ 1 } else { hi = m }
        }
        if start < lo { _nodes.removeSubrange(start..<lo) }
    }

    @inline(__always)
    private func _removePending(overlapping r: Range<Int>) {
        guard !_pendingNodes.isEmpty else { return }
        _pendingNodes.removeAll { $0.range.overlaps(r) }
    }

    // cut 以降のノードを座標シフト
    private func _shiftNodes(startingFrom cut: Int, by delta: Int) {
        guard delta != 0 else { return }
        if !_nodes.isEmpty {
            let idx = _lowerBoundIndex(ofLowerBound: cut)
            if idx < _nodes.count {
                for i in idx..<_nodes.count {
                    let r = _nodes[i].range
                    _nodes[i] = .init(range: (r.lowerBound + delta)..<(r.upperBound + delta), kind: _nodes[i].kind)
                }
            }
        }
        if !_pendingNodes.isEmpty {
            for i in 0..<_pendingNodes.count {
                let r = _pendingNodes[i].range
                if r.lowerBound >= cut {
                    _pendingNodes[i] = .init(range: (r.lowerBound + delta)..<(r.upperBound + delta), kind: _pendingNodes[i].kind)
                }
            }
        }
    }

    // 一定件数貯まったら本体に統合
    @inline(__always)
    private func _maybeMergePending() {
        guard _pendingNodes.count >= _pendingMergeThreshold else { return }
        _pendingNodes.sort { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [KSyntaxNode] = []
        merged.reserveCapacity(_nodes.count + _pendingNodes.count)

        var i = 0, j = 0
        while i < _nodes.count || j < _pendingNodes.count {
            let fromPending: Bool
            if i == _nodes.count { fromPending = true }
            else if j == _pendingNodes.count { fromPending = false }
            else { fromPending = _pendingNodes[j].range.lowerBound < _nodes[i].range.lowerBound }

            let n = fromPending ? _pendingNodes[j] : _nodes[i]
            if let last = merged.last,
               last.kind == n.kind,
               last.range.upperBound == n.range.lowerBound {
                merged[merged.count - 1] = .init(range: last.range.lowerBound..<n.range.upperBound, kind: last.kind)
            } else {
                merged.append(n)
            }
            if fromPending { j &+= 1 } else { i &+= 1 }
        }
        _nodes = merged
        _pendingNodes.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    private func _invalidatePendingTail(from cut: Int) {
        guard !_pendingNodes.isEmpty else { return }
        _pendingNodes.removeAll { $0.range.lowerBound >= cut }
        _dirty.insert(cut..<_storage.count)
    }

    // 下限に対する lower_bound（二分探索）
    @inline(__always)
    private func _lowerBoundIndex(ofLowerBound value: Int) -> Int {
        var low = 0
        var high = _nodes.count
        while low < high {
            let mid = (low + high) >> 1
            if _nodes[mid].range.lowerBound >= value { high = mid }
            else { low = mid &+ 1 }
        }
        return low
    }

    // 既存ノードの重なり有無（高速判定）
    @inline(__always)
    private func _hasOverlap(with r: Range<Int>) -> Bool {
        guard !_nodes.isEmpty else { return false }
        var lo = 0, hi = _nodes.count
        while lo < hi {
            let m = (lo + hi) >> 1
            if _nodes[m].range.upperBound > r.lowerBound { hi = m } else { lo = m &+ 1 }
        }
        if lo >= _nodes.count { return false }
        return _nodes[lo].range.lowerBound < r.upperBound
    }

    // MARK: - スキャナ本体

    @inline(__always) private func _isAsciiAlphaNum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }
    @inline(__always) private func _isAsciiSpace(_ b: UInt8) -> Bool {
        b == FC.space || b == FC.tab || b == FC.lf
    }

    // %r / %R のデリミタ判定（英数字・空白以外の1文字。括弧は対応ペア）
    @inline(__always)
    private func _regexDelims(after rPos: Int, in bytes: ArraySlice<UInt8>) -> (open: UInt8, close: UInt8, next: Int)? {
        let E = bytes.endIndex
        let dPos = rPos &+ 1
        guard dPos < E else { return nil }
        let d = bytes[dPos]
        guard !_isAsciiAlphaNum(d), !_isAsciiSpace(d) else { return nil }
        switch d {
        case UInt8(ascii: "("): return (d, UInt8(ascii: ")"), dPos &+ 1)
        case UInt8(ascii: "{"): return (d, UInt8(ascii: "}"), dPos &+ 1)
        case UInt8(ascii: "["): return (d, UInt8(ascii: "]"), dPos &+ 1)
        case UInt8(ascii: "<"): return (d, UInt8(ascii: ">"), dPos &+ 1)
        default:                return (d, d,               dPos &+ 1)
        }
    }

    // MARK: - スキャナ本体（差し替え用・完全版）
    // MARK: - スキャナ本体（埋め込み変数対応版・メソッド丸ごと差し替え）
    private func _scan(range: Range<Int>, initialState: _ParserState) -> [KSyntaxNode] {
        var out: [KSyntaxNode] = []
        out.reserveCapacity(128)

        let full = _skeleton.expandToFullLines(range: range)
        guard full.lowerBound < full.upperBound else { return out }

        let bytes = _skeleton.bytes(in: full)
        let E = bytes.endIndex

        @inline(__always)
        func _match(_ at: Int, ascii: [UInt8]) -> Bool {
            let end = at &+ ascii.count
            return end <= E && bytes[at..<end].elementsEqual(ascii)
        }
        @inline(__always)
        func _firstNonSpaceAtLineStart(_ at: Int) -> Int {
            var s = at
            if !(s == bytes.startIndex || bytes[s - 1] == FC.lf) {
                var j = s &- 1
                while j >= bytes.startIndex && bytes[j] != FC.lf { j &-= 1 }
                s = (j < bytes.startIndex) ? bytes.startIndex : j &+ 1
            }
            while s < E, (bytes[s] == FC.space || bytes[s] == FC.tab) { s &+= 1 }
            return s
        }
        @inline(__always)
        func _lineEndExcludingLF(from i: Int) -> Int {
            var j = i
            while j < E, bytes[j] != FC.lf { j &+= 1 }
            return j
        }
        @inline(__always)
        func _isAsciiAlphaNum(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        @inline(__always)
        func _isAsciiSpace(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab || b == FC.lf }

        @inline(__always)
        func _regexDelims(after rPos: Int) -> (open: UInt8, close: UInt8, next: Int)? {
            let dPos = rPos &+ 1
            guard dPos < E else { return nil }
            let d = bytes[dPos]
            guard !_isAsciiAlphaNum(d), !_isAsciiSpace(d) else { return nil }
            switch d {
            case UInt8(ascii: "("): return (d, UInt8(ascii: ")"), dPos &+ 1)
            case UInt8(ascii: "{"): return (d, UInt8(ascii: "}"), dPos &+ 1)
            case UInt8(ascii: "["): return (d, UInt8(ascii: "]"), dPos &+ 1)
            case UInt8(ascii: "<"): return (d, UInt8(ascii: ">"), dPos &+ 1)
            default:                return (d, d,               dPos &+ 1)
            }
        }

        // 直ちに絶対座標へ変換してノード追加
        var spanStart = -1
        @inline(__always) func _open(_ at: Int) { spanStart = at }
        @inline(__always) func _close(_ kind: KSyntaxKind, _ at: Int) {
            if spanStart >= 0 {
                let abs = (full.lowerBound + (spanStart - bytes.startIndex))..<(full.lowerBound + (at - bytes.startIndex))
                out.append(.init(range: abs, kind: kind))
            }
            spanStart = -1
        }

        // 状態復元
        var inMulti = false, inHere = false, inLine = false, inStr = false, inRx = false
        var hereId: ArraySlice<UInt8> = []
        var quote: UInt8 = 0, escaped = false
        var rxClose: UInt8 = 0
        switch initialState {
        case .neutral: break
        case .inLineComment: inLine = true; _open(bytes.startIndex)
        case .inMultiComment: inMulti = true; _open(bytes.startIndex)
        case .inString(let q): inStr = true; quote = q; _open(bytes.startIndex)
        case .inHereDoc(let id): inHere = true; hereId = ArraySlice(id); _open(bytes.startIndex)
        case .inRegex(_, let c): inRx = true; rxClose = c; _open(bytes.startIndex)
        }

        let kwBegin = _kwBegin, kwEnd = _kwEnd

        // 文字列内の #{ ... } で変数を拾う
        @inline(__always)
        func _scanInterpolationVariables(start jStart: Int) -> Int {
            var j = jStart         // `#{` の直後から
            var depth = 1
            while j < E {
                let c = bytes[j]
                // エスケープ
                if c == FC.backSlash, j &+ 1 < E { j &+= 2; continue }
                // 入れ子
                if c == UInt8(ascii: "{") { depth &+= 1; j &+= 1; continue }
                if c == UInt8(ascii: "}") {
                    depth &-= 1; j &+= 1
                    if depth == 0 { break }
                    continue
                }

                // 変数検出（@@ / @ / $...）
                if c == UInt8(ascii: "@") {
                    let start = j
                    var k = j &+ 1
                    if k < E, bytes[k] == UInt8(ascii: "@") { k &+= 1 } // @@
                    if k < E, _identifierSet.contains(bytes[k]) {
                        repeat { k &+= 1 } while k < E && _identifierSet.contains(bytes[k])
                        // ノード追加（絶対座標）
                        let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (k - bytes.startIndex))
                        out.append(.init(range: abs, kind: .variable))
                        j = k; continue
                    }
                } else if c == UInt8(ascii: "$") {
                    let start = j
                    var k = j &+ 1
                    if k < E {
                        let d = bytes[k]
                        if d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") {
                            repeat { k &+= 1 } while k < E && (bytes[k] >= UInt8(ascii: "0") && bytes[k] <= UInt8(ascii: "9"))
                            let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (k - bytes.startIndex))
                            out.append(.init(range: abs, kind: .variable))
                            j = k; continue
                        }
                        let specials: Set<UInt8> = [
                            UInt8(ascii: "~"), UInt8(ascii: "!"), UInt8(ascii: "?"), UInt8(ascii: "/"),
                            UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "`"), UInt8(ascii: "'"),
                            UInt8(ascii: "_"), UInt8(ascii: "$")
                        ]
                        if specials.contains(d) {
                            k &+= 1
                            let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (k - bytes.startIndex))
                            out.append(.init(range: abs, kind: .variable))
                            j = k; continue
                        }
                        if _identifierSet.contains(d) {
                            repeat { k &+= 1 } while k < E && _identifierSet.contains(bytes[k])
                            let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (k - bytes.startIndex))
                            out.append(.init(range: abs, kind: .variable))
                            j = k; continue
                        }
                    }
                }

                j &+= 1
            }
            return j // 閉じ '}' の次位置（または E）
        }

        var i = bytes.startIndex
        while i < E {
            let b = bytes[i]

            // ===== 内部状態 =====
            if inMulti {
                let j0 = _firstNonSpaceAtLineStart(i)
                if j0 == i, _match(j0, ascii: kwEnd) {
                    let endL = _lineEndExcludingLF(from: i)
                    _close(.comment, endL)
                    inMulti = false
                    i = (endL < E && bytes[endL] == FC.lf) ? endL &+ 1 : endL
                    continue
                }
                i &+= 1; continue
            }
            if inHere {
                let j0 = _firstNonSpaceAtLineStart(i)
                if j0 == i, !hereId.isEmpty,
                   i &+ hereId.count <= E,
                   bytes[i..<(i + hereId.count)].elementsEqual(hereId) {
                    var j = _lineEndExcludingLF(from: i)
                    if j < E { j &+= 1 } // LF を含める
                    _close(.string, j)
                    inHere = false; hereId = []
                    i = j; continue
                }
                i &+= 1; continue
            }
            if inLine {
                if b == FC.lf { _close(.comment, i); inLine = false }
                i &+= 1; continue
            }
            if inStr {
                // 文字列中：#{ ... } の変数色分け（"..." のみ。'...' や /.../ は対象外）
                if quote == FC.doubleQuote, b == UInt8(ascii: "#"), i &+ 1 < E, bytes[i &+ 1] == UInt8(ascii: "{") {
                    let jAfter = _scanInterpolationVariables(start: i &+ 2)
                    i = jAfter
                    continue
                }
                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == quote { _close(.string, i &+ 1); inStr = false; i &+= 1; continue }
                i &+= 1; continue
            }
            if inRx {
                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == rxClose {
                    var j = i &+ 1
                    while j < E && _isAsciiAlphaNum(bytes[j]) { j &+= 1 } // フラグ
                    _close(.string, j)
                    inRx = false
                    i = j; continue
                }
                i &+= 1; continue
            }

            // ===== オープニング =====
            let j0 = _firstNonSpaceAtLineStart(i)

            // =begin → 前方 =end 探索して一括ノード化（見つからねば inMulti 開始）
            if j0 == i, _match(j0, ascii: _kwBegin) {
                var head = i
                if !(head == bytes.startIndex || bytes[head - 1] == FC.lf) {
                    var p = head &- 1
                    while p >= bytes.startIndex && bytes[p] != FC.lf { p &-= 1 }
                    head = (p < bytes.startIndex) ? bytes.startIndex : p &+ 1
                }
                var k = i
                var closedAt: Int? = nil
                while k < E {
                    while k < E, bytes[k] != FC.lf { k &+= 1 }
                    if k < E { k &+= 1 } else { break }
                    if k >= E { break }
                    let s = _firstNonSpaceAtLineStart(k)
                    if s == k, _match(s, ascii: _kwEnd) {
                        let endL = _lineEndExcludingLF(from: k)
                        let abs = (full.lowerBound + (head - bytes.startIndex))..<(full.lowerBound + (endL - bytes.startIndex))
                        out.append(.init(range: abs, kind: .comment))
                        i = (endL < E && bytes[endL] == FC.lf) ? endL &+ 1 : endL
                        closedAt = i
                        break
                    }
                }
                if closedAt != nil { continue }
                _open(head); inMulti = true; i &+= 1; continue
            }

            // 行頭の =end 単独塗り（ブロック外れ対策）
            if j0 == i, _match(j0, ascii: _kwEnd) {
                var head = i
                if !(head == bytes.startIndex || bytes[head - 1] == FC.lf) {
                    var p = head &- 1
                    while p >= bytes.startIndex && bytes[p] != FC.lf { p &-= 1 }
                    head = (p < bytes.startIndex) ? bytes.startIndex : p &+ 1
                }
                let endL = _lineEndExcludingLF(from: i)
                let abs = (full.lowerBound + (head - bytes.startIndex))..<(full.lowerBound + (endL - bytes.startIndex))
                out.append(.init(range: abs, kind: .comment))
                i = (endL < E && bytes[endL] == FC.lf) ? endL &+ 1 : endL
                continue
            }

            // ヒアドキュメント
            if b == FC.lt, i &+ 1 < E, bytes[i + 1] == FC.lt {
                var j = i &+ 2
                if j < E, (bytes[j] == FC.minus || bytes[j] == FC.tilde) { j &+= 1 }
                var idStart = j, idEnd = j
                var ok = false
                if j < E, (bytes[j] == FC.singleQuote || bytes[j] == FC.doubleQuote) {
                    let q = bytes[j]; j &+= 1; idStart = j
                    while j < E && bytes[j] != q { j &+= 1 }
                    if j < E { idEnd = j; j &+= 1; ok = (idEnd > idStart) }
                } else {
                    while j < E && _identifierSet.contains(bytes[j]) { j &+= 1 }
                    idEnd = j; ok = (idEnd > idStart)
                }
                if ok {
                    while j < E, bytes[j] != FC.lf { j &+= 1 }
                    let body = (j < E) ? (j &+ 1) : j
                    _open(i); inHere = true; hereId = bytes[idStart..<idEnd]
                    i = body; continue
                }
            }

            // 行コメント
            if b == UInt8(ascii: "#") {
                _open(i); inLine = true; i &+= 1; continue
            }

            // /.../ 正規表現
            if b == FC.slash {
                _open(i); inStr = true; quote = FC.slash; i &+= 1; continue
            }

            // '...' / "..."
            if b == FC.doubleQuote || b == FC.singleQuote {
                _open(i); inStr = true; quote = b; i &+= 1; continue
            }

            // %r / %R
            if b == FC.percent, i &+ 2 < E {
                let rch = bytes[i &+ 1]
                if rch == UInt8(ascii: "r") || rch == UInt8(ascii: "R"),
                   let (_, cl, next) = _regexDelims(after: i &+ 1) {
                    _open(i); inRx = true; rxClose = cl
                    i = next; continue
                }
            }

            // 変数（@ / @@）
            if b == UInt8(ascii: "@") {
                let start = i
                var j = i &+ 1
                if j < E, bytes[j] == UInt8(ascii: "@") { j &+= 1 }
                if j < E, _identifierSet.contains(bytes[j]) {
                    repeat { j &+= 1 } while j < E && _identifierSet.contains(bytes[j])
                    let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (j - bytes.startIndex))
                    out.append(.init(range: abs, kind: .variable))
                    i = j; continue
                }
            }

            // 変数（$...）
            if b == UInt8(ascii: "$"), i &+ 1 < E {
                let start = i
                var j = i &+ 1
                let c = bytes[j]
                if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                    repeat { j &+= 1 } while j < E && (bytes[j] >= UInt8(ascii: "0") && bytes[j] <= UInt8(ascii: "9"))
                    let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (j - bytes.startIndex))
                    out.append(.init(range: abs, kind: .variable))
                    i = j; continue
                }
                let specials: Set<UInt8> = [
                    UInt8(ascii: "~"), UInt8(ascii: "!"), UInt8(ascii: "?"), UInt8(ascii: "/"),
                    UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "`"), UInt8(ascii: "'"),
                    UInt8(ascii: "_"), UInt8(ascii: "$")
                ]
                if specials.contains(c) {
                    j &+= 1
                    let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (j - bytes.startIndex))
                    out.append(.init(range: abs, kind: .variable))
                    i = j; continue
                }
                if _identifierSet.contains(c) {
                    repeat { j &+= 1 } while j < E && _identifierSet.contains(bytes[j])
                    let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (j - bytes.startIndex))
                    out.append(.init(range: abs, kind: .variable))
                    i = j; continue
                }
            }

            // キーワード
            if _identifierSet.contains(b) {
                let start = i
                var j = i &+ 1
                while j < E && _identifierSet.contains(bytes[j]) { j &+= 1 }
                let len = j - start
                if let bucket = _keywordBuckets[len] {
                    let slice = bytes[start..<j]
                    if bucket.contains(where: { slice.elementsEqual($0) }) {
                        let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (j - bytes.startIndex))
                        out.append(.init(range: abs, kind: .keyword))
                    }
                }
                i = j; continue
            }

            i &+= 1
        }

        if inMulti { _close(.comment, E) }
        if inHere  { _close(.string,  E) }
        if inLine  { _close(.comment, E) }
        if inStr   { _close(.string,  E) }
        if inRx    { _close(.string,  E) }

        return out
    }
}
