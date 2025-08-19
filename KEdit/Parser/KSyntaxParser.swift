//
//  KSyntaxParser.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

// MARK: - Shared models

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
    case variable
    case identifier
    case number
    case punctuation
    case unknown
}

enum KSyntaxType { case plain, ruby, html }

// MARK: - Parser protocol

protocol KSyntaxParserProtocol: AnyObject {
    // TextStorage -> Parser
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)

    // Optional: full parse when needed
    func parse(range: Range<Int>)

    // Painter hook: attribute spans (font is applied by TextStorage)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan]
}

// MARK: - Short alias

typealias FC = FuncChar

// MARK: - Ruby parser

final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // MARK: Defaults (language-fixed)
    private static let _defaultIdentifierChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

    private static let _defaultKeywords: [String] = [
        "def","class","module","if","elsif","else","end","while","until","unless",
        "case","when","for","in","do","then","yield","return","break","next","redo","retry",
        "and","or","not","nil","true","false","self","super","begin","rescue","ensure","raise"
    ]

    // Keywords after which a `/.../` literal is likely to appear (regex context)
    private static let _regexCtxSet: Set<String> = [
        "if","elsif","unless","while","until","when","case","for",
        "return","break","next","redo","retry","yield",
        "and","or","not","then","do"
    ]

    // MARK: Inputs
    private unowned let _storage: KTextStorageReadable
    private var _skeleton: KSkeletonStringInUTF8 { _storage.skeletonString }

    // MARK: Theme (colors only; fonts handled by TextStorage)
    private var _stringColor:  NSColor
    private var _commentColor: NSColor
    private var _keywordColor: NSColor
    private var _variableColor: NSColor

    // Hot attributes (rebuilt by applyTheme)
    private var _stringAttr:  [NSAttributedString.Key: Any]
    private var _commentAttr: [NSAttributedString.Key: Any]
    private var _keywordAttr: [NSAttributedString.Key: Any]
    private var _variableAttr: [NSAttributedString.Key: Any]

    // MARK: Lexer tables
    private var _identifierSet: Set<UInt8> = []              // ASCII set for identifiers
    private var _keywordBuckets: [Int: [[UInt8]]] = [:]      // len -> words
    private var _regexCtxBuckets: [Int: [[UInt8]]] = [:]     // subset of keywords for `/` context

    // MARK: Results
    private var _nodes: [KSyntaxNode] = []                   // ascending by lowerBound

    // Pending (batched inserts before occasional merge)
    private var _pendingNodes: [KSyntaxNode] = []
    private let _pendingMergeThreshold = 20_000

    // MARK: Dirty (line-based)
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
    private let _kwR:     [UInt8] = Array("%r".utf8)

    // MARK: Init
    init(storage: KTextStorageReadable) {
        _storage = storage

        // default colors
        let defString  = "#860300".convertToColor() ?? .black
        let defComment = "#0B5A00".convertToColor() ?? .black
        let defKeyword = "#070093".convertToColor() ?? .black
        let defVar     = "#653F00".convertToColor() ?? .darkGray

        _stringColor   = defString
        _commentColor  = defComment
        _keywordColor  = defKeyword
        _variableColor = defVar

        _stringAttr   = [.foregroundColor: defString]
        _commentAttr  = [.foregroundColor: defComment]
        _keywordAttr  = [.foregroundColor: defKeyword]
        _variableAttr = [.foregroundColor: defVar]

        _identifierSet = Set(Self._defaultIdentifierChars.utf8)

        _applyKeywords(Self._defaultKeywords)
    }

    // MARK: Theme/keywords public
    struct Theme {
        let string: NSColor, comment: NSColor, keyword: NSColor, variable: NSColor
        init(string: NSColor, comment: NSColor, keyword: NSColor, variable: NSColor) {
            self.string = string; self.comment = comment; self.keyword = keyword; self.variable = variable
        }
    }
    func applyTheme(_ theme: Theme) {
        _stringColor   = theme.string
        _commentColor  = theme.comment
        _keywordColor  = theme.keyword
        _variableColor = theme.variable
        _stringAttr   = [.foregroundColor: _stringColor]
        _commentAttr  = [.foregroundColor: _commentColor]
        _keywordAttr  = [.foregroundColor: _keywordColor]
        _variableAttr = [.foregroundColor: _variableColor]
    }

    // Keep legacy signature for compatibility; internally unified
    @discardableResult
    func resetKeywords(_ keywords: [String]) -> Bool { _applyKeywords(keywords) }

    // Optional convenience: nil means revert to defaults
    @discardableResult
    func resetKeywords(_ keywords: [String]?) -> Bool {
        _applyKeywords(keywords ?? Self._defaultKeywords)
    }

    // MARK: KSyntaxParserProtocol – TextStorage hooks
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        // mark whole affected lines as dirty
        let dirtyLines = _skeleton.expandToFullLines(range: oldRange)
        _dirty.insert(dirtyLines)

        // invalidate pending tail (new edits will overwrite) and mark till end dirty
        _invalidatePendingTail(from: dirtyLines.lowerBound)

        // shift existing nodes right of the edit
        let delta = newCount - oldRange.count
        guard delta != 0 else { return }
        _shiftNodes(startingFrom: oldRange.upperBound, by: delta)
    }

    func ensureUpToDate(for range: Range<Int>) {
        let r = _skeleton.expandToFullLines(range: range)

        // if nothing overlaps yet, scan on demand and stage to pending
        if !_hasOverlap(with: r) {
            let initState = _scanStateBefore(r.lowerBound)
            _removeNodes(overlapping: r)
            _removePending(overlapping: r)
            let ns = _scan(range: r, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
            _maybeMergePending()
            return
        }

        // consume dirty segments intersecting visible range
        let need = _dirty.takeIntersecting(r)
        guard !need.isEmpty else { return }

        for d in need {
            let initState = _scanStateBefore(d.lowerBound)
            _removeNodes(overlapping: d)
            _removePending(overlapping: d)
            let ns = _scan(range: d, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
        }
        _maybeMergePending()
    }

    // Full parse (when explicitly requested)
    func parse(range: Range<Int>) {
        let full = _skeleton.expandToFullLines(range: range)
        _nodes = _scan(range: full, initialState: .neutral)
        _dirty = _Dirty()
        _pendingNodes.removeAll(keepingCapacity: true)
    }

    // Painter hook
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan] {
        // collect nodes intersecting 'range' from main + pending
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

        // sort: start asc, longer first on ties
        local.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        // build masks where comment/string dominate (merge overlaps)
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

        // filter out keywords/variables fully covered by comment/string
        var filtered: [KSyntaxNode] = []
        filtered.reserveCapacity(local.count)
    nodeLoop:
        for n in local {
            if (n.kind == .keyword || n.kind == .variable) {
                for m in masks where m.overlaps(n.range) { continue nodeLoop }
            }
            filtered.append(n)
        }
        guard !filtered.isEmpty else { return [] }

        // low (keyword/variable) then high (comment/string) so high overrides
        @inline(__always)
        func attrs(for kind: KSyntaxKind) -> [NSAttributedString.Key: Any]? {
            switch kind {
            case .keyword:  return _keywordAttr
            case .variable: return _variableAttr
            case .comment:  return _commentAttr
            case .string:   return _stringAttr
            default:        return nil
            }
        }

        var spans: [AttributedSpan] = []
        spans.reserveCapacity(filtered.count)
        for n in filtered {
            if let a = attrs(for: n.kind) { spans.append(.init(range: n.range, attributes: a)) }
        }
        return spans
    }

    // MARK: - Internal state helpers

    private enum _ParserState {
        case neutral
        case inLineComment
        case inMultiComment
        case inString(quote: UInt8)
        case inHereDoc(id: [UInt8])
    }

    // --------------- FIX HERE ---------------
    // 直前ノードが .comment のとき、それが「行コメント」か「ブロックコメント」かを
    // スケルトンの実バイトで判別して復元する。
    @inline(__always)
    private func _scanStateBefore(_ pos: Int) -> _ParserState {
        let p = max(0, pos - 1)
        var hit: KSyntaxNode?

        if !_nodes.isEmpty {
            let idx = _lowerBoundIndex(ofLowerBound: p)
            var i = max(0, idx - 1)
            while i < _nodes.count, _nodes[i].range.lowerBound <= p {
                if _nodes[i].range.contains(p) { hit = _nodes[i]; break }
                i &+= 1
            }
        }
        if hit == nil, !_pendingNodes.isEmpty {
            hit = _pendingNodes.first { $0.range.contains(p) }
        }

        guard let n = hit else { return .neutral }

        switch n.kind {
        case .comment:
            // ノード先頭の絶対位置から数バイト取得して種別判定
            let start = n.range.lowerBound
            let end   = min(_storage.count, start &+ max(6, 1)) // "=begin" 6文字まで見る
            let head  = (start < end) ? _skeleton.bytes(in: start..<end) : []

            if let first = head.first, first == FC.numeric {
                // 先頭が '#' なら行コメント
                return .inLineComment
            }
            // "=begin" で始まっていればブロックコメント
            if head.count >= _kwBegin.count &&
               head.prefix(_kwBegin.count).elementsEqual(_kwBegin[...]) {
                return .inMultiComment
            }
            // 安全側：未知の .comment は「行コメント」として扱う（色の“伸び”を防ぐ）
            return .inLineComment

        case .string:
            // 引用種の復元まではしない（0 = 不明）—再スキャンで確定する
            return .inString(quote: 0)

        default:
            return .neutral
        }
    }
    // ----------------------------------------

    @inline(__always)
    private func _lowerBoundIndex(ofLowerBound value: Int) -> Int {
        var low = 0, high = _nodes.count
        while low < high {
            let mid = (low + high) >> 1
            if _nodes[mid].range.lowerBound >= value { high = mid }
            else { low = mid &+ 1 }
        }
        return low
    }

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
    private func _maybeMergePending() {
        guard _pendingNodes.count >= _pendingMergeThreshold else { return }
        _pendingNodes.sort { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [KSyntaxNode] = []
        merged.reserveCapacity(_nodes.count + _pendingNodes.count)

        var i = 0, j = 0
        while i < _nodes.count || j < _pendingNodes.count {
            let usePending: Bool
            if i == _nodes.count { usePending = true }
            else if j == _pendingNodes.count { usePending = false }
            else { usePending = _pendingNodes[j].range.lowerBound < _nodes[i].range.lowerBound }

            let n = usePending ? _pendingNodes[j] : _nodes[i]
            if let last = merged.last,
               last.kind == n.kind,
               last.range.upperBound == n.range.lowerBound {
                merged[merged.count - 1] = .init(range: last.range.lowerBound..<n.range.upperBound, kind: last.kind)
            } else {
                merged.append(n)
            }
            if usePending { j &+= 1 } else { i &+= 1 }
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

    @inline(__always)
    private func _removePending(overlapping r: Range<Int>) {
        guard !_pendingNodes.isEmpty else { return }
        _pendingNodes.removeAll { $0.range.overlaps(r) }
    }

    // MARK: - Local scanner (returns nodes; does not mutate _nodes)
    private func _scan(range: Range<Int>, initialState: _ParserState) -> [KSyntaxNode] {
        var nodes: [KSyntaxNode] = []
        nodes.reserveCapacity(256)

        let full = _skeleton.expandToFullLines(range: range)
        guard full.lowerBound < full.upperBound else { return nodes }

        let bytes = _skeleton.bytes(in: full)
        let E = bytes.endIndex

        @inline(__always) func _abs(_ local: Int) -> Int {
            full.lowerBound + (local - bytes.startIndex)
        }
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
        @inline(__always) func _lineEndNoLF(from i: Int) -> Int {
            var j = i
            while j < E, bytes[j] != FC.lf { j &+= 1 }
            return j
        }
        @inline(__always) func _isWord(_ c: UInt8) -> Bool {
            c == FC.underscore ||
            (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
        }

        // span helpers (absolute ranges)
        var spanStart = -1
        @inline(__always) func open(_ at: Int) { spanStart = at }
        @inline(__always) func close(_ kind: KSyntaxKind, _ at: Int) {
            if spanStart >= 0 {
                let abs = _abs(spanStart)..<_abs(at)
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
            inLine = true; open(bytes.startIndex)
        case .inMultiComment:
            inMulti = true; open(bytes.startIndex)
        case .inString(let q):
            inStr = true; quote = q; open(bytes.startIndex)
        case .inHereDoc(let id):
            inHere = true; hereId = ArraySlice(id); open(bytes.startIndex)
        }

        // helpers for variables
        @inline(__always)
        func emitVariable(from s: Int) -> Int {
            var j = s
            let first = bytes[j]
            if first == FC.at {
                j &+= 1
                if j < E, bytes[j] == FC.at { j &+= 1 }
                while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
            } else if first == FC.dollar {
                j &+= 1
                if j < E, (0x30...0x39).contains(bytes[j]) {
                    while j < E, (0x30...0x39).contains(bytes[j]) { j &+= 1 }
                } else {
                    while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
                }
            }
            if j > s { nodes.append(.init(range: _abs(s)..<_abs(j), kind: .variable)) }
            return j
        }

        // regex delimiter inference after %r / %r?
        @inline(__always)
        func regexDelims(after i: Int) -> (open: UInt8, close: UInt8, next: Int)? {
            guard i < E else { return nil }
            let c = bytes[i]
            switch c {
            case FC.leftParen:   return (FC.leftParen,   FC.rightParen,   i &+ 1)
            case FC.leftBracket: return (FC.leftBracket, FC.rightBracket, i &+ 1)
            case FC.leftBrace:   return (FC.leftBrace,   FC.rightBrace,   i &+ 1)
            case FC.lt:          return (FC.lt,          FC.gt,           i &+ 1)
            default:             return (c, c, i &+ 1)
            }
        }

        @inline(__always)
        func slashIsRegex(at i: Int) -> Bool {
            var p = i &- 1
            while p >= bytes.startIndex {
                let c = bytes[p]
                if c == FC.space || c == FC.tab { p &-= 1; continue }
                if c == FC.lf { return true }
                if _isWord(c) {
                    var end = p, start = p
                    while start > bytes.startIndex, _isWord(bytes[start &- 1]) { start &-= 1 }
                    let tok = bytes[start...end]
                    if let bucket = _regexCtxBuckets[tok.count],
                       bucket.contains(where: { tok.elementsEqual($0) }) {
                        return true
                    }
                    return false
                }
                if c == FC.rightParen || c == FC.rightBracket || c == FC.rightBrace
                    || c == FC.singleQuote || c == FC.doubleQuote {
                    return false
                }
                switch c {
                case FC.comma, FC.semicolon, FC.colon,
                     FC.plus, FC.minus, FC.asterisk, FC.percent,
                     FC.equals, FC.exclamation, FC.ampersand,
                     FC.pipe, FC.caret, FC.lt, FC.gt, FC.tilde,
                     FC.leftParen, FC.leftBracket, FC.leftBrace:
                    return true
                default:
                    return true
                }
            }
            return true
        }

        var i = bytes.startIndex
        while i < E {
            let b = bytes[i]
            let isLineStart = (i == bytes.startIndex) || (bytes[i - 1] == FC.lf)

            // -------- inside states --------
            if inMulti {
                let j0 = _firstNonSpaceAtLineStart(i)
                if j0 == i, _match(j0, ascii: _kwEnd) {
                    let endL = _lineEndNoLF(from: i)
                    close(.comment, endL)
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
                    var j = _lineEndNoLF(from: i)
                    if j < E { j &+= 1 }
                    close(.string, j)
                    inHere = false; hereId = []
                    i = j; continue
                }
                i &+= 1; continue
            }

            if inLine {
                if b == FC.lf { close(.comment, i); inLine = false }
                i &+= 1; continue
            }

            if inStr {
                if quote == FC.doubleQuote, b == FC.numeric, i &+ 1 < E, bytes[i + 1] == FC.leftBrace {
                    close(.string, i)
                    nodes.append(.init(range: _abs(i)..<_abs(i &+ 2), kind: .string))
                    var depth = 1
                    i &+= 2
                    while i < E, depth > 0 {
                        if bytes[i] == FC.leftBrace { depth &+= 1; i &+= 1; continue }
                        if bytes[i] == FC.rightBrace {
                            depth &-= 1
                            i &+= 1
                            if depth == 0 {
                                let braceStart = i &- 1
                                nodes.append(.init(range: _abs(braceStart)..<_abs(braceStart &+ 1), kind: .string))
                                break
                            }
                            continue
                        }
                        if bytes[i] == FC.at || bytes[i] == FC.dollar {
                            i = emitVariable(from: i); continue
                        }
                        i &+= 1
                    }
                    if i < E { open(i); inStr = true }
                    continue
                }

                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == quote {
                    close(.string, i &+ 1)
                    inStr = false
                    i &+= 1
                    continue
                }
                i &+= 1; continue
            }

            // -------- openings --------

            if isLineStart, _match(i, ascii: _kwBegin) {
                var head = i
                if !(head == bytes.startIndex || bytes[head - 1] == FC.lf) {
                    var p = head &- 1
                    while p >= bytes.startIndex && bytes[p] != FC.lf { p &-= 1 }
                    head = (p < bytes.startIndex) ? bytes.startIndex : p &+ 1
                }
                open(head); inMulti = true; i &+= 1; continue
            }

            // heredoc start
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
                    open(i); inHere = true; hereId = bytes[idStart..<idEnd]
                    i = body; continue
                }
            }

            // line comment
            if b == FC.numeric {
                open(i); inLine = true; i &+= 1; continue
            }

            // %r-forms regex
            if _match(i, ascii: _kwR) {
                if let (op, cl, next) = regexDelims(after: i &+ 2) {
                    open(i)
                    var j = next
                    var depth = 0
                    while j < E {
                        let c = bytes[j]
                        if c == FC.backSlash { j &+= 2; continue }
                        if op != cl {
                            if c == op { depth &+= 1; j &+= 1; continue }
                            if c == cl {
                                if depth == 0 { j &+= 1; break }
                                depth &-= 1; j &+= 1; continue
                            }
                        } else {
                            if c == cl { j &+= 1; break }
                        }
                        j &+= 1
                    }
                    while j < E, (0x61...0x7A).contains(bytes[j]) { j &+= 1 }
                    close(.string, j)
                    i = j
                    continue
                }
            }

            // slash-regex vs division
            if b == FC.slash {
                if slashIsRegex(at: i) {
                    open(i); inStr = true; quote = FC.slash; i &+= 1; continue
                }
            }

            // quotes
            if b == FC.doubleQuote || b == FC.singleQuote {
                open(i); inStr = true; quote = b; escaped = false; i &+= 1; continue
            }

            // variables
            if b == FC.at || b == FC.dollar {
                i = emitVariable(from: i); continue
            }

            // keywords
            if _identifierSet.contains(b) {
                let start = i
                var j = i &+ 1
                while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
                let len = j - start
                if let bucket = _keywordBuckets[len] {
                    let slice = bytes[start..<j]
                    if bucket.contains(where: { slice.elementsEqual($0) }) {
                        nodes.append(.init(range: _abs(start)..<_abs(j), kind: .keyword))
                    }
                }
                i = j; continue
            }

            i &+= 1
        }

        // close dangling spans
        if inMulti { close(.comment, E) }
        if inHere  { close(.string,  E) }
        if inLine  { close(.comment, E) }
        if inStr   { close(.string,  E) }

        return nodes
    }

    // MARK: - Keywords plumbing

    @discardableResult
    private func _applyKeywords(_ list: [String]) -> Bool {
        var newBuckets: [Int: [[UInt8]]] = [:]; newBuckets.reserveCapacity(32)
        for s in list {
            let a = Array(s.utf8); guard !a.isEmpty else { continue }
            newBuckets[a.count, default: []].append(a)
        }

        var ctx: [Int: [[UInt8]]] = [:]
        for (len, words) in newBuckets {
            let filtered = words.filter { Self._regexCtxSet.contains(String(decoding: $0, as: UTF8.self)) }
            if !filtered.isEmpty { ctx[len] = filtered }
        }

        if newBuckets == _keywordBuckets { return false }

        _keywordBuckets  = newBuckets
        _regexCtxBuckets = ctx
        _nodes.removeAll(keepingCapacity: false)
        _pendingNodes.removeAll(keepingCapacity: false)
        _dirty = .init()
        return true
    }

    // MARK: - Node shifting

    private func _shiftNodes(startingFrom cut: Int, by delta: Int) {
        guard delta != 0, !_nodes.isEmpty else { return }
        let idx = _lowerBoundIndex(ofLowerBound: cut)
        if idx < _nodes.count {
            for k in idx..<_nodes.count {
                let r = _nodes[k].range
                _nodes[k] = .init(range: (r.lowerBound + delta)..<(r.upperBound + delta),
                                  kind: _nodes[k].kind)
            }
        }
    }
}

/*
//
//  KSyntaxParser.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

//
//  KSyntaxParser.swift
//  KEdit
//
//  Protocol + Ruby parser (final cut)
//
//  Assumptions:
//  - KSkeletonStringInUTF8: 1 char == 1 byte; non‑ASCII -> 'a', LF normalized.
//  - Indices are byte-based and aligned with character slice from TextStorage.
//  - TextStorage provides: skeletonString, count, etc.
//  - FuncChar provides ASCII tokens as UInt8 (see your current definition).
//

import AppKit

// MARK: - Shared models

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
    case variable
    case identifier
    case number
    case punctuation
    case unknown
}

enum KSyntaxType { case plain, ruby, html }

// MARK: - Parser protocol

protocol KSyntaxParserProtocol: AnyObject {
    // TextStorage -> Parser
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)

    // Optional: full parse when needed
    func parse(range: Range<Int>)

    // Painter hook: attribute spans (font is applied by TextStorage)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan]
}

// MARK: - Short alias

typealias FC = FuncChar

// MARK: - Ruby parser

final class KSyntaxParserRuby: KSyntaxParserProtocol {

    // MARK: Defaults (language-fixed)
    private static let _defaultIdentifierChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

    private static let _defaultKeywords: [String] = [
        "def","class","module","if","elsif","else","end","while","until","unless",
        "case","when","for","in","do","then","yield","return","break","next","redo","retry",
        "and","or","not","nil","true","false","self","super","begin","rescue","ensure","raise"
    ]

    // Keywords after which a `/.../` literal is likely to appear (regex context)
    private static let _regexCtxSet: Set<String> = [
        "if","elsif","unless","while","until","when","case","for",
        "return","break","next","redo","retry","yield",
        "and","or","not","then","do"
    ]

    // MARK: Inputs
    private unowned let _storage: KTextStorageReadable
    private var _skeleton: KSkeletonStringInUTF8 { _storage.skeletonString }

    // MARK: Theme (colors only; fonts handled by TextStorage)
    private var _stringColor:  NSColor
    private var _commentColor: NSColor
    private var _keywordColor: NSColor
    private var _variableColor: NSColor

    // Hot attributes (rebuilt by applyTheme)
    private var _stringAttr:  [NSAttributedString.Key: Any]
    private var _commentAttr: [NSAttributedString.Key: Any]
    private var _keywordAttr: [NSAttributedString.Key: Any]
    private var _variableAttr: [NSAttributedString.Key: Any]

    // MARK: Lexer tables
    private var _identifierSet: Set<UInt8> = []              // ASCII set for identifiers
    private var _keywordBuckets: [Int: [[UInt8]]] = [:]      // len -> words
    private var _regexCtxBuckets: [Int: [[UInt8]]] = [:]     // subset of keywords for `/` context

    // MARK: Results
    private var _nodes: [KSyntaxNode] = []                   // ascending by lowerBound

    // Pending (batched inserts before occasional merge)
    private var _pendingNodes: [KSyntaxNode] = []
    private let _pendingMergeThreshold = 20_000

    // MARK: Dirty (line-based)
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
    private let _kwR:     [UInt8] = Array("%r".utf8)

    // MARK: Init
    init(storage: KTextStorageReadable) {
        _storage = storage

        // default colors
        let defString  = "#860300".convertToColor() ?? .black
        let defComment = "#0B5A00".convertToColor() ?? .black
        let defKeyword = "#070093".convertToColor() ?? .black
        let defVar     = "#653F00".convertToColor() ?? .darkGray

        _stringColor   = defString
        _commentColor  = defComment
        _keywordColor  = defKeyword
        _variableColor = defVar

        _stringAttr   = [.foregroundColor: defString]
        _commentAttr  = [.foregroundColor: defComment]
        _keywordAttr  = [.foregroundColor: defKeyword]
        _variableAttr = [.foregroundColor: defVar]

        _identifierSet = Set(Self._defaultIdentifierChars.utf8)

        _applyKeywords(Self._defaultKeywords)
    }

    // MARK: Theme/keywords public
    struct Theme {
        let string: NSColor, comment: NSColor, keyword: NSColor, variable: NSColor
        init(string: NSColor, comment: NSColor, keyword: NSColor, variable: NSColor) {
            self.string = string; self.comment = comment; self.keyword = keyword; self.variable = variable
        }
    }
    func applyTheme(_ theme: Theme) {
        _stringColor   = theme.string
        _commentColor  = theme.comment
        _keywordColor  = theme.keyword
        _variableColor = theme.variable
        _stringAttr   = [.foregroundColor: _stringColor]
        _commentAttr  = [.foregroundColor: _commentColor]
        _keywordAttr  = [.foregroundColor: _keywordColor]
        _variableAttr = [.foregroundColor: _variableColor]
    }

    // Keep legacy signature for compatibility; internally unified
    @discardableResult
    func resetKeywords(_ keywords: [String]) -> Bool { _applyKeywords(keywords) }

    // Optional convenience: nil means revert to defaults
    @discardableResult
    func resetKeywords(_ keywords: [String]?) -> Bool {
        _applyKeywords(keywords ?? Self._defaultKeywords)
    }

    // MARK: KSyntaxParserProtocol – TextStorage hooks
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        // mark whole affected lines as dirty
        let dirtyLines = _skeleton.expandToFullLines(range: oldRange)
        _dirty.insert(dirtyLines)

        // invalidate pending tail (new edits will overwrite) and mark till end dirty
        _invalidatePendingTail(from: dirtyLines.lowerBound)

        // shift existing nodes right of the edit
        let delta = newCount - oldRange.count
        guard delta != 0 else { return }
        _shiftNodes(startingFrom: oldRange.upperBound, by: delta)
    }

    func ensureUpToDate(for range: Range<Int>) {
        let r = _skeleton.expandToFullLines(range: range)

        // if nothing overlaps yet, scan on demand and stage to pending
        if !_hasOverlap(with: r) {
            let initState = _scanStateBefore(r.lowerBound)
            _removeNodes(overlapping: r)
            _removePending(overlapping: r)
            let ns = _scan(range: r, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
            _maybeMergePending()
            return
        }

        // consume dirty segments intersecting visible range
        let need = _dirty.takeIntersecting(r)
        guard !need.isEmpty else { return }

        for d in need {
            let initState = _scanStateBefore(d.lowerBound)
            _removeNodes(overlapping: d)
            _removePending(overlapping: d)
            let ns = _scan(range: d, initialState: initState)
            _pendingNodes.append(contentsOf: ns)
        }
        _maybeMergePending()
    }

    // Full parse (when explicitly requested)
    func parse(range: Range<Int>) {
        let full = _skeleton.expandToFullLines(range: range)
        _nodes = _scan(range: full, initialState: .neutral)
        _dirty = _Dirty()
        _pendingNodes.removeAll(keepingCapacity: true)
    }

    // Painter hook
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan] {
        // collect nodes intersecting 'range' from main + pending
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

        // sort: start asc, longer first on ties
        local.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        // build masks where comment/string dominate (merge overlaps)
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

        // filter out keywords/variables fully covered by comment/string
        var filtered: [KSyntaxNode] = []
        filtered.reserveCapacity(local.count)
    nodeLoop:
        for n in local {
            if (n.kind == .keyword || n.kind == .variable) {
                for m in masks where m.overlaps(n.range) { continue nodeLoop }
            }
            filtered.append(n)
        }
        guard !filtered.isEmpty else { return [] }

        // low (keyword/variable) then high (comment/string) so high overrides
        @inline(__always)
        func attrs(for kind: KSyntaxKind) -> [NSAttributedString.Key: Any]? {
            switch kind {
            case .keyword:  return _keywordAttr
            case .variable: return _variableAttr
            case .comment:  return _commentAttr
            case .string:   return _stringAttr
            default:        return nil
            }
        }

        var spans: [AttributedSpan] = []
        spans.reserveCapacity(filtered.count)
        for n in filtered {
            if let a = attrs(for: n.kind) { spans.append(.init(range: n.range, attributes: a)) }
        }
        return spans
    }

    // MARK: - Internal state helpers

    private enum _ParserState {
        case neutral
        case inLineComment
        case inMultiComment
        case inString(quote: UInt8)
        case inHereDoc(id: [UInt8])
    }

    @inline(__always)
    private func _scanStateBefore(_ pos: Int) -> _ParserState {
        let p = max(0, pos - 1)
        var hit: KSyntaxNode?

        if !_nodes.isEmpty {
            let idx = _lowerBoundIndex(ofLowerBound: p)
            var i = max(0, idx - 1)
            while i < _nodes.count, _nodes[i].range.lowerBound <= p {
                if _nodes[i].range.contains(p) { hit = _nodes[i]; break }
                i &+= 1
            }
        }
        if hit == nil, !_pendingNodes.isEmpty {
            hit = _pendingNodes.first { $0.range.contains(p) }
        }

        guard let n = hit else { return .neutral }
        switch n.kind {
        case .comment: return .inMultiComment       // coarse resume
        case .string:  return .inString(quote: 0)   // quote not restored
        default:       return .neutral
        }
    }

    @inline(__always)
    private func _lowerBoundIndex(ofLowerBound value: Int) -> Int {
        var low = 0, high = _nodes.count
        while low < high {
            let mid = (low + high) >> 1
            if _nodes[mid].range.lowerBound >= value { high = mid }
            else { low = mid &+ 1 }
        }
        return low
    }

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
    private func _maybeMergePending() {
        guard _pendingNodes.count >= _pendingMergeThreshold else { return }
        _pendingNodes.sort { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [KSyntaxNode] = []
        merged.reserveCapacity(_nodes.count + _pendingNodes.count)

        var i = 0, j = 0
        while i < _nodes.count || j < _pendingNodes.count {
            let usePending: Bool
            if i == _nodes.count { usePending = true }
            else if j == _pendingNodes.count { usePending = false }
            else { usePending = _pendingNodes[j].range.lowerBound < _nodes[i].range.lowerBound }

            let n = usePending ? _pendingNodes[j] : _nodes[i]
            if let last = merged.last,
               last.kind == n.kind,
               last.range.upperBound == n.range.lowerBound {
                merged[merged.count - 1] = .init(range: last.range.lowerBound..<n.range.upperBound, kind: last.kind)
            } else {
                merged.append(n)
            }
            if usePending { j &+= 1 } else { i &+= 1 }
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

    @inline(__always)
    private func _removePending(overlapping r: Range<Int>) {
        guard !_pendingNodes.isEmpty else { return }
        _pendingNodes.removeAll { $0.range.overlaps(r) }
    }

    // MARK: - Local scanner (returns nodes; does not mutate _nodes)
    private func _scan(range: Range<Int>, initialState: _ParserState) -> [KSyntaxNode] {
        var nodes: [KSyntaxNode] = []
        nodes.reserveCapacity(256)

        let full = _skeleton.expandToFullLines(range: range)
        guard full.lowerBound < full.upperBound else { return nodes }

        let bytes = _skeleton.bytes(in: full)
        let E = bytes.endIndex

        @inline(__always) func _abs(_ local: Int) -> Int {
            full.lowerBound + (local - bytes.startIndex)
        }
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
        @inline(__always) func _lineEndNoLF(from i: Int) -> Int {
            var j = i
            while j < E, bytes[j] != FC.lf { j &+= 1 }
            return j
        }
        @inline(__always) func _isWord(_ c: UInt8) -> Bool {
            c == FC.underscore ||
            (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
        }

        // span helpers (absolute ranges)
        var spanStart = -1
        @inline(__always) func open(_ at: Int) { spanStart = at }
        @inline(__always) func close(_ kind: KSyntaxKind, _ at: Int) {
            if spanStart >= 0 {
                let abs = _abs(spanStart)..<_abs(at)
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
            inLine = true; open(bytes.startIndex)
        case .inMultiComment:
            inMulti = true; open(bytes.startIndex)
        case .inString(let q):
            inStr = true; quote = q; open(bytes.startIndex)
        case .inHereDoc(let id):
            inHere = true; hereId = ArraySlice(id); open(bytes.startIndex)
        }

        // helpers for variables
        @inline(__always)
        func emitVariable(from s: Int) -> Int {
            var j = s
            let first = bytes[j]
            if first == FC.at {
                // @@class or @instance
                j &+= 1
                if j < E, bytes[j] == FC.at { j &+= 1 }
                while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
            } else if first == FC.dollar {
                // $global / $1
                j &+= 1
                if j < E, (0x30...0x39).contains(bytes[j]) {
                    while j < E, (0x30...0x39).contains(bytes[j]) { j &+= 1 }
                } else {
                    while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
                }
            }
            if j > s { nodes.append(.init(range: _abs(s)..<_abs(j), kind: .variable)) }
            return j
        }

        // regex delimiter inference after %r / %r?
        @inline(__always)
        func regexDelims(after i: Int) -> (open: UInt8, close: UInt8, next: Int)? {
            guard i < E else { return nil }
            let c = bytes[i]
            switch c {
            case FC.leftParen:   return (FC.leftParen,   FC.rightParen,   i &+ 1)
            case FC.leftBracket: return (FC.leftBracket, FC.rightBracket, i &+ 1)
            case FC.leftBrace:   return (FC.leftBrace,   FC.rightBrace,   i &+ 1)
            case FC.lt:          return (FC.lt,          FC.gt,           i &+ 1)
            default:             return (c, c, i &+ 1) // same char as both ends
            }
        }

        // does '/' start a regex (vs division)?
        @inline(__always)
        func slashIsRegex(at i: Int) -> Bool {
            // previous non-space char
            var p = i &- 1
            while p >= bytes.startIndex {
                let c = bytes[p]
                if c == FC.space || c == FC.tab { p &-= 1; continue }
                if c == FC.lf { return true } // line start
                // word?
                if _isWord(c) {
                    var end = p, start = p
                    while start > bytes.startIndex, _isWord(bytes[start &- 1]) { start &-= 1 }
                    let tok = bytes[start...end]
                    if let bucket = _regexCtxBuckets[tok.count],
                       bucket.contains(where: { tok.elementsEqual($0) }) {
                        return true  // context keywords -> regex
                    }
                    return false     // other identifiers -> division
                }
                // value-ending tokens -> division
                if c == FC.rightParen || c == FC.rightBracket || c == FC.rightBrace
                    || c == FC.singleQuote || c == FC.doubleQuote {
                    return false
                }
                // operators / openers -> regex
                switch c {
                case FC.comma, FC.semicolon, FC.colon,
                     FC.plus, FC.minus, FC.asterisk, FC.percent,
                     FC.equals, FC.exclamation, FC.ampersand,
                     FC.pipe, FC.caret, FC.lt, FC.gt, FC.tilde,
                     FC.leftParen, FC.leftBracket, FC.leftBrace:
                    return true
                default:
                    return true
                }
            }
            return true
        }

        var i = bytes.startIndex
        while i < E {
            let b = bytes[i]
            let isLineStart = (i == bytes.startIndex) || (bytes[i - 1] == FC.lf)

            // -------- inside states --------
            if inMulti {
                let j0 = _firstNonSpaceAtLineStart(i)
                if j0 == i, _match(j0, ascii: _kwEnd) {
                    let endL = _lineEndNoLF(from: i)
                    close(.comment, endL)
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
                    var j = _lineEndNoLF(from: i)
                    if j < E { j &+= 1 }
                    close(.string, j)
                    inHere = false; hereId = []
                    i = j; continue
                }
                i &+= 1; continue
            }

            if inLine {
                if b == FC.lf { close(.comment, i); inLine = false }
                i &+= 1; continue
            }

            if inStr {
                
                
                if quote == FC.doubleQuote, b == FC.numeric, i &+ 1 < E, bytes[i + 1] == FC.leftBrace {
                    // close literal part before '#'
                    close(.string, i)

                    // ★追加: "#{” の2文字そのものを .string としてマーキング
                    nodes.append(.init(range: _abs(i)..<_abs(i &+ 2), kind: .string))

                    // skip '#{' and treat inner as code until matching '}'
                    var depth = 1
                    i &+= 2
                    while i < E, depth > 0 {
                        if bytes[i] == FC.leftBrace { depth &+= 1; i &+= 1; continue }
                        if bytes[i] == FC.rightBrace {
                            depth &-= 1
                            i &+= 1
                            if depth == 0 { // ★変更: 最外 '}' に到達した瞬間だけ処理
                                // ★追加: 終端 '}' の1文字を .string としてマーキング
                                let braceStart = i &- 1
                                nodes.append(.init(range: _abs(braceStart)..<_abs(braceStart &+ 1), kind: .string))
                                break
                            }
                            continue
                        }
                        // allow variables inside interpolation
                        if bytes[i] == FC.at || bytes[i] == FC.dollar {
                            i = emitVariable(from: i); continue
                        }
                        i &+= 1
                    }
                    // reopen string if still within literal
                    if i < E { open(i); inStr = true } // keep same quote
                    continue
                }

                // usual escapes / closing
                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == quote {
                    close(.string, i &+ 1)
                    inStr = false
                    i &+= 1
                    continue
                }
                i &+= 1; continue
                
                
            }

            // -------- openings --------

            // =begin at line start -> begin multi-line comment (include marker line)
            if isLineStart, _match(i, ascii: _kwBegin) {
                // include from line head
                var head = i
                if !(head == bytes.startIndex || bytes[head - 1] == FC.lf) {
                    var p = head &- 1
                    while p >= bytes.startIndex && bytes[p] != FC.lf { p &-= 1 }
                    head = (p < bytes.startIndex) ? bytes.startIndex : p &+ 1
                }
                open(head); inMulti = true; i &+= 1; continue
            }

            // heredoc start: <<, <<-, <<~ with optional quoted ID
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
                    open(i); inHere = true; hereId = bytes[idStart..<idEnd]
                    i = body; continue
                }
            }

            // line comment
            if b == FC.numeric {
                open(i); inLine = true; i &+= 1; continue
            }

            // %r-forms regex: %r{...}, %r(...), %r[...] , %r<...> or %r!…!
            if _match(i, ascii: _kwR) {
                if let (op, cl, next) = regexDelims(after: i &+ 2) {
                    open(i); // include "%r"
                    var j = next
                    var depth = 0
                    while j < E {
                        let c = bytes[j]
                        if c == FC.backSlash { j &+= 2; continue }
                        if op != cl {
                            if c == op { depth &+= 1; j &+= 1; continue }
                            if c == cl {
                                if depth == 0 { j &+= 1; break }
                                depth &-= 1; j &+= 1; continue
                            }
                        } else {
                            if c == cl { j &+= 1; break }
                        }
                        j &+= 1
                    }
                    // optional modifiers letters (skip [a-z]*)
                    while j < E, (0x61...0x7A).contains(bytes[j]) { j &+= 1 }
                    close(.string, j)
                    i = j
                    continue
                }
            }

            // slash-regex vs division
            if b == FC.slash {
                if slashIsRegex(at: i) {
                    open(i); inStr = true; quote = FC.slash; i &+= 1; continue
                }
                // division: fallthrough
            }

            // quotes
            if b == FC.doubleQuote || b == FC.singleQuote {
                open(i); inStr = true; quote = b; escaped = false; i &+= 1; continue
            }

            // variables (@, @@, $)
            if b == FC.at || b == FC.dollar {
                i = emitVariable(from: i); continue
            }

            // keywords: cut identifier then check length bucket
            if _identifierSet.contains(b) {
                let start = i
                var j = i &+ 1
                while j < E, _identifierSet.contains(bytes[j]) { j &+= 1 }
                let len = j - start
                if let bucket = _keywordBuckets[len] {
                    let slice = bytes[start..<j]
                    if bucket.contains(where: { slice.elementsEqual($0) }) {
                        nodes.append(.init(range: _abs(start)..<_abs(j), kind: .keyword))
                    }
                }
                i = j; continue
            }

            i &+= 1
        }

        // close dangling spans
        if inMulti { close(.comment, E) }
        if inHere  { close(.string,  E) }
        if inLine  { close(.comment, E) }
        if inStr   { close(.string,  E) }

        return nodes
    }

    // MARK: - Keywords plumbing

    @discardableResult
    private func _applyKeywords(_ list: [String]) -> Bool {
        var newBuckets: [Int: [[UInt8]]] = [:]; newBuckets.reserveCapacity(32)
        for s in list {
            let a = Array(s.utf8); guard !a.isEmpty else { continue }
            newBuckets[a.count, default: []].append(a)
        }

        var ctx: [Int: [[UInt8]]] = [:]
        for (len, words) in newBuckets {
            let filtered = words.filter { Self._regexCtxSet.contains(String(decoding: $0, as: UTF8.self)) }
            if !filtered.isEmpty { ctx[len] = filtered }
        }

        if newBuckets == _keywordBuckets { return false }

        _keywordBuckets  = newBuckets
        _regexCtxBuckets = ctx
        _nodes.removeAll(keepingCapacity: false)
        _pendingNodes.removeAll(keepingCapacity: false)
        _dirty = .init()
        return true
    }

    // MARK: - Node shifting

    private func _shiftNodes(startingFrom cut: Int, by delta: Int) {
        guard delta != 0, !_nodes.isEmpty else { return }
        let idx = _lowerBoundIndex(ofLowerBound: cut)
        if idx < _nodes.count {
            for k in idx..<_nodes.count {
                let r = _nodes[k].range
                _nodes[k] = .init(range: (r.lowerBound + delta)..<(r.upperBound + delta),
                                  kind: _nodes[k].kind)
            }
        }
    }
}*/


