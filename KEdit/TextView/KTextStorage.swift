//
//  KTextStorage.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa
import AppKit
import TreeSitterBridge

// MARK: - General enum and struct

// Observingに使用するenumとstruct
struct KStorageModifiedInfo {
    let range: Range<Int>
    let insertedCount: Int
    let deletedNewlineCount: Int
    let insertedNewlineCount: Int
}

enum KStorageModified {
    //case textChanged(range: Range<Int>, insertedCount: Int)
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
    
    func addObserver(_ observer: @escaping (KStorageModified) -> Void)
}

// 読み取り専用プロトコル
protocol KTextStorageReadable: KTextStorageCommon {
    var string: String { get }
    var skeletonString: KSkeletonStringInUTF8 { get }
    var hardLineCount: Int { get } // if _character is empty, return 1. if end of chars is '\n', add 1.
    var invisibleCharacters: KInvisibleCharacters? { get }
    var spaceAdvance: CGFloat { get }
    var lineNumberCharacterMaxWidth: CGFloat { get }
    var lineNumberFont: NSFont { get }
    var lineNumberFontEmph: NSFont { get }
    
    func wordRange(at index: Int) -> Range<Int>?
    func attributedString(for range: Range<Int>, tabWidth: Int?, withoutColors: Bool) -> NSAttributedString?
    func lineRange(at index: Int) -> Range<Int>?
    //func advances(in range:Range<Int>) -> [CGFloat]
    //func advance(for character:Character) -> CGFloat
    //func countLines() -> Int
}

// 書き込み可能プロトコル（読み取り継承なし）
protocol KTextStorageWritable: KTextStorageCommon {
    var string: String { get set }

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

// KEdit用軽量テキストストレージ
final class KTextStorage: KTextStorageProtocol {
    // MARK: - Enum and Struct
    
    
    // attribute runの仮実装
    struct KAttributeRun {
        let range: Range<Int>
        let attributes: [NSAttributedString.Key: Any]
    }
    
    // Undo用
    struct KUndoUnit {
        let range: Range<Int>
        let oldCharacters: [Character]
        let newCharacters: [Character]
    }
    
    enum KUndoAction {
        case undo
        case redo
        case none
    }
    

    // MARK: - Properties

    // data.
    private(set) var _characters: [Character] = []
    private var _observers: [(KStorageModified) -> Void] = []
    //private lazy var _parser: KSyntaxParser = KSyntaxParser(textStorage: self, type: .ruby)
    private lazy var _parser: KSyntaxParserProtocol = KSyntaxParserRuby(storage: self, identifierChars: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_", keywords: ["def","class","self","nil"])
    
    private var _skeletonString: KSkeletonStringInUTF8 = .init()
    
    // propaties for appearances.
    private var _baseFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var _lineNumberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11 ,weight: .regular)
    private var _lineNumberFontEmph: NSFont = .monospacedDigitSystemFont(ofSize: 11 ,weight: .bold)
    
    // caches.
    private var _spaceAdvanceCache: CGFloat?
    private var _hardLineCount: Int?
    private var _invisibleCharacters: KInvisibleCharacters?
    private var _lineNumberCharacterMaxWidth: CGFloat?
    
    // for undo.
    private var _history: KRingBuffer<KUndoUnit> = .init(capacity: 5000)
    private var _undoDepth: Int = 0
    private var _undoActions: KRingBuffer<KUndoAction> = .init(capacity: 2)
    
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
            //_lineNumberDigitWidth = nil
            _lineNumberCharacterMaxWidth = nil
        }
    }
    
    // 行番号表示に使用するフォント。強調表示用。
    var lineNumberFontEmph: NSFont {
        get { _lineNumberFont }
        set {
            _lineNumberFontEmph = newValue
            //_lineNumberDigitWidth = nil
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
    
    // 行番号表示に使用する数字の最大の横幅。
    var lineNumberCharacterMaxWidth: CGFloat {
        if let width = _lineNumberCharacterMaxWidth {
            return width
        }
        
        let digits: [Character] = Array("0123456789")
        let ctFont = _lineNumberFontEmph as CTFont

        var maxWidth: CGFloat = 0

        for char in digits {
            guard let scalar = char.unicodeScalars.first else { continue }
            let uniChar = UniChar(scalar.value)
            var glyph = CGGlyph()
            let success = CTFontGetGlyphsForCharacters(ctFont, [uniChar], &glyph, 1)
            if success {
                var advance: CGSize = .zero
                CTFontGetAdvancesForGlyphs(ctFont, .horizontal, [glyph], &advance, 1)
                maxWidth = max(maxWidth, advance.width)
            }
        }
        return maxWidth
    }
    
    
    var characterSlice: ArraySlice<Character> {
        _characters[_characters.indices]
    }
    
    var invisibleCharacters: KInvisibleCharacters? {
        if let invisibleCharacters = _invisibleCharacters {
            return invisibleCharacters
        }
        _invisibleCharacters = KInvisibleCharacters()
        return _invisibleCharacters
    }
    
    // 初期値として文字列をセットする際に使用する。
    // ドキュメントからの読み込み時に限定して使用。Undoは反応しない。
    /*
    func setDefaultString(_ string: String) {
        _characters = Array(string)
        _history.reset()
    }*/
    /*
    var lineNumberDigitWidth: CGFloat {
        //if let width = _lineNumberDigitWidth {
        if let width = _lineNumberCharacterMaxWidth {
            return width
        }
        let attrStr = NSAttributedString(string: "M", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: _baseFont.pointSize * 0.95, weight: .regular)])
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        let charWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        return charWidth
    }*/
    
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
    
    
    init() {
        // undoのアクションを先に2回分埋めておく。
        _undoActions.append(.none)
        _undoActions.append(.none)
        
        //_advanceCache = KGlyphAdvanceCache(font: _baseFont)
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
        if _undoActions.element(at: 0)! == .none {
            let undoUnit = KUndoUnit(range: range, oldCharacters: Array(_characters[range]), newCharacters: newCharacters)
            if _undoActions.element(at: 1)! != .none {
                _history.removeNewerThan(index: _undoDepth)
                _undoDepth = 0
            }
            
            _history.append(undoUnit)
        }
        
        // 改行の数が旧テキストと新テキストで異なれば_hardLineCountが変化する。
        let oldReturnCount = _characters[range].filter { $0 == "\n" }.count
        let newReturnCount = newCharacters.filter { $0 == "\n" }.count
        if oldReturnCount != newReturnCount {
            _hardLineCount = nil
        }
        let timer0 = KTimeChecker(name:"replace and parse")
        timer0.start(message: "replacing characters")
        // replacement.
        _characters.replaceSubrange(range, with: newCharacters)
        _skeletonString.replaceCharacters(range, with: newCharacters)
        timer0.stopAndGo(message: "parsing")
        // 構文カラーリングのパーサーに通す。現在は全文。
        //_parser.parse(range.lowerBound..<range.upperBound + newCharacters.count - range.count)
        //_parser.parse(range:0..<count)
        _parser.noteEdit(oldRange: range, newCount: newCharacters.count)
        timer0.stop()
        
        // notification.
        let timer = KTimeChecker(name:"observer")
        notifyObservers(.textChanged(info: KStorageModifiedInfo(range:range, insertedCount: newCharacters.count, deletedNewlineCount: oldReturnCount, insertedNewlineCount: newReturnCount)))
        timer.stop()
        
        // undo. recovery.
        _undoActions.append(.none)
        
        
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
    

    func addObserver(_ observer: @escaping ((KStorageModified) -> Void)){
        //print("\(#function)")
        _observers.append(observer)
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
    
    func undo() {
        guard _undoDepth < _history.count else {
            NSSound.beep() // NSBeep()がなぜか使用できないためObjective-Cブリッジ経由で。
            log("undo: no more history", from: self)
            return
        }

        _undoActions.append(.undo)

        guard let undoUnit = _history.element(at: _undoDepth) else { log("undo: failed to get undoUnit at \(_undoDepth)", from: self); return }

        let range = undoUnit.range.lowerBound..<undoUnit.range.lowerBound + undoUnit.newCharacters.count
        replaceCharacters(in: range, with: undoUnit.oldCharacters)

        _undoDepth += 1
    }
    
    func redo() {
        guard _undoDepth > 0 else {
            NSSound.beep()
            log("redo: no redo available", from: self)
            return
        }

        _undoActions.append(.redo)

        let redoIndex = _undoDepth - 1

        guard let undoUnit = _history.element(at: redoIndex) else { log("redo: failed to get redoUnit at \(redoIndex)", from: self); return }

        replaceCharacters(in: undoUnit.range, with: undoUnit.newCharacters)

        _undoDepth -= 1
    }
    
    func canUndo() -> Bool {
        return _undoDepth < _history.count
    }

    func canRedo() -> Bool {
        return _undoDepth > 0
    }
    
    func resetUndoHistory() {
        _history.reset()
        _undoDepth = 0
    }
    
    
    
    // MARK: - Utilities
    
    // index文字目のある場所を含む行のRangeを返す。改行は含まない。
    func lineRange(at index: Int) -> Range<Int>? {
        guard index >= 0 && index < _characters.count else { return nil }

        var lower = index
        while lower > 0 {
            if _characters[lower - 1].isNewline {
                break
            }
            lower -= 1
        }

        var upper = index
        while upper < _characters.count {
            if _characters[upper].isNewline {
                break
            }
            upper += 1
        }

        return lower..<upper
    }
    
    /*
    // 論理行の行数を返す。最後が改行の場合は改行後にも1行あるとみなす。
    func countLines() -> Int {
        let timer = KTimeChecker(name: "countLines()")
        timer.start()
        var count = 0
        for c in _characters {
            if c == "\n" { count += 1 }
        }
        timer.stop()
        return count + 1
    }*/

    
    // attributeの変更についてはテキストの変更時に自動ではなくattributeの変更の際に手動で送信する。
    func notifyColoringChanged(in range: Range<Int>) {
        //_attributeVersion &+= 1
        notifyObservers(.colorChanged(range: range))
    }

    
    // TextStorageのindexを含む単語を返す。
    // 現在の実装では一般的な英単語に準じた単語判定だが、将来的には開発言語毎に調整した方がよいと思われる。
    func wordRange(at index: Int) -> Range<Int>? {

        guard index >= 0 && index < count else { return nil }

        // Characterベース → String → NSString → UTF16でのインデックス位置を取得
        let characterArray = Array(characterSlice)
        let prefixString = String(characterArray.prefix(index))
        let utf16Offset = prefixString.utf16.count
        
        // NSStringでトークンを取得
        let nsString = NSString(string: String(characterArray))
        let cfTokenizer = CFStringTokenizerCreate(nil, nsString, CFRangeMake(0, nsString.length), kCFStringTokenizerUnitWord, nil)
        CFStringTokenizerGoToTokenAtIndex(cfTokenizer, utf16Offset)
        let tokenRange = CFStringTokenizerGetCurrentTokenRange(cfTokenizer)
        
        // tokenRangeが存在しない場合にはnilを返す
        guard tokenRange.location != kCFNotFound else { return nil }
        
        // 範囲の変換（UTF-16 → Characterインデックス）
        let utf16View = nsString as String
        guard let fromUTF16 = utf16View.utf16.index(utf16View.utf16.startIndex, offsetBy: tokenRange.location, limitedBy: utf16View.utf16.endIndex),
              let toUTF16 = utf16View.utf16.index(fromUTF16, offsetBy: tokenRange.length, limitedBy: utf16View.utf16.endIndex),
              let start = fromUTF16.samePosition(in: utf16View),
              let end = toUTF16.samePosition(in: utf16View)
        else {
            return nil
        }

        let startIndex = utf16View.distance(from: utf16View.startIndex, to: start)
        let endIndex = utf16View.distance(from: utf16View.startIndex, to: end)
        return startIndex..<endIndex
    }
    
    
    
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
    /*func attributedString(for range: Range<Int>, tabWidth: Int? = nil) -> NSAttributedString? {
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

        // 5) パーサのスパンを取得（文字オフセット前提）
        let spans = _parser.attributes(in: range, tabWidth: tabWidth ?? 0)
        guard !spans.isEmpty else { return mas }

        //let fullString = String(buffer)

        // 文字オフセット → NSRange 変換（安全クリップ付き）
        @inline(__always)
        func nsRangeClipped(_ span: Range<Int>) -> NSRange? {
            let localLower = max(span.lowerBound - range.lowerBound, 0)
            let localUpper = min(span.upperBound - range.lowerBound, fullString.count)
            guard localUpper > localLower else { return nil }
            let s = fullString.index(fullString.startIndex, offsetBy: localLower)
            let e = fullString.index(fullString.startIndex, offsetBy: localUpper)
            return NSRange(s..<e, in: fullString)
        }

        // 適用＆ログ
        var applied = 0
        for s in spans {
            if let r = nsRangeClipped(s.range) {
                mas.addAttributes(s.attributes, range: r)
                applied &+= 1
                log("apply attrs range=\(s.range.lowerBound)..<\(s.range.upperBound) -> NSRange\(r)", from: self)
            } else {
                log("skip attrs (out of slice) \(s.range.lowerBound)..<\(s.range.upperBound)", from: self)
            }
        }
        log("applied spans: \(applied)/\(spans.count)", from: self)

        return mas
    }*/
    
    /*
    // 与えられたRangeの範囲のテキストをNSAttributedStringとして返す。
    // 現在仮実装。最終的にtree-sitterによる色分けを行う予定。
    func attributedString(for range: Range<Int>, tabWidth: Int? = nil) -> NSAttributedString? {
        guard let slice = self[range] else { return nil }
        
        // 冒頭の連続したtab以外のtabを全てspaceに入れ替える。
        // 本来は行頭であるか確認するべきだが、問題になるのは現時点でfake lineのみのため気にしないことにする。
        let tabChar:Character = "\t"
        let spaceChar:Character = " "
        var convertedSlice:[Character] = []
        var leadingTabsDone = false
        
        for char in slice {
            if !leadingTabsDone {
                if char == tabChar {
                    convertedSlice.append(char)
                } else {
                    leadingTabsDone = true
                    convertedSlice.append(char == tabChar ? spaceChar : char)
                }
            } else {
                convertedSlice.append(char == tabChar ? spaceChar : char)
            }
        }

        // 仮実装：全体に一律の属性を与える
        var attributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.black]
        //if tabWidth != nil {
        if let tabWidth = tabWidth {
            let paragraphStyle = NSMutableParagraphStyle()
            //paragraphStyle.defaultTabInterval = CGFloat(tabWidth!) * _tabWidthCache!
            paragraphStyle.defaultTabInterval = CGFloat(tabWidth) * spaceAdvance
            attributes[.paragraphStyle] = paragraphStyle
        }
        
        let attributeRun = KTextStorage.KAttributeRun(
            range: characterSlice.startIndex..<characterSlice.endIndex,
            attributes: attributes
        )
        let attributeRuns = [attributeRun]

        let result = NSMutableAttributedString()
        for run in attributeRuns {
            let overlap = run.range.clamped(to: range)
            if overlap.count == 0 { continue }
            
            // ArraySliceのstartIndex補正
            /*
            let lowerOffset = overlap.lowerBound - range.lowerBound
            let upperOffset = overlap.upperBound - range.lowerBound
            
            let lowerIndex = slice.index(slice.startIndex, offsetBy: lowerOffset)
            let upperIndex = slice.index(slice.startIndex, offsetBy: upperOffset)
            let subSlice = slice[lowerIndex..<upperIndex]
            let string = String(subSlice)*/
            
            let lowerOffset = overlap.lowerBound - range.lowerBound
            let upperOffset = overlap.upperBound - range.lowerBound
            
            let subSlice = convertedSlice[lowerOffset..<upperOffset]
            let string = String(subSlice)

            result.append(NSAttributedString(string: string, attributes: run.attributes))
        }
        return result
    }*/
    
    /*func attributedString(for range: Range<Int>, tabWidth: Int? = nil) -> NSAttributedString? {
        guard let slice = self[range] else { return nil }

        let tabChar: Character = "\t"
        let spaceChar: Character = " "
        var convertedSlice: [Character] = []
        var leadingTabsDone = false

        for char in slice {
            if !leadingTabsDone {
                if char == tabChar {
                    convertedSlice.append(char)
                } else {
                    leadingTabsDone = true
                    convertedSlice.append(char == tabChar ? spaceChar : char)
                }
            } else {
                convertedSlice.append(char == tabChar ? spaceChar : char)
            }
        }

        // 基本属性（地の色）
        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: KSyntaxParser.KSyntaxColorType.default.color
        ]

        if let tabWidth = tabWidth {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.defaultTabInterval = CGFloat(tabWidth) * spaceAdvance
            baseAttributes[.paragraphStyle] = paragraphStyle
        }

        // AttributedStringをベース色で作成
        let result = NSMutableAttributedString(
            string: String(convertedSlice),
            attributes: baseAttributes
        )

        // syntax parser から対象範囲の構文情報を取得
        let spans = _parser.highlightSpans(in: range)
        //print("Got \(spans.count) spans in range \(range)")
        // 各spanに対して属性を上書き適用
        /*
        for span in spans {
            let localLower = span.range.lowerBound - range.lowerBound
            let localUpper = span.range.upperBound - range.lowerBound

            guard localLower >= 0, localUpper <= convertedSlice.count, localLower < localUpper else { continue }

            let nsRange = NSRange(location: localLower, length: localUpper - localLower)
            result.addAttribute(.foregroundColor, value: span.kind.colorType.color, range: nsRange)
        }*/
        for span in spans {
            //print("Span: \(span.range), kind: \(span.kind)")
            let overlap = span.range.clamped(to: range)
            guard !overlap.isEmpty else { continue }

            let nsRange = NSRange(
                location: overlap.lowerBound - range.lowerBound,
                length: overlap.count
            )

            result.addAttribute(.foregroundColor, value: span.kind.colorType.color, range: nsRange)
        }

        return result
    }*/
    
    // 与えられた範囲のadvanceの配列を返す。
    /*
    func advances(in range:Range<Int>) -> [CGFloat] {
        return _advanceCache.advances(for: _characters, in: range)
    }
    
    func advance(for character:Character) -> CGFloat {
        return _advanceCache.advance(for: character)
    }*/
    
    
    
    
    // MARK: - Private

    private func notifyObservers(_ event: KStorageModified) {
        _observers.forEach { $0(event) }
    }
    
    private func resetCaches() {
        //_advanceCache = KGlyphAdvanceCache(font: _baseFont)
        //_advanceCache.setParticularCache(spaceAdvance, for: "\t")
        _spaceAdvanceCache = nil
        //_lineNumberDigitWidth = nil
        _invisibleCharacters = nil
        _lineNumberCharacterMaxWidth = nil
        
        fontSizeOfLineNumber = baseFont.pointSize - 1.0
        
    }
    
    
}



