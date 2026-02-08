//
//  KSyntaxParser.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

// MARK: - Shared models



struct KAttributedSpan {
    let range: Range<Int>
    let attributes: [NSAttributedString.Key: Any]
}

/// 言語共通で使う機能別カラー
enum KFunctionalColor: CaseIterable {
    case base
    case background
    case comment
    case string
    case keyword
    case number
    case variable
    case tag
    case attribute
    case selector
}

enum KSyntaxType: String, CaseIterable, CustomStringConvertible {
    case plain = "public.plain-text"
    case ruby  = "public.ruby-script"
    case html  = "public.html"
    case ini   = "public.ini-text"
    case sh    = "public.shell-script"

    // extensions for every type.
    var extensions: [String] {
        switch self {
        case .plain: return ["txt", "text", "md"]
        case .ruby:  return ["rb", "rake", "ru", "erb"]
        case .html:  return ["html", "htm", "xhtml", "xml", "plist"]
        case .ini:   return ["ini", "cfg", "conf"]
        case .sh:    return ["sh", "bash", "zsh", "ksh"]
        }
    }

    // ext is extension only (without '.')
    static func fromExtension(_ ext: String) -> Self? {
        let key = ext.lowercased()

        for type in Self.allCases {
            if type.extensions.contains(key) { return type }
        }
        return nil
    }

    // メニュー表示用の文字列
    var string: String {
        switch self {
        case .plain: return "Plain"
        case .ruby:  return "Ruby"
        case .html:  return "HTML/XML"
        case .ini:   return "INI"
        case .sh:    return "Shell"
        }
    }

    // 設定ファイルに記述された文字列をenumに変換する。
    static func fromSetting(_ raw: String) -> Self? {
        let key = raw.lowercased()
        return KSyntaxMeta.reverse[key]
    }

    // enumを設定ファイルに記述される文字列に変換する。
    var settingName: String {
        return KSyntaxMeta.map[self]!
    }

    // enumと設定名の対応を示す構造体。
    private struct KSyntaxMeta {
        // enum → 設定名
        static let map: [KSyntaxType : String] = [
            .plain : "plain",
            .ruby  : "ruby",
            .html  : "html",
            .ini   : "ini",
            .sh    : "sh"
        ]
        // 設定名 → enum
        static let reverse: [String : KSyntaxType] = {
            var r: [String : KSyntaxType] = [:]
            for (k, v) in map { r[v] = k }
            return r
        }()
    }

    // KSyntaxType.plain.makeParser(storage:self)...といった形で生成する。
    func makeParser(storage:KTextStorageReadable) -> KSyntaxParser {
        switch self {
        case .plain: return KSyntaxParserPlain(storage: storage)
        case .ruby:  return KSyntaxParserRuby(storage: storage)
        case .html:  return KSyntaxParserHtml(storage: storage)
        case .ini:   return KSyntaxParserIni(storage: storage)
        case .sh:    return KSyntaxParserSh(storage: storage)
        }
    }

    static func detect(fromTypeName typeName: String?, orExtension ext: String?, content: String) -> Self {
        // 1) typeName が UTI として一致するか
        if let type = typeName, let knownType = KSyntaxType(rawValue: type) {
            return knownType
        }

        // 2) 拡張子から推定（拡張子優先。ただし plain系拡張子は確定にしない）
        if let fileExtension = ext?.lowercased(), !fileExtension.isEmpty {
            if let type = Self.fromExtension(fileExtension) {
                // .txt などは plain 確定にせず、内容判定に回す
                if type != .plain {
                    return type
                }

                // plain拡張子でも「曖昧」なものは確定しない
                // （必要ならここに追加する）
                let ambiguousPlainExtensions: Set<String> = ["txt", "text", "md"]
                if !ambiguousPlainExtensions.contains(fileExtension) {
                    return .plain
                }
                // fallthrough: 内容判定へ
            } else {
                // 未登録の拡張子 → 内容判定へ
            }
        }

        // 3) 拡張子が無い場合だけ内容判定（当面は shebang）
        if let detected = detectFromShebang(content) {
            return detected
        }

        return .plain
    }

    private static func detectFromShebang(_ content: String) -> Self? {
        if content.isEmpty { return nil }

        // 先頭行のみ（shebang）
        let firstLine: Substring
        if let newline = content.firstIndex(of: "\n") {
            firstLine = content[..<newline]
        } else {
            firstLine = content[...]
        }

        var line = firstLine
        if line.first == "\u{FEFF}" { // BOM
            line = line.dropFirst()
        }

        guard line.hasPrefix("#!") else { return nil }

        var rest = line.dropFirst(2)
        while rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
        if rest.isEmpty { return nil }

        // token 化（空白区切り）
        let parts = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.isEmpty { return nil }

        // /usr/bin/env 形式
        var interpreter: Substring? = nil
        if parts[0].hasSuffix("/env") || parts[0] == "env" {
            // env の次の「オプションっぽくない」トークンを interpreter とみなす
            for p in parts.dropFirst() {
                if p.hasPrefix("-") { continue }
                interpreter = p
                break
            }
        } else {
            interpreter = parts[0]
        }

        guard var interp = interpreter, !interp.isEmpty else { return nil }

        // パスの末尾だけ（/bin/bash → bash）
        if let slash = interp.lastIndex(of: "/") {
            interp = interp[interp.index(after: slash)...]
        }

        switch interp.lowercased() {
        case "sh", "bash", "zsh", "ksh":
            return .sh
        case "ruby":
            return .ruby
        default:
            return nil
        }
    }

    var description: String {
        return "KSyntaxType: \(string)"
    }
}

// MARK: - Outline API

/// 言語アウトライン1項目
struct KOutlineItem {
    enum Kind { case `class`, module, method, heading }

    let kind: Kind
    let nameRange: Range<Int>        // range of name-symbol.
    let level: Int                   // nest depth.
    let isSingleton: Bool            // def self.foo / def Klass.bar
}


// MARK: - KSyntaxParser

class KSyntaxParser {
    // Properties
    let storage: KTextStorageReadable
    let type: KSyntaxType
    let keywords: [[UInt8]]
    private let _theme: [KFunctionalColor: NSColor]
    private var _dirtyLineRange: Range<Int>? = nil
    private var _lastSkeletonLineCount: Int = 0
    private var _pendingLineDelta: Int = 0
    private var _pendingSpliceIndex: Int = 0
    
    // Word completion. 言語差にしにくい設計値なので、基底クラスの定数として持つ。
    let completionMinPrefixLength: Int = 2
    let completionMaxCandidates: Int = 32
    let completionMaxWordLength: Int = 128

    private let _completionQueue = DispatchQueue(label: "Ganpi.completion.catalog", qos: .utility)
    private var _completionIsBuilding: Bool = false
    private var _completionIsDirty: Bool = true
    private var _completionCatalog: [[UInt8]] = []
    
    var baseTextColor: NSColor { return color(.base) }
    var backgroundColor: NSColor { return color(.background) }
    
    var lineCommentPrefix: String? { return nil }
    
    
    func noteEdit(oldRange: Range<Int>, newCount: Int) {
        markCompletionDirty()

        let skeleton = storage.skeletonString
        let currentLineCount = skeletonLineCount()

        if _lastSkeletonLineCount == 0 {
            _lastSkeletonLineCount = currentLineCount
            _dirtyLineRange = 0..<currentLineCount
            return
        }

        let oldLineCount = _lastSkeletonLineCount
        _lastSkeletonLineCount = currentLineCount

        // 行数が変わった場合は差分情報を保持し、dirty は局所に閉じ込める
        if currentLineCount != oldLineCount {
            _pendingLineDelta = currentLineCount - oldLineCount

            let clamped = min(oldRange.lowerBound, skeleton.count)
            let editedLine = skeleton.lineIndex(at: clamped)

            // spliceIndex 推定：
            // - 行頭での改行/改行削除はその行自身が動くので editedLine
            // - それ以外（行途中/行末の改行、行末のLF削除）は editedLine+1 側が動く
            let lineRange = skeleton.lineRange(at: min(editedLine, max(0, currentLineCount - 1)))
            let atLineStart = (clamped == lineRange.lowerBound)

            var spliceIndex = atLineStart ? editedLine : (editedLine + 1)
            spliceIndex = max(0, min(spliceIndex, oldLineCount)) // old count 側で clamp

            _pendingSpliceIndex = spliceIndex

            // dirty は編集行の周辺だけ（状態連鎖で必要なら先に伝播する）
            let fromLine = max(0, min(editedLine, currentLineCount - 1))
            let toLine = min(currentLineCount, fromLine + 1) // exclusive
            mergeDirtyLineRange(from: fromLine, to: toLine)

            return
        }

        // 行数が変わらない編集は従来どおり局所 dirty
        let editedLine = skeleton.lineIndex(at: oldRange.lowerBound)
        let fromLine = max(0, min(editedLine, currentLineCount - 1))
        let toLine = min(currentLineCount, fromLine + 1) // exclusive
        mergeDirtyLineRange(from: fromLine, to: toLine)

    }

    
    // ensure internal state is valid for given range
    func ensureUpToDate(for range: Range<Int>) { /* no-op */ }
    
    // 'range' always doesn't contain LF.
    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] { return [] }
    
    func color(_ role: KFunctionalColor) -> NSColor {
        if let color = _theme[role] { return color }
        log("no such color.",from:self)
        return NSColor.textColor
    }
    
    // Additional functions.
    // language-specific range of word. needed by completion system.
    func wordRange(at index: Int) -> Range<Int>? { return nil }
    // where the caret is. Outer: class/struct, Inner: var/func.
    func currentContext(at index: Int) -> (outer: String?, inner: String?) { return (nil, nil) }
    // get outline of structures. for 'jump' menu.
    func outline(in range: Range<Int>?) -> [KOutlineItem] { return [] }
    
    // get completion words (alphabetical / prefix match)
    // completion system needs implementaion of wordRange(at:).
    func completionEntries(prefixBytes: [UInt8]) -> [[UInt8]] {
        guard prefixBytes.count >= completionMinPrefixLength else { return [] }

        startCompletionCatalogBuildIfNeeded()

        let words = _completionCatalog
        guard !words.isEmpty else { return [] }

        let start = lowerBoundIndex(in: words, key: prefixBytes)
        if start >= words.count { return [] }

        var res: [[UInt8]] = []
        res.reserveCapacity(completionMaxCandidates)

        var i = start
        while i < words.count && res.count < completionMaxCandidates {
            let w = words[i]
            if !hasPrefixBytes(w, prefixBytes) { break }

            // prefix と完全一致する語彙は「補完で伸びない」のでスキップする
            if !equalBytes(w, prefixBytes) {
                res.append(w)
            }

            i += 1
        }

        return res
    }


    
    
    init(storage: KTextStorageReadable, type:KSyntaxType){
        self.storage = storage
        self.type = type
        
        // load keywords
        keywords = Self.loadKeywords(type: type)
        
        // load theme.
        let prefs = KPreference.shared
        var theme: [KFunctionalColor: NSColor] = [:]
        
        for role in KFunctionalColor.allCases {
            if let key = Self.prefKey(for: role) {
                theme[role] = prefs.color(key, lang: type)
            }
        }
        _theme = theme
    }
    
    // KAttributedSpanをシンプルに作成する補助メソッド
    func makeSpan(range: Range<Int>, role: KFunctionalColor) -> KAttributedSpan {
        return KAttributedSpan(range: range, attributes: [.foregroundColor: color(role)])
    }
    
    // 現在の skeleton に基づく物理行数（最低1）
    func skeletonLineCount() -> Int {
        let skeleton = storage.skeletonString
        return max(1, skeleton.newlineIndices.count + 1)
    }
    
    private func mergeDirtyLineRange(from: Int, to: Int) {
        let r = from..<to
        if let existing = _dirtyLineRange {
            let lower = min(existing.lowerBound, r.lowerBound)
            let upper = max(existing.upperBound, r.upperBound)
            _dirtyLineRange = lower..<upper
        } else {
            _dirtyLineRange = r
        }
    }

    func consumeRescanPlan(for range: Range<Int>) -> (startLine: Int, minLine: Int, spliceIndex: Int, lineDelta: Int) {
        let skeleton = storage.skeletonString
        let clamped = min(range.lowerBound, skeleton.count)
        let requestedLine = skeleton.lineIndex(at: clamped)

        var startLine = max(0, requestedLine - 1)
        var minLine = requestedLine

        if let dirty = _dirtyLineRange {
            startLine = min(startLine, dirty.lowerBound)
            if dirty.upperBound > 0 {
                minLine = max(minLine, dirty.upperBound - 1)
            }
        }

        let lineDelta = _pendingLineDelta
        let spliceIndex = _pendingSpliceIndex

        _dirtyLineRange = nil
        _pendingLineDelta = 0
        _pendingSpliceIndex = 0

        return (startLine: startLine, minLine: minLine, spliceIndex: spliceIndex, lineDelta: lineDelta)
    }

    // 行数差分（改行追加/削除）を、行バッファへ splice として反映する
    func applyLineDelta<T>(lines: inout [T], spliceIndex: Int, lineDelta: Int, make: () -> T) {
        if lineDelta == 0 { return }

        var index = spliceIndex
        index = max(0, min(index, lines.count))

        if lineDelta > 0 {
            let inserted = (0..<lineDelta).map { _ in make() }
            lines.insert(contentsOf: inserted, at: index)
        } else {
            let removeCount = min(-lineDelta, lines.count - index)
            if removeCount > 0 {
                lines.removeSubrange(index..<(index + removeCount))
            }
        }
    }


    // skeleton の行数に追随する行バッファを用意する（型は呼び出し側で自由）
    // 戻り値: バッファを作り直した（＝行数が変わった）場合 true
    @discardableResult
    func syncLineBuffer<T>(lines: inout [T], make: () -> T) -> Bool {
        let count = skeletonLineCount()

        if lines.count == count {
            return false
        }

        lines = (0..<count).map { _ in make() }
        return true
    }

    
    
    // KFunctionColorに対応する初期設定のkeyを取り出す。
    private static func prefKey(for role: KFunctionalColor) -> KPrefKey? {
        switch role {
        case .base:       return .parserColorText
        case .background: return .parserColorBackground
        case .comment:    return .parserColorComment
        case .string:     return .parserColorLiteral
        case .keyword:    return .parserColorKeyword
        case .number:     return .parserColorNumeric
        case .variable:   return .parserColorVariable
        case .tag:        return .parserColorTag
        case .attribute, .selector:
            return nil
        }
    }
    
    
    // for keywords.
    
    private static func loadKeywords(type: KSyntaxType) -> [[UInt8]] {
        // plain はキーワード無し（ファイルがあっても使わない方針ならここで返す）
        if type == .plain { return [] }

        let resourceBaseName = "keyword_\(type.settingName)"
        let fileName = resourceBaseName + ".txt"

        // 1) User (Application Support) を優先
        if let userURL = userKeywordFileURL(fileName: fileName) {
            if let words = readKeywordFile(from: userURL) {
                return normalizeAndSortKeywords(words)
            }
        }

        // 2) Bundle fallback
        if let url = Bundle.main.url(forResource: resourceBaseName, withExtension: "txt") {
            if let words = readKeywordFile(from: url) {
                return normalizeAndSortKeywords(words)
            }
        }

        return []
    }

    private static func userKeywordFileURL(fileName: String) -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log("Failed to resolve Application Support directory")
            return nil
        }

        let dir = base.appendingPathComponent("Ganpi/keywords", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log("Failed to create Ganpi/keywords directory: \(error)")
            return nil
        }

        let url = dir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func readKeywordFile(from url: URL) -> [String]? {
        do {
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8) else {
                log("Keyword file is not UTF-8: \(url.lastPathComponent)")
                return nil
            }
            let (normalized, _) = string.normalizeNewlinesAndDetect()

            var lines: [String] = []
            lines.reserveCapacity(256)

            for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                if s.hasPrefix("#") { continue }
                lines.append(s)
            }
            return lines
        } catch {
            log("Failed to read keyword file: \(url.lastPathComponent), \(error)")
            return nil
        }
    }

    private static func normalizeAndSortKeywords(_ words: [String]) -> [[UInt8]] {
        var bytes: [[UInt8]] = []
        bytes.reserveCapacity(words.count)

        for w in words {
            bytes.append(Array(w.utf8))
        }

        // sort（[[UInt8]] は sorted 前提）
        bytes.sort { $0.lexicographicallyPrecedes($1) }

        // unique（重複排除）
        var unique: [[UInt8]] = []
        unique.reserveCapacity(bytes.count)

        var last: [UInt8]? = nil
        for w in bytes {
            if let l = last, l == w { continue }
            unique.append(w)
            last = w
        }
        return unique
    }

    
    // Completion helpers.
    
    private func markCompletionDirty() {
        _completionIsDirty = true
    }

    private func startCompletionCatalogBuildIfNeeded() {
        if !_completionIsDirty { return }
        if _completionIsBuilding { return }

        // KSkeletonString はスレッドセーフではない前提で、メインスレッドでコピーを確定させる。
        let skeleton = storage.skeletonString
        let slice = skeleton.bytes(in: 0..<skeleton.count)
        let bytes = Array(slice)

        _completionIsBuilding = true
        _completionIsDirty = false

        let minLen = completionMinPrefixLength
        let maxLen = completionMaxWordLength
        let keywordCatalog = keywords   // [[UInt8]]（loadKeywordsで正規化済み）

        _completionQueue.async { [weak self] in
            guard let self else { return }

            let docCatalog = buildCompletionCatalog(bytes: bytes, minWordLength: minLen, maxWordLength: maxLen)
            let mergedCatalog = mergeSortedUniqueCatalogs(doc: docCatalog, keywords: keywordCatalog)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _completionCatalog = mergedCatalog
                _completionIsBuilding = false
            }
        }
    }
    
    private func mergeSortedUniqueCatalogs(doc: [[UInt8]], keywords: [[UInt8]]) -> [[UInt8]] {
        if doc.isEmpty { return keywords }
        if keywords.isEmpty { return doc }

        var res: [[UInt8]] = []
        res.reserveCapacity(doc.count + keywords.count)

        var i = 0
        var j = 0

        while i < doc.count && j < keywords.count {
            let a = doc[i]
            let b = keywords[j]
            let c = compareBytes(a, b)

            if c == 0 {
                res.append(a)
                i += 1
                j += 1
            } else if c < 0 {
                res.append(a)
                i += 1
            } else {
                res.append(b)
                j += 1
            }
        }

        while i < doc.count {
            res.append(doc[i])
            i += 1
        }
        while j < keywords.count {
            res.append(keywords[j])
            j += 1
        }

        return res
    }

    private func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        if n > 0 {
            for k in 0..<n {
                let x = a[k]
                let y = b[k]
                if x != y { return (x < y) ? -1 : 1 }
            }
        }
        if a.count == b.count { return 0 }
        return (a.count < b.count) ? -1 : 1
    }

    private func equalBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        if a.isEmpty { return true }
        for k in 0..<a.count {
            if a[k] != b[k] { return false }
        }
        return true
    }

    private func hasPrefixBytes(_ word: [UInt8], _ prefix: [UInt8]) -> Bool {
        if prefix.count > word.count { return false }
        if prefix.isEmpty { return true }
        for k in 0..<prefix.count {
            if word[k] != prefix[k] { return false }
        }
        return true
    }

    private func lowerBoundIndex(in words: [[UInt8]], key: [UInt8]) -> Int {
        var low = 0
        var high = words.count

        while low < high {
            let mid = (low + high) / 2
            if compareBytes(words[mid], key) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func buildCompletionCatalog(bytes: [UInt8], minWordLength: Int, maxWordLength: Int) -> [[UInt8]] {
        if bytes.isEmpty { return [] }

        var catalog: [[UInt8]] = []
        catalog.reserveCapacity(4096)

        var i = 0
        while i < bytes.count {
            let b = bytes[i]

            if b.isIdentStartAZ_ {
                var j = i + 1
                while j < bytes.count && bytes[j].isIdentPartAZ09_ {
                    j += 1
                }

                let len = j - i
                if len >= minWordLength && len <= maxWordLength {
                    catalog.append(Array(bytes[i..<j]))
                }

                i = j
                continue
            }

            i += 1
        }

        if catalog.isEmpty { return [] }

        catalog.sort { compareBytes($0, $1) < 0 }

        // unique（隣接重複を除去）
        var uniqueCatalog: [[UInt8]] = []
        uniqueCatalog.reserveCapacity(catalog.count)

        var prev: [UInt8]? = nil
        for w in catalog {
            if let prev {
                if compareBytes(prev, w) == 0 { continue }
            }
            uniqueCatalog.append(w)
            prev = w
        }

        return uniqueCatalog
    }


}


