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
                // interpolation in double-quoted string: "#{ ... }"
                if quote == FC.doubleQuote, b == FC.numeric, i &+ 1 < E, bytes[i + 1] == FC.leftBrace {
                    // close literal part before '#'
                    close(.string, i)
                    // skip '#{' and treat inner as code until matching '}'
                    var depth = 1
                    i &+= 2
                    while i < E, depth > 0 {
                        if bytes[i] == FC.leftBrace { depth &+= 1; i &+= 1; continue }
                        if bytes[i] == FC.rightBrace { depth &-= 1; i &+= 1; continue }
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
}


/*import Cocoa
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
    private var _identifierSet: Set<UInt8> = []        // ASCII の識別子集合
    private var _keywordBuckets: [Int: [[UInt8]]] = [:]  // 長さ → 候補配列
    private var _regexCtxBuckets: [Int: [[UInt8]]] = [:]   // subset of keywords for `/` context
    
    // default.
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
    init(storage: KTextStorageReadable) {
        _storage = storage

        // colors (as before)
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

        // identifier set is fixed per language
        _identifierSet = Set(Self._defaultIdentifierChars.utf8)

        // build keyword buckets from defaults
        _applyKeywords(Self._defaultKeywords)
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
    /*
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
    }*/
    @discardableResult
    func resetKeywords(_ keywords: [String]?) -> Bool {
        let list = keywords ?? Self._defaultKeywords
        return _applyKeywords(list)
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
    
    // 抜粋のコア差し替え部分だけ
    // 直前単語が _regexCtxBuckets に入っているかで `/` を regex と判断
    @inline(__always)
    private func _isRegexContextWord(_ tok: ArraySlice<UInt8>) -> Bool {
        let len = tok.count
        guard let bucket = _regexCtxBuckets[len] else { return false }
        return bucket.contains { tok.elementsEqual($0) }
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
    

    @discardableResult
    private func _applyKeywords(_ list: [String]) -> Bool {
        var newBuckets: [Int: [[UInt8]]] = [:]; newBuckets.reserveCapacity(32)
        for s in list {
            let a = Array(s.utf8); guard !a.isEmpty else { continue }
            newBuckets[a.count, default: []].append(a)
        }

        // derive regex-context buckets from keywords
        var ctx: [Int: [[UInt8]]] = [:]
        for (len, words) in newBuckets {
            let filtered = words.filter { Self._regexCtxSet.contains(String(decoding: $0, as: UTF8.self)) }
            if !filtered.isEmpty { ctx[len] = filtered }
        }

        // no-op check
        if newBuckets == _keywordBuckets { return false }

        _keywordBuckets = newBuckets
        _regexCtxBuckets = ctx

        // invalidate parse results (caller will trigger ensureUpToDate on demand)
        _nodes.removeAll(keepingCapacity: false)
        _pendingNodes.removeAll(keepingCapacity: false)
        _dirty = .init()
        return true
    }

    // MARK: - スキャナ本体
    private func _scan(range: Range<Int>, initialState: _ParserState) -> [KSyntaxNode] {
        var nodes: [KSyntaxNode] = []
        nodes.reserveCapacity(256)

        let full = _skeleton.expandToFullLines(range: range)
        guard full.lowerBound < full.upperBound else { return nodes }

        let bytes = _skeleton.bytes(in: full)
        let E = bytes.endIndex

        @inline(__always) func abs(_ local: Range<Int>) -> Range<Int> {
            (full.lowerBound + (local.lowerBound - bytes.startIndex))..<(full.lowerBound + (local.upperBound - bytes.startIndex))
        }
        @inline(__always) func match(_ at: Int, _ word: [UInt8]) -> Bool {
            let end = at &+ word.count
            return end <= E && bytes[at..<end].elementsEqual(word)
        }
        @inline(__always) func firstNonSpaceAtLineStart(_ at: Int) -> Int {
            var s = at
            if !(s == bytes.startIndex || bytes[s - 1] == FC.lf) {
                var j = s &- 1
                while j >= bytes.startIndex && bytes[j] != FC.lf { j &-= 1 }
                s = (j < bytes.startIndex) ? bytes.startIndex : j &+ 1
            }
            while s < E, (bytes[s] == FC.space || bytes[s] == FC.tab) { s &+= 1 }
            return s
        }
        @inline(__always) func lineEndExcludingLF(from i: Int) -> Int {
            var j = i
            while j < E, bytes[j] != FC.lf { j &+= 1 }
            return j
        }
        @inline(__always) func isAlphaNum(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        @inline(__always) func prevNonSpace(_ idx: Int) -> UInt8? {
            var k = idx &- 1
            while k >= bytes.startIndex {
                let c = bytes[k]
                if c != FC.space && c != FC.tab && c != FC.lf { return c }
                k &-= 1
            }
            return nil
        }
        @inline(__always) func regexDelims(after rPos: Int) -> (open: UInt8, close: UInt8, next: Int)? {
            let dPos = rPos &+ 1
            guard dPos < E else { return nil }
            let d = bytes[dPos]
            if isAlphaNum(d) || d == FC.space || d == FC.tab || d == FC.lf { return nil }
            switch d {
            case FC.leftParen:   return (d, FC.rightParen,   dPos &+ 1)
            case FC.leftBrace:   return (d, FC.rightBrace,   dPos &+ 1)
            case FC.leftBracket: return (d, FC.rightBracket, dPos &+ 1)
            case FC.lt:          return (d, FC.gt,           dPos &+ 1)
            default:             return (d, d,               dPos &+ 1)
            }
        }

        // "#{…}" の中身だけ外扱いにする（括弧は文字列色に残す）。入れ子対応。
        @inline(__always)
        func scanInterpolation(from start: Int) -> Int {
            var i = start
            var depth = 1
            while i < E {
                let b = bytes[i]
                if b == FC.backSlash, i &+ 1 < E { i &+= 2; continue }
                if b == FC.leftBrace  { depth &+= 1; i &+= 1; continue }
                if b == FC.rightBrace {
                    depth &-= 1; i &+= 1
                    if depth == 0 { break }
                    continue
                }

                // @ / @@
                if b == FC.at {
                    let s = i
                    var j = i &+ 1
                    if j < E, bytes[j] == FC.at { j &+= 1 }
                    if j < E, _identifierSet.contains(bytes[j]) {
                        repeat { j &+= 1 } while j < E && _identifierSet.contains(bytes[j])
                        nodes.append(.init(range: abs(s..<j), kind: .variable))
                        i = j; continue
                    }
                }
                // $ 変数群
                if b == FC.dollar, i &+ 1 < E {
                    let s = i
                    var j = i &+ 1
                    let d = bytes[j]
                    if d >= 0x30 && d <= 0x39 {
                        repeat { j &+= 1 } while j < E && (bytes[j] >= 0x30 && bytes[j] <= 0x39)
                        nodes.append(.init(range: abs(s..<j), kind: .variable))
                        i = j; continue
                    }
                    let specials: Set<UInt8> = [
                        FC.tilde, FC.exclamation, FC.question, FC.slash,
                        FC.colon, FC.period, FC.backtick, FC.singleQuote,
                        FC.underscore, FC.dollar
                    ]
                    if specials.contains(d) {
                        j &+= 1
                        nodes.append(.init(range: abs(s..<j), kind: .variable))
                        i = j; continue
                    }
                    if _identifierSet.contains(d) {
                        repeat { j &+= 1 } while j < E && _identifierSet.contains(bytes[j])
                        nodes.append(.init(range: abs(s..<j), kind: .variable))
                        i = j; continue
                    }
                }
                // キーワード
                if _identifierSet.contains(b) {
                    let s = i
                    var j = i &+ 1
                    while j < E && _identifierSet.contains(bytes[j]) { j &+= 1 }
                    let len = j - s
                    if let bucket = _keywordBuckets[len] {
                        let slice = bytes[s..<j]
                        if bucket.contains(where: { slice.elementsEqual($0) }) {
                            nodes.append(.init(range: abs(s..<j), kind: .keyword))
                            i = j; continue
                        }
                    }
                    i = j; continue
                }

                i &+= 1
            }
            return i // '}' の**次の**位置
        }

        // スパン管理
        var spanStart = -1
        @inline(__always) func open(_ at: Int) { spanStart = at }
        @inline(__always) func close(_ kind: KSyntaxKind, _ at: Int) {
            if spanStart >= 0 { nodes.append(.init(range: abs(spanStart..<at), kind: kind)) }
            spanStart = -1
        }

        // 状態復元
        var inMulti = false, inHere = false, inLine = false, inStr = false, inRx = false
        var hereId: ArraySlice<UInt8> = []
        var quote: UInt8 = 0, escaped = false
        var rxClose: UInt8 = 0
        switch initialState {
        case .neutral: break
        case .inLineComment: inLine = true; open(bytes.startIndex)
        case .inMultiComment: inMulti = true; open(bytes.startIndex)
        case .inString(let q): inStr = true; quote = q; open(bytes.startIndex)
        case .inHereDoc(let id): inHere = true; hereId = ArraySlice(id); open(bytes.startIndex)
        case .inRegex(_, let c): inRx = true; rxClose = c; open(bytes.startIndex)
        }

        let kwBegin = _kwBegin, kwEnd = _kwEnd
        var i = bytes.startIndex

        while i < E {
            let b = bytes[i]

            // ---- 内部状態 ----
            if inMulti {
                let j0 = firstNonSpaceAtLineStart(i)
                if j0 == i, match(j0, kwEnd) {
                    let endL = lineEndExcludingLF(from: i)
                    close(.comment, endL)
                    inMulti = false
                    i = (endL < E && bytes[endL] == FC.lf) ? endL &+ 1 : endL
                    continue
                }
                i &+= 1; continue
            }
            if inHere {
                let j0 = firstNonSpaceAtLineStart(i)
                if j0 == i, !hereId.isEmpty,
                   i &+ hereId.count <= E,
                   bytes[i..<(i + hereId.count)].elementsEqual(hereId) {
                    var j = lineEndExcludingLF(from: i)
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
            if inRx {
                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == rxClose {
                    var j = i &+ 1
                    while j < E, isAlphaNum(bytes[j]) { j &+= 1 } // /re/ixm
                    close(.string, j)
                    inRx = false
                    i = j; continue
                }
                i &+= 1; continue
            }
            if inStr {
                // "..." 内の "#{…}"：括弧は文字列色で残し、中身だけ外扱い
                if quote == FC.doubleQuote,
                   b == FC.numeric, i &+ 1 < E, bytes[i &+ 1] == FC.leftBrace {
                    // 直前までの文字列を閉じる
                    close(.string, i)
                    // "#{"
                    nodes.append(.init(range: abs(i..<(i &+ 2)), kind: .string))
                    // 本体をスキャン
                    var j = i &+ 2
                    j = scanInterpolation(from: j)
                    // "}" を文字列色で追加
                    nodes.append(.init(range: abs((j &- 1)..<j), kind: .string))
                    // 文字列を再開
                    if j < E { open(j) } else { spanStart = -1; inStr = false }
                    i = j
                    continue
                }
                if escaped { escaped = false; i &+= 1; continue }
                if b == FC.backSlash { escaped = true; i &+= 1; continue }
                if b == quote { close(.string, i &+ 1); inStr = false; i &+= 1; continue }
                i &+= 1; continue
            }

            // ---- オープニング ----
            let j0 = firstNonSpaceAtLineStart(i)

            // =begin … =end
            if j0 == i, match(j0, kwBegin) {
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
                    let s = firstNonSpaceAtLineStart(k)
                    if s == k, match(s, kwEnd) {
                        let endL = lineEndExcludingLF(from: k)
                        nodes.append(.init(range: abs(head..<endL), kind: .comment))
                        i = (endL < E && bytes[endL] == FC.lf) ? endL &+ 1 : endL
                        closedAt = i
                        break
                    }
                }
                if closedAt != nil { continue }
                open(head); inMulti = true; i &+= 1; continue
            }

            // 行頭の =end 単独塗り（防御）
            if j0 == i, match(j0, kwEnd) {
                var head = i
                if !(head == bytes.startIndex || bytes[head - 1] == FC.lf) {
                    var p = head &- 1
                    while p >= bytes.startIndex && bytes[p] != FC.lf { p &-= 1 }
                    head = (p < bytes.startIndex) ? bytes.startIndex : p &+ 1
                }
                let endL = lineEndExcludingLF(from: i)
                nodes.append(.init(range: abs(head..<endL), kind: .comment))
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
                    open(i); inHere = true; hereId = bytes[idStart..<idEnd]
                    i = body; continue
                }
            }

            // 行コメント
            if b == FC.numeric {
                open(i); inLine = true; i &+= 1; continue
            }

            // /…/ 正規表現 vs 除算
            if b == FC.slash {
                let p = prevNonSpace(i)
                let isDivision: Bool
                if let pc = p {
                    let isIdent = _identifierSet.contains(pc) || (pc >= 0x30 && pc <= 0x39)
                    let isCloser = (pc == FC.rightParen || pc == FC.rightBracket || pc == FC.rightBrace)
                    isDivision = isIdent || isCloser
                } else {
                    isDivision = false // 行頭なら regex
                }
                if !isDivision {
                    open(i); inStr = true; quote = FC.slash; i &+= 1; continue
                }
                // 除算なら素通し
            }

            // '…' / "…"
            if b == FC.doubleQuote || b == FC.singleQuote {
                open(i); inStr = true; quote = b; i &+= 1; continue
            }

            // %r / %R
            if b == FC.percent, i &+ 2 < E {
                let rch = bytes[i &+ 1]
                if rch == UInt8(ascii: "r") || rch == UInt8(ascii: "R"),
                   let (_, cl, next) = regexDelims(after: i &+ 1) {
                    open(i); inRx = true; rxClose = cl
                    i = next; continue
                }
            }

            // 変数（@ / @@）
            if b == FC.at {
                let s = i
                var j = i &+ 1
                if j < E, bytes[j] == FC.at { j &+= 1 }
                if j < E, _identifierSet.contains(bytes[j]) {
                    repeat { j &+= 1 } while j < E && _identifierSet.contains(bytes[j])
                    nodes.append(.init(range: abs(s..<j), kind: .variable))
                    i = j; continue
                }
            }

            // 変数（$...）
            if b == FC.dollar, i &+ 1 < E {
                let s = i
                var j = i &+ 1
                let d = bytes[j]
                if d >= 0x30 && d <= 0x39 {
                    repeat { j &+= 1 } while j < E && (bytes[j] >= 0x30 && bytes[j] <= 0x39)
                    nodes.append(.init(range: abs(s..<j), kind: .variable))
                    i = j; continue
                }
                let specials: Set<UInt8> = [
                    FC.tilde, FC.exclamation, FC.question, FC.slash,
                    FC.colon, FC.period, FC.backtick, FC.singleQuote,
                    FC.underscore, FC.dollar
                ]
                if specials.contains(d) {
                    j &+= 1
                    nodes.append(.init(range: abs(s..<j), kind: .variable))
                    i = j; continue
                }
                if _identifierSet.contains(d) {
                    repeat { j &+= 1 } while j < E && _identifierSet.contains(bytes[j])
                    nodes.append(.init(range: abs(s..<j), kind: .variable))
                    i = j; continue
                }
            }

            // キーワード
            if _identifierSet.contains(b) {
                let s = i
                var j = i &+ 1
                while j < E && _identifierSet.contains(bytes[j]) { j &+= 1 }
                let len = j - s
                if let bucket = _keywordBuckets[len] {
                    let slice = bytes[s..<j]
                    if bucket.contains(where: { slice.elementsEqual($0) }) {
                        nodes.append(.init(range: abs(s..<j), kind: .keyword))
                        i = j; continue
                    }
                }
                i = j; continue
            }

            i &+= 1
        }

        if inMulti { close(.comment, E) }
        if inHere  { close(.string,  E) }
        if inLine  { close(.comment, E) }
        if inStr   { close(.string,  E) }
        if inRx    { close(.string,  E) }

        return nodes
    }
}*/
