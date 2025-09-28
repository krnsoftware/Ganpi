//
//  KTextStorage.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa
import AppKit

// MARK: - General enum and struct

// Observingに使用するenumとstruct
struct KStorageModifiedInfo {
    let range: Range<Int>
    let insertedCount: Int
    let deletedNewlineCount: Int
    let insertedNewlineCount: Int
}

enum KStorageModified {
    case textChanged(info: KStorageModifiedInfo)
    case colorChanged(range: Range<Int>)
}

// 方向を示すenum
enum KDirection: Int {
    case forward = 1
    case backward = -1
}


// MARK: - KTextStorageProtocol
// read-onlyとして利用する場合にはKTextStorageReadableを使用。
// read & writeとして利用する場合にはKTextStorageProtocolを使用。

// 共通プロパティ（読み書き両方が依存する基本インターフェース）
protocol KTextStorageCommon: AnyObject {
    var count: Int { get }
    var baseFont: NSFont { get }
    var characterSlice: ArraySlice<Character> { get }
    subscript(index: Int) -> Character? { get }
    subscript(range: Range<Int>) -> ArraySlice<Character>? { get }
    
    func addObserver(_ owner: AnyObject, _ handler: @escaping (KStorageModified) -> Void)
    func removeObserver(_ owner: AnyObject)
    
    func undo()
    func redo()
}

// 読み取り専用プロトコル
protocol KTextStorageReadable: KTextStorageCommon {
    var string: String { get }
    var skeletonString: KSkeletonStringInUTF8 { get }
    //var parser: KSyntaxParserProtocol { get }
    var hardLineCount: Int { get } // if _character is empty, return 1. if end of chars is '\n', add 1.
    var invisibleCharacters: KInvisibleCharacters? { get }
    var spaceAdvance: CGFloat { get }
    var lineNumberCharacterMaxWidth: CGFloat { get }
    var lineNumberFont: NSFont { get }
    var lineNumberFontEmph: NSFont { get }
    
    func wordRange(at index: Int) -> Range<Int>?
    func attributedString(for range: Range<Int>, tabWidth: Int?, withoutColors: Bool) -> NSAttributedString?
    func lineRange(at index: Int) -> Range<Int>?
    func lineAndColumNumber(at index:Int) -> (line:Int, column:Int) // index(0..), line(1..), column(1..)
    //func advances(in range:Range<Int>) -> [CGFloat]
    //func advance(for character:Character) -> CGFloat
    //func countLines() -> Int
}

// 書き込み可能プロトコル（読み取り継承なし）
protocol KTextStorageWritable: KTextStorageCommon {
    var string: String { get set }
    var baseFont: NSFont { get set }

    @discardableResult
    func replaceCharacters(in range: Range<Int>, with characters: [Character]) -> Bool
    
    @discardableResult
    func replaceString(in range: Range<Int>, with newString: String) -> Bool

    @discardableResult
    func insertCharacters(_ characters: [Character], at index: Int) -> Bool

    @discardableResult
    func insertCharacter(_ character: Character, at index: Int) -> Bool

    @discardableResult
    func insertString(_ string: String, at index: Int) -> Bool

    @discardableResult
    func deleteCharacters(in range: Range<Int>) -> Bool
}

// 両対応型（明示的に定義）
typealias KTextStorageProtocol = KTextStorageReadable & KTextStorageWritable

// MARK: - KTextStorage

// Ganpi用軽量テキストストレージ
final class KTextStorage: KTextStorageProtocol {
    // MARK: - Enum and Struct
    
    
    // attribute runの仮実装
    struct KAttributeRun {
        let range: Range<Int>
        let attributes: [NSAttributedString.Key: Any]
    }
    
    private struct _ObserverEntry {
        weak var owner: AnyObject?
        let handler: (KStorageModified) -> Void
    }
    

    // MARK: - Properties

    // data.
    private(set) var _characters: [Character] = []
    private var _observers: [_ObserverEntry] = []
    private lazy var _parser: KSyntaxParserProtocol = KSyntaxParserPlain(storage: self)
    private var _skeletonString: KSkeletonStringInUTF8 = .init()
    
    // propaties for appearances.
    private var _baseFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    //private var _lineNumberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11 ,weight: .regular)
    //private var _lineNumberFontEmph: NSFont = .monospacedDigitSystemFont(ofSize: 11 ,weight: .bold)
    private var _lineNumberFont: NSFont =
        NSFont(name: "Menlo-Regular", size: 11) ??
        .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var _lineNumberFontEmph: NSFont = NSFont(name: "Menlo-Bold", size: 11) ??
        .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    
    // caches.
    private var _spaceAdvanceCache: CGFloat?
    private var _hardLineCount: Int?
    //private var _hardLineRanges: [Range<Int>]?
    private var _invisibleCharacters: KInvisibleCharacters?
    private var _lineNumberCharacterMaxWidth: CGFloat?
    
    // for undo.
    private lazy var _undoManager: KUndoManager = .init(with: self)
    
    // constants.
    private let _characterCacheLoadLimit: Int = 100_000

    // MARK: - Public API

    var count: Int { _characters.count }
    
    var string: String {
        get { String(_characters) }
        set { characters = Array(newValue) }
    }
    
    var characters: [Character] { // 将来的に内部データが[Character]でなくなる可能性あり。
        get { _characters }
        set {
            replaceCharacters(in: 0..<_characters.count, with: newValue)
        }
    }
    
    var skeletonString: KSkeletonStringInUTF8 {
        get { _skeletonString }
    }

    var baseFont: NSFont {
        get { _baseFont }
        set {
            _baseFont = newValue
            resetCaches()
            notifyColoringChanged(in: 0..<_characters.count)
        }
    }

    var fontSize: CGFloat {
        get { _baseFont.pointSize }
        set {
            _baseFont = _baseFont.withSize(newValue)
            resetCaches()
            notifyColoringChanged(in: 0..<_characters.count)
        }
    }
    
    // 行番号表示に使用するフォント
    var lineNumberFont: NSFont {
        get { _lineNumberFont }
        set {
            _lineNumberFont = newValue
            _lineNumberCharacterMaxWidth = nil
        }
    }
    
    // 行番号表示に使用するフォント。強調表示用。
    var lineNumberFontEmph: NSFont {
        get { _lineNumberFont }
        set {
            _lineNumberFontEmph = newValue
            _lineNumberCharacterMaxWidth = nil
        }
    }
    
    var fontSizeOfLineNumber: CGFloat {
        get { _lineNumberFont.pointSize }
        set {
            _lineNumberFont = _lineNumberFont.withSize(newValue)
            _lineNumberFontEmph = _lineNumberFontEmph.withSize(newValue)
        }
    }
    
    // 行番号用の数字の最大 advance 幅（通常/強調の両方を考慮してキャッシュ）
    var lineNumberCharacterMaxWidth: CGFloat {
        if let cachedWidth = _lineNumberCharacterMaxWidth {
            return cachedWidth
        }

        func maxDigitAdvance(for font: NSFont) -> CGFloat {
            let ctFont = font as CTFont
            var maxAdvanceWidth: CGFloat = 0
            for scalar in "0123456789".unicodeScalars {
                var glyph = CGGlyph()
                var unicodeValue = UniChar(scalar.value)
                guard CTFontGetGlyphsForCharacters(ctFont, &unicodeValue, &glyph, 1) else { continue }
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
                if advance.width > maxAdvanceWidth {
                    maxAdvanceWidth = advance.width
                }
            }
            return maxAdvanceWidth
        }

        // 通常フォントと強調フォントの両方で確認し、最大値を採用
        let normalWidth = maxDigitAdvance(for: _lineNumberFont)
        let emphasizedWidth = maxDigitAdvance(for: _lineNumberFontEmph)
        let maxWidth = ceil(max(normalWidth, emphasizedWidth))

        _lineNumberCharacterMaxWidth = maxWidth
        return maxWidth
    }
    
    
    var characterSlice: ArraySlice<Character> {
        _characters[_characters.indices]
    }
    
    var invisibleCharacters: KInvisibleCharacters? {
        if let invisibleCharacters = _invisibleCharacters {
            return invisibleCharacters
        }
        let attr: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        _invisibleCharacters = KInvisibleCharacters(attributes: attr)
        return _invisibleCharacters
    }
    
    
    // 論理行の数を返す。
    var hardLineCount: Int {
        
        if let hardLineCount = _hardLineCount {
            return hardLineCount
        }
        var count = 1
        for c in _characters { if c == "\n" { count += 1 } }
        _hardLineCount = count
        return count
         
    }
    
    // タブ幅の元になるspaceの幅を返す。
    var spaceAdvance: CGFloat {
        if let cached = _spaceAdvanceCache {
            return cached
        }
        let newCache = " ".size(withAttributes: [.font: baseFont]).width
        _spaceAdvanceCache = newCache
        return newCache
    }
    
    private var parser: KSyntaxParserProtocol {
        get { _parser }
        set {
            _parser = newValue
            _parser.noteEdit(oldRange: 0..<count, newCount: count)
            //_parser.ensureUpToDate(for: 0..<count)
            notifyObservers(.colorChanged(range: 0..<count))
        }
    }
    
    
    init() {
        
        _invisibleCharacters = KInvisibleCharacters()
                
    }

    // 最終的に全ての文字列の変更はこのメソッドを通じて行う。
    @discardableResult
    func replaceCharacters(in range: Range<Int>, with newCharacters: [Character]) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound <= _characters.count,
              range.lowerBound <= range.upperBound else {
            return false
        }
        
        // undo. registering.
        _undoManager.register(range: range, oldString: String(_characters[range]), newString: String(newCharacters))
        
        
        // 改行の数が旧テキストと新テキストで異なれば_hardLineCountが変化する。
        let oldReturnCount = _characters[range].filter { $0 == "\n" }.count
        let newReturnCount = newCharacters.filter { $0 == "\n" }.count
        if oldReturnCount != newReturnCount {
            _hardLineCount = nil
        }
        
        // replacement.
        _characters.replaceSubrange(range, with: newCharacters)
        _skeletonString.replaceCharacters(range, with: newCharacters)

        // 構文カラーリングのパーサーに通す。
        _parser.noteEdit(oldRange: range, newCount: newCharacters.count)
        
        // notification.
        let timer = KTimeChecker(name:"observer")
        notifyObservers(.textChanged(
                info: .init(
                    range: range,
                    insertedCount: newCharacters.count,
                    deletedNewlineCount: oldReturnCount,
                    insertedNewlineCount: newReturnCount
                )
            )
        )
        timer.stop()
        
        // undo. recovery.
        //_undoManager.appendUndoAction(with: .none)
        
        
        return true
    }
    
    @discardableResult
    func replaceString(in range: Range<Int>, with newString: String) -> Bool {
        replaceCharacters(in: range, with: Array(newString))
    }

    @discardableResult
    func insertCharacters(_ newCharacters: [Character], at index: Int) -> Bool {
        replaceCharacters(in: index..<index, with: newCharacters)
    }

    @discardableResult
    func insertCharacter(_ newCharacter: Character, at index: Int) -> Bool {
        insertCharacters([newCharacter], at: index)
    }

    @discardableResult
    func insertString(_ newString: String, at index: Int) -> Bool {
        insertCharacters(Array(newString), at: index)
    }

    @discardableResult
    func deleteCharacters(in range: Range<Int>) -> Bool {
        replaceCharacters(in: range, with: [])
    }
    
    subscript(index: Int) -> Character? {
        guard index >= 0, index < _characters.count else { return nil }
        return _characters[index]
    }
    
    subscript(range: Range<Int>) -> ArraySlice<Character>? {
        guard range.lowerBound >= 0 && range.upperBound <= _characters.count else { return nil }
        return _characters[range]
    }
    
    
    
    // MARK: - Undo functions
    
    func undo() { _undoManager.undo() }
    func redo() { _undoManager.redo() }
    func canUndo() -> Bool { return _undoManager.canUndo() }
    func canRedo() -> Bool { return _undoManager.canRedo() }
    func resetUndoHistory() { _undoManager.resetUndoHistory() }
    
    
    // MARK: - Utilities
    
    // index文字目のある場所を含む行のRangeを返す。改行は含まない。
    func lineRange(at index: Int) -> Range<Int>? {
        guard index >= 0 && index <= _characters.count else { log("index out of range.",from:self); return nil }
        
        
        var lower = index
        while lower > 0 {
            if skeletonString.bytes[lower - 1] == FuncChar.lf { break }
            lower -= 1
        }
        var upper = index
        while upper < count {
            if skeletonString.bytes[upper] == FuncChar.lf { break }
            upper += 1
        }
        return lower..<upper
    }

    
    // attributeの変更についてはテキストの変更時に自動ではなくattributeの変更の際に手動で送信する。
    func notifyColoringChanged(in range: Range<Int>) {
        //_attributeVersion &+= 1
        notifyObservers(.colorChanged(range: range))
    }

    
    // TextStorageのindexを含む単語を返す。
    // 現在の実装では一般的な英単語に準じた単語判定だが、将来的には開発言語毎に調整した方がよいと思われる。
    func wordRange(at index: Int) -> Range<Int>? {
        if let spaceTabRange = spaceOrTabRunRange(at: index) { return spaceTabRange }
        if let japaneseRange = japaneseClusterRange(at: index) { return japaneseRange }
        if let parserRange = _parser.wordRange(at: index) { return parserRange }
        return asciiIdentifierRange(at: index)
        
    }
    
    
    // 指定した範囲からattributed stringを返す。parserによる色指定を含む。
    // withoutColors==trueで、parserによる色指定を無視してフォント・フォントサイズだけから高速に文字のoffset取得用attributed stringを返す。
    func attributedString(for range: Range<Int>,
                          tabWidth: Int? = nil,
                          withoutColors: Bool = false) -> NSAttributedString? {
        // 1) Character slice (indices are character-based and match skeleton indices)
        guard let slice = self[range] else { return nil }

        // 2) Detect tabs on skeleton and build output buffer with tab->space (except leading tabs)
        let skel = skeletonString.bytes(in: range) // 1 char == 1 byte ('a' for non-ASCII)
        var buffer: [Character] = []
        buffer.reserveCapacity(slice.count)

        var leadingTabsDone = false
        var iSkel = skel.startIndex
        var iChar = slice.startIndex
        while iSkel < skel.endIndex {
            let ch = slice[iChar]
            let isTab = (skel[iSkel] == FuncChar.tab)
            if !leadingTabsDone {
                if isTab {
                    buffer.append(ch)            // keep leading tabs
                } else {
                    leadingTabsDone = true
                    buffer.append(isTab ? " " : ch)
                }
            } else {
                buffer.append(isTab ? " " : ch)  // replace later tabs with space
            }
            slice.formIndex(after: &iChar)
            iSkel &+= 1
        }

        // 3) Base attributes (font + default color + optional paragraph style)
        var baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.black
        ]
        if let tabWidth = tabWidth {
            let ps = NSMutableParagraphStyle()
            ps.defaultTabInterval = CGFloat(tabWidth) * spaceAdvance
            baseAttrs[.paragraphStyle] = ps
        }

        // 4) Build attributed string with base attributes
        let fullString = String(buffer)
        let mas = NSMutableAttributedString(string: fullString, attributes: baseAttrs)

        // 5) Fast path: skip coloring entirely when requested (CTLine bootstrap, etc.)
        if withoutColors { return mas }
        
        // 5.5) Ensure parser state is up-to-date before applying colors
        _parser.ensureUpToDate(for: range)

        // 6) Apply syntax spans (character-offset based)
        let spans = _parser.attributes(in: range, tabWidth: tabWidth ?? 0)
        guard !spans.isEmpty else { return mas }

        @inline(__always)
        func nsRangeClipped(_ span: Range<Int>) -> NSRange? {
            let localLower = max(span.lowerBound - range.lowerBound, 0)
            let localUpper = min(span.upperBound - range.lowerBound, fullString.count)
            guard localUpper > localLower else { return nil }
            let s = fullString.index(fullString.startIndex, offsetBy: localLower)
            let e = fullString.index(fullString.startIndex, offsetBy: localUpper)
            return NSRange(s..<e, in: fullString)
        }

        var applied = 0
        for s in spans {
            if let r = nsRangeClipped(s.range) {
                mas.addAttributes(s.attributes, range: r)
                applied &+= 1
                //log("apply attrs range=\(s.range.lowerBound)..<\(s.range.upperBound) -> NSRange\(r)", from: self)
            } else {
                //log("skip attrs (out of slice) \(s.range.lowerBound)..<\(s.range.upperBound)", from: self)
            }
        }
        //log("applied spans: \(applied)/\(spans.count)", from: self)

        return mas
    }
    
    
    // 登録：owner を弱参照で保持。handler はクロージャ。
    func addObserver(_ owner: AnyObject, _ handler: @escaping (KStorageModified) -> Void) {
        // 既存の owner を一掃してから登録（重複防止）
        _observers.removeAll { $0.owner === owner || $0.owner == nil }
        _observers.append(_ObserverEntry(owner: owner, handler: handler))
    }

    // 解除：owner 一致だけ除去
    func removeObserver(_ owner: AnyObject) {
        _observers.removeAll { $0.owner === owner || $0.owner == nil }
    }
    
    // 指定したindexが論理行の何行目で、行頭から何文字目かを返す。いずれも1スタート。
    func lineAndColumNumber(at index:Int) -> (line:Int, column:Int) {
        guard index >= 0, index <= _skeletonString.bytes.count else {
            log("index is out of range.",from:self)
            return (0,0)
        }
        var lineNo = 1
        var columnNo = 1
        for i in 0..<index {
            let ch = _skeletonString.bytes[i]
            if ch == FuncChar.lf {
                lineNo += 1
                columnNo = 1
                continue
            }
            columnNo += 1
        }
        return (lineNo, columnNo)
    }

    
    func replaceParser(for type: KSyntaxType) {
        parser = type.makeParser(storage: self)
    }
    
    
    // MARK: - Private

    // 通知：同期。死んだ参照はついでに掃除。
    private func notifyObservers(_ note: KStorageModified) {
        var alive: [_ObserverEntry] = []
        alive.reserveCapacity(_observers.count)
        for e in _observers {
            if let _ = e.owner {
                e.handler(note)
                alive.append(e)
            }
        }
        _observers = alive
    }
    
    private func resetCaches() {
        _spaceAdvanceCache = nil
        _invisibleCharacters = nil
        _lineNumberCharacterMaxWidth = nil
        
        fontSizeOfLineNumber = baseFont.pointSize - 1.0
        
    }
    
    // MARK: - wordRange helpers.
    
    // 空白文字とタブの連続を検出する。
    @inline(__always)
    private func spaceOrTabRunRange(at index: Int) -> Range<Int>? {
        let n = count
        let chars = characterSlice
        let base  = chars.startIndex
        
        var i = max(0, min(index, n))
        if i == n { i = max(0, n - 1) }
        
        @inline(__always) func isSpaceTab(_ ch: Character) -> Bool { ch == " " || ch == "\t" }
        
        let pivot = chars[base + i]
        guard isSpaceTab(pivot) else { return nil }
        
        var lo = i
        while lo > 0, isSpaceTab(chars[base + lo - 1]) { lo -= 1 }
        
        var hi = i + 1
        while hi < n, isSpaceTab(chars[base + hi]) { hi += 1 }
        
        return lo..<hi
    }


    // ひらがな/カタカナ/漢字クラスタ（ーは仮名に結合）
    @inline(__always)
    private func japaneseClusterRange(at index: Int) -> Range<Int>? {
        
        let n = count
        if n == 0 { return 0..<0 }
        
        let chars = characterSlice
        let base  = chars.startIndex
        
        // 末尾クリックは末尾-1を観察
        var i = max(0, min(index, n))
        if i == n { i = max(0, n - 1) }
        
        let pivot = chars[base + i]
        
        // クリックが長音そのもの → その1文字だけ
        if pivot._isKanaProlong { return i..<(i + 1) }
        
        // ピボットスクリプト（漢字/ひらがな/カタカナ）
        guard let script = pivot._jpScript else { return nil }
        
        // ひらがな/カタカナのときは長音を“同クラスタ扱い”にする
        @inline(__always)
        func matchesPivotScript(_ ch: Character) -> Bool {
            if (script == .hiragana || script == .katakana), ch._isKanaProlong { return true }
            if let s = ch._jpScript { return s == script }
            return false
        }
        
        var lo = i
        while lo > 0, matchesPivotScript(chars[base + lo - 1]) { lo -= 1 }
        
        var hi = i + 1
        while hi < n, matchesPivotScript(chars[base + hi]) { hi += 1 }
        
        return lo..<hi
    }

    // --- 3) ASCII 識別子（[A-Za-z0-9_]+）。該当しないなら “空選択” を返す ---
    @inline(__always)
    private func asciiIdentifierRange(at index: Int) -> Range<Int>? {
        let n = count
        let chars = characterSlice
        let base  = chars.startIndex
        
        var i = max(0, min(index, n))
        if i == n { i = max(0, n - 1) }
        
        @inline(__always)
        func isAsciiIdent(_ ch: Character) -> Bool {
            guard ch.unicodeScalars.allSatisfy({ $0.value <= 0x7F }) else { return false }
            if let u = ch.unicodeScalars.first?.value {
                return (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) ||
                (0x61...0x7A).contains(u) || u == 0x5F
            }
            return false
        }
        
        let p = chars[base + i]
        guard isAsciiIdent(p) else { return i..<i }   // 記号などは“空選択”
        
        var lo = i
        while lo > 0, isAsciiIdent(chars[base + lo - 1]) { lo -= 1 }
        var hi = i + 1
        while hi < n, isAsciiIdent(chars[base + hi]) { hi += 1 }
        
        return lo..<hi
    }
    
}


