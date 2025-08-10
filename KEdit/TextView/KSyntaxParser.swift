//
//  KSyntaxParser.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa
import AppKit

// ==== Shared models (既存と同名で想定) ====
struct KSyntaxNode {
    let range: Range<Int>
    let kind: KSyntaxKind
}
struct AttributedSpan {
    let range: Range<Int>
    let attributes: [NSAttributedString.Key: Any]
}
enum KSyntaxKind {
    case keyword, comment, string, identifier, number, punctuation, unknown
}
enum KSyntaxType { case plain, ruby, html }

// ==== Parser protocol ====
protocol KSyntaxParserProtocol: AnyObject {
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)
    func parse(range: Range<Int>)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan]
}

// Short alias
typealias FC = FuncChar

// MARK: - Ruby Parser
final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // MARK: Inputs
    private unowned let _storage: KTextStorageReadable
    private var _skeleton: KSkeletonStringInUTF8 { _storage.skeletonString }

    // MARK: Theme (colors only)
    private var _stringColor:  NSColor
    private var _commentColor: NSColor
    private var _keywordColor: NSColor
    private var _stringAttr:  [NSAttributedString.Key: Any]
    private var _commentAttr: [NSAttributedString.Key: Any]
    private var _keywordAttr: [NSAttributedString.Key: Any]

    // MARK: Lexer tables
    private let _identifierSet: Set<UInt8>        // ASCII set for identifiers
    private var _keywordBuckets: [Int: [[UInt8]]] // length -> words

    // MARK: Results (global node store; lowerBound 昇順)
    private var _nodes: [KSyntaxNode] = []
    private var _pendingNodes: [KSyntaxNode] = []
    private let _pendingMergeThreshold = 20_000   // 閾値超で一度だけ重いマージ

    // MARK: Dirty (line-based, merged)
    private struct _Dirty {
        private(set) var ranges: [Range<Int>] = [] // non-overlapping, ascending
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
            guard !r.isEmpty, !ranges.isEmpty else { return [] }
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

    // MARK: Fixed tokens
    private let _kwBegin: [UInt8] = Array("=begin".utf8)
    private let _kwEnd:   [UInt8] = Array("=end".utf8)

    // MARK: Init
    init(storage: KTextStorageReadable, identifierChars: String, keywords: [String]) {
        self._storage = storage

        // default colors (可変)
        let defString  = "#860300".convertToColor() ?? .black
        let defComment = "#0B5A00".convertToColor() ?? .black
        let defKeyword = "#070093".convertToColor() ?? .black
        _stringColor  = defString
        _commentColor = defComment
        _keywordColor = defKeyword
        _stringAttr   = [.foregroundColor: defString]
        _commentAttr  = [.foregroundColor: defComment]
        _keywordAttr  = [.foregroundColor: defKeyword]

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

    // MARK: Theme/keywords public
    struct Theme {
        let string: NSColor, comment: NSColor, keyword: NSColor
        init(string: NSColor, comment: NSColor, keyword: NSColor) {
            self.string = string; self.comment = comment; self.keyword = keyword
        }
    }
    func applyTheme(_ theme: Theme) {
        _stringColor  = theme.string
        _commentColor = theme.comment
        _keywordColor = theme.keyword
        _stringAttr   = [.foregroundColor: _stringColor]
        _commentAttr  = [.foregroundColor: _commentColor]
        _keywordAttr  = [.foregroundColor: _keywordColor]
    }
    @discardableResult
    func resetKeywords(_ keywords: [String]) -> Bool {
        var newBuckets: [Int: [[UInt8]]] = [:]
        newBuckets.reserveCapacity(16)
        for w in keywords {
            let a = Array(w.utf8); guard !a.isEmpty else { continue }
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

    // MARK: KSyntaxParserProtocol (TextStorage からの 2 窓)
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        let dirtyLines = _skeleton.expandToFullLines(range: oldRange)
        _dirty.insert(dirtyLines)

        _invalidatePendingTail(from: dirtyLines.lowerBound)

        let delta = newCount - oldRange.count
        guard delta != 0 else { return }
        _shiftNodes(startingFrom: oldRange.upperBound, by: delta)
    }

    func ensureUpToDate(for range: Range<Int>) {
        let r = _skeleton.expandToFullLines(range: range)

        // --- on-demand: 未カバー ---
        if !_hasOverlap(with: r) {
            let initState = _stateBefore(r.lowerBound)   // 先に文脈を拾う
            _removeNodes(overlapping: r)                 // それから古いのを落とす
            _removePending(overlapping: r)
            let ns = _scan(range: r, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
            _maybeMergePending()
            return
        }

        // --- dirty 消化 ---
        let need = _dirty.takeIntersecting(r)
        guard !need.isEmpty else { return }

        for d in need {
            let initState = _stateBefore(d.lowerBound)   // 先に文脈
            _removeNodes(overlapping: d)                 // その後で除去
            _removePending(overlapping: d)

            let ns = _scan(range: d, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
        }
        _maybeMergePending()
    }

    // 任意：全面パース（必要な場面のみ）
    func parse(range: Range<Int>) {
        let full = _skeleton.expandToFullLines(range: range)
        _nodes = _scan(range: full, initialState: .neutral)
        _dirty = _Dirty()
    }

    // Painter 用：可視範囲の属性を返す（Font は TextStorage 側）
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan] {
        // 1) collect local nodes (main + pending)
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

        // 2) sort by start (stable; longer first on ties)
        local.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        // 3) build masks (comment/string dominate)
        var masks: [Range<Int>] = []
        masks.reserveCapacity(local.count / 2)
        for n in local where (n.kind == .comment || n.kind == .string) {
            if let last = masks.last, last.upperBound >= n.range.lowerBound {
                let lo = min(last.lowerBound, n.range.lowerBound)
                let hi = max(last.upperBound, n.range.upperBound)
                masks[masks.count - 1] = lo..<hi
            } else {
                masks.append(n.range)
            }
        }

        // 4) filter keywords covered by masks
        var filtered: [KSyntaxNode] = []
        filtered.reserveCapacity(local.count)
    outer:
        for n in local {
            if n.kind == .keyword {
                for m in masks where m.overlaps(n.range) { continue outer }
            }
            filtered.append(n)
        }
        guard !filtered.isEmpty else { return [] }

        // 5) priority buckets: low -> high (apply high last to override)
        var low:  [KSyntaxNode] = [] // identifiers, numbers, punctuation, keyword(残り)
        var high: [KSyntaxNode] = [] // comment, string
        low.reserveCapacity(filtered.count)
        high.reserveCapacity(filtered.count)

        for n in filtered {
            switch n.kind {
            case .comment, .string:
                high.append(n)
            default:
                low.append(n)
            }
        }

        // 6) convert to AttributedSpan (low first, then high to override)
        @inline(__always)
        func attrs(for kind: KSyntaxKind) -> [NSAttributedString.Key: Any]? {
            switch kind {
            case .keyword: return _keywordAttr
            case .comment: return _commentAttr
            case .string:  return _stringAttr
            default:       return nil
            }
        }

        var spans: [AttributedSpan] = []
        spans.reserveCapacity(filtered.count)

        for n in low {
            if let a = attrs(for: n.kind) {
                spans.append(.init(range: n.range, attributes: a))
            }
        }
        for n in high {
            if let a = attrs(for: n.kind) {
                spans.append(.init(range: n.range, attributes: a))
            }
        }
        return spans
    }

    // MARK: Private: state + nodes ops
    private enum _ParserState {
        case neutral
        case inLineComment
        case inMultiComment
        case inString(quote: UInt8)
        case inHereDoc(id: [UInt8])
    }

    // 文脈復元：pos-1 を含む既存ノード（main/pending）を探し、コメント・文字列中ならその状態で開始
    @inline(__always)
    private func _stateBefore(_ pos: Int) -> _ParserState {
        let p = max(0, pos - 1)
        var hit: KSyntaxNode?

        if !_nodes.isEmpty {
            let idx = _lowerBoundIndex(ofLowerBound: p)   // lowerBound >= p の最初
            var i = max(0, idx - 1)                       // 左隣も確認
            while i < _nodes.count, _nodes[i].range.lowerBound <= p {
                let n = _nodes[i]
                if n.range.contains(p) { hit = n; break }
                i &+= 1
            }
        }
        if hit == nil, !_pendingNodes.isEmpty {
            if let n = _pendingNodes.first(where: { $0.range.contains(p) }) {
                hit = n
            }
        }

        guard let n = hit else { return .neutral }
        switch n.kind {
        case .comment: return .inMultiComment
        case .string:  return .inString(quote: 0)
        default:       return .neutral
        }
    }

    private func _removeNodes(overlapping rng: Range<Int>) {
        guard !_nodes.isEmpty else { return }
        // first with upper > rng.lower
        var lo = _nodes.startIndex, hi = _nodes.endIndex
        while lo < hi {
            let m = (lo + hi) >> 1
            if _nodes[m].range.upperBound > rng.lowerBound { hi = m } else { lo = m &+ 1 }
        }
        let start = lo
        // first with lower >= rng.upper
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

    private func _shiftNodes(startingFrom cut: Int, by delta: Int) {
        guard delta != 0, !_nodes.isEmpty else { return }
        let idx = _lowerBoundIndex(ofLowerBound: cut)
        if idx < _nodes.count {
            for i in idx..<_nodes.count {
                let r = _nodes[i].range
                _nodes[i] = .init(range: (r.lowerBound + delta)..<(r.upperBound + delta),
                                  kind: _nodes[i].kind)
            }
        }
        // pending も座標を合わせる（件数少・線形で十分）
        if !_pendingNodes.isEmpty {
            for i in 0..<_pendingNodes.count {
                let r = _pendingNodes[i].range
                if r.lowerBound >= cut {
                    _pendingNodes[i] = .init(range: (r.lowerBound + delta)..<(r.upperBound + delta),
                                             kind: _pendingNodes[i].kind)
                }
            }
        }
    }

    // news は昇順（_scan が昇順で返す前提）
    private func _insertAndCoalesce(_ news: [KSyntaxNode]) {
        guard !news.isEmpty else { return }
        let at = _lowerBoundIndex(ofLowerBound: news[0].range.lowerBound)
        _nodes.insert(contentsOf: news, at: at)
        var i = max(at - 1, 0)
        while i + 1 < _nodes.count {
            let left  = _nodes[i]
            let right = _nodes[i + 1]
            if left.kind == right.kind,
               left.range.upperBound == right.range.lowerBound {
                _nodes[i] = .init(range: left.range.lowerBound..<right.range.upperBound, kind: left.kind)
                _nodes.remove(at: i + 1)
            } else {
                if i >= at + news.count { break }
                i += 1
            }
        }
    }

    // MARK: Private: local scanner (returns nodes; does not touch _nodes)
    private func _scan(range: Range<Int>, initialState: _ParserState) -> [KSyntaxNode] {
        var nodes: [KSyntaxNode] = []
        nodes.reserveCapacity(128)

        let full = _skeleton.expandToFullLines(range: range)
        guard full.lowerBound < full.upperBound else { return nodes }

        let bytes = _skeleton.bytes(in: full)
        let E = bytes.endIndex

        @inline(__always) func _match(_ at: Int, ascii: [UInt8]) -> Bool {
            let end = at &+ ascii.count
            return end <= E && bytes[at..<end].elementsEqual(ascii)
        }
        @inline(__always) func _firstNonSpaceAtLineStart(_ at: Int) -> Int {
            var s = at
            if !(s == bytes.startIndex || bytes[s - 1] == FC.lf) {
                var j = s &- 1
                while j >= bytes.startIndex && bytes[j] != FC.lf { j &-= 1 }
                s = (j < bytes.startIndex) ? bytes.startIndex : j &+ 1
            }
            while s < E, (bytes[s] == FC.space || bytes[s] == FC.tab) { s &+= 1 }
            return s
        }
        @inline(__always) func _lineEndExcludingLF(from i: Int) -> Int {
            var j = i
            while j < E, bytes[j] != FC.lf { j &+= 1 }
            return j
        }
        // span helpers (absolute rangesを直接生成)
        var spanStart = -1
        @inline(__always) func _open(_ at: Int) { spanStart = at }
        @inline(__always) func _close(_ kind: KSyntaxKind, _ at: Int) {
            if spanStart >= 0 {
                let abs = (full.lowerBound + (spanStart - bytes.startIndex))..<(full.lowerBound + (at - bytes.startIndex))
                nodes.append(.init(range: abs, kind: kind))
            }
            spanStart = -1
        }

        // restore flags
        var inMulti = false, inHere = false, inLine = false, inStr = false
        var hereId: ArraySlice<UInt8> = []
        var quote: UInt8 = 0, escaped = false
        switch initialState {
        case .neutral: break
        case .inLineComment:
            inLine = true; _open(bytes.startIndex)
        case .inMultiComment:
            inMulti = true; _open(bytes.startIndex)
        case .inString(let q):
            inStr = true; quote = q; _open(bytes.startIndex)
        case .inHereDoc(let id):
            inHere = true; hereId = ArraySlice(id); _open(bytes.startIndex)
        }

        let kwBegin = _kwBegin, kwEnd = _kwEnd
        var i = bytes.startIndex
        while i < E {
            let b = bytes[i]

            // inside
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
                    if j < E { j &+= 1 }
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
                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == quote { _close(.string, i &+ 1); inStr = false; i &+= 1; continue }
                i &+= 1; continue
            }

            // openings
            let j0 = _firstNonSpaceAtLineStart(i)

            if j0 == i, _match(j0, ascii: kwBegin) {
                // include marker line
                var head = i
                if !(head == bytes.startIndex || bytes[head - 1] == FC.lf) {
                    var p = head &- 1
                    while p >= bytes.startIndex && bytes[p] != FC.lf { p &-= 1 }
                    head = (p < bytes.startIndex) ? bytes.startIndex : p &+ 1
                }
                _open(head); inMulti = true; i &+= 1; continue
            }

            // heredoc start (<<, <<-, <<~) with optional quoted ID
            if b == FC.lt, i &+ 1 < E, bytes[i + 1] == FC.lt {
                var j = i &+ 2
                if j < E, (bytes[j] == FC.minus || bytes[j] == FC.tilde) { j &+= 1 }
                var idStart = j, idEnd = j
                var ok = false
                if j < E, (bytes[j] == FC.singleQuote || bytes[j] == FC.doubleQuote) {
                    let q = bytes[j]; j &+= 1; idStart = j
                    while j < E, bytes[j] != q { j &+= 1 }
                    if j < E { idEnd = j; j &+= 1; ok = (idEnd > idStart) }
                } else {
                    while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
                    idEnd = j; ok = (idEnd > idStart)
                }
                if ok {
                    while j < E, bytes[j] != FC.lf { j &+= 1 }
                    let body = (j < E) ? (j &+ 1) : j
                    _open(i); inHere = true; hereId = bytes[idStart..<idEnd]
                    i = body; continue
                }
            }

            if b == 0x23 { _open(i); inLine = true; i &+= 1; continue }                      // '#'
            if b == FC.slash { _open(i); inStr = true; quote = FC.slash; i &+= 1; continue } // /.../
            if b == FC.doubleQuote || b == FC.singleQuote { _open(i); inStr = true; quote = b; i &+= 1; continue }

            if _identifierSet.contains(b) {
                let start = i
                var j = i &+ 1
                while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
                let len = j - start
                if let bucket = _keywordBuckets[len] {
                    let slice = bytes[start..<j]
                    if bucket.contains(where: { slice.elementsEqual($0) }) {
                        let abs = (full.lowerBound + (start - bytes.startIndex))..<(full.lowerBound + (j - bytes.startIndex))
                        nodes.append(.init(range: abs, kind: .keyword))
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

        return nodes
    }

    @inline(__always)
    private func _lowerBoundIndex(ofLowerBound value: Int) -> Int {
        var low = 0
        var high = _nodes.count
        while low < high {
            let mid = (low + high) >> 1
            if _nodes[mid].range.lowerBound >= value {
                high = mid
            } else {
                low = mid &+ 1
            }
        }
        return low
    }

    // 範囲と既存ノードの重なり判定（二分探索）
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

    @inline(__always)
    private func _maybeMergePending() {
        guard _pendingNodes.count >= _pendingMergeThreshold else { return }
        _pendingNodes.sort { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [KSyntaxNode] = []
        merged.reserveCapacity(_nodes.count + _pendingNodes.count)

        var i = 0, j = 0
        while i < _nodes.count || j < _pendingNodes.count {
            let pickP: Bool
            if i == _nodes.count { pickP = true }
            else if j == _pendingNodes.count { pickP = false }
            else { pickP = _pendingNodes[j].range.lowerBound < _nodes[i].range.lowerBound }

            let n = pickP ? _pendingNodes[j] : _nodes[i]
            if let last = merged.last,
               last.kind == n.kind,
               last.range.upperBound == n.range.lowerBound {
                merged[merged.count - 1] = .init(range: last.range.lowerBound..<n.range.upperBound, kind: last.kind)
            } else {
                merged.append(n)
            }
            if pickP { j &+= 1 } else { i &+= 1 }
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
}
