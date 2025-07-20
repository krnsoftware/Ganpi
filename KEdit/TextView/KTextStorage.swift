//
//  KTextStorage.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

// MARK: - General enum and struct

// Observingに使用するenum
enum KStorageModified {
    case textChanged(range: Range<Int>, insertedCount: Int)
    case colorChanged(range: Range<Int>)
}

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
    //var characterVersion: UInt64 { get }
    //var attributeVersion: UInt64 { get }
    subscript(index: Int) -> Character? { get }
    subscript(range: Range<Int>) -> ArraySlice<Character>? { get }
    
    //func addObserver(_ observer: @escaping () -> Void)
    func addObserver(_ observer: @escaping (KStorageModified) -> Void)
}

// 読み取り専用プロトコル
protocol KTextStorageReadable: KTextStorageCommon {
    var string: String { get }
    
    func wordRange(at index: Int) -> Range<Int>?
    func attributedString(for range: Range<Int>, tabWidth: Int?) -> NSAttributedString?
    func lineRange(at index: Int) -> Range<Int>?
    //func characterIndex(c: Character, from: Int, direction: KDirection) -> Int?
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

    private(set) var _characters: [Character] = []
    private var _observers: [(KStorageModified) -> Void] = []
    private var _baseFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var _tabWidthCache: CGFloat?
    
    // data version
    //private var _characterVersion: UInt64 = 0
    //private var _attributeVersion: UInt64 = 0
    
    // for undo.
    private var _history: KRingBuffer<KUndoUnit> = .init(capacity: 5000)
    private var _undoDepth: Int = 0
    private var _undoActions: KRingBuffer<KUndoAction> = .init(capacity: 2)

    // MARK: - Public API

    var count: Int { _characters.count }
    
    var string: String {
        get { String(_characters) }
        set { characters = Array(newValue) }
    }
    
    var characters: [Character] { // 将来的に内部データが[Character]でなくなる可能性あり。
        get { _characters }
        set {
            replaceCharacters(in: 0..<newValue.count, with: newValue)
        }
    }

    var baseFont: NSFont {
        get { _baseFont }
        set {
            _baseFont = newValue
            _tabWidthCache = nil
            notifyColoringChanged(in: 0..<_characters.count)
        }
    }

    var fontSize: CGFloat {
        get { _baseFont.pointSize }
        set {
            _baseFont = _baseFont.withSize(newValue)
            notifyColoringChanged(in: 0..<_characters.count)
        }
    }
    
    
    var characterSlice: ArraySlice<Character> {
        _characters[_characters.indices]
    }
    
    // 初期値として文字列をセットする際に使用する。
    // ドキュメントからの読み込み時に限定して使用。Undoは反応しない。
    func setDefaultString(_ string: String) {
        _characters = Array(string)
        _history.reset()
        //_characterVersion &+= 1
        //_attributeVersion &+= 1
    }
    
    //var characterVersion: UInt64 { _characterVersion }
    //var attributeVersion: UInt64 { _attributeVersion }
    
    
    init() {
        // undoのアクションを先に2回分埋めておく。
        _undoActions.append(.none)
        _undoActions.append(.none)
    }

    // 最終的に全ての文字列の変更はこのメソッドを通じて行う。
    @discardableResult
    func replaceCharacters(in range: Range<Int>, with newCharacters: [Character]) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound <= _characters.count,
              range.lowerBound <= range.upperBound else {
            return false
        }
        
        if _undoActions.element(at: 0)! == .none {
            let undoUnit = KUndoUnit(range: range, oldCharacters: Array(_characters[range]), newCharacters: newCharacters)
            if _undoActions.element(at: 1)! != .none {
                _history.removeNewerThan(index: _undoDepth)
                _undoDepth = 0
            }
            
            _history.append(undoUnit)
        }

        _characters.replaceSubrange(range, with: newCharacters)
        notifyObservers(.textChanged(range: range, insertedCount: newCharacters.count))
        
        _undoActions.append(.none)
        //_characterVersion &+= 1
        //_attributeVersion &+= 1
        
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
        guard _undoDepth < _history.count else { log("undo: no more history", from: self); return }

        _undoActions.append(.undo)

        guard let undoUnit = _history.element(at: _undoDepth) else { log("undo: failed to get undoUnit at \(_undoDepth)", from: self); return }

        let range = undoUnit.range.lowerBound..<undoUnit.range.lowerBound + undoUnit.newCharacters.count
        replaceCharacters(in: range, with: undoUnit.oldCharacters)

        _undoDepth += 1
    }
    
    func redo() {
        guard _undoDepth > 0 else { log("redo: no redo available", from: self); return }

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
    
    
    // 与えられたRangeの範囲のテキストをNSAttributedStringとして返す。
    // 現在仮実装。最終的にtree-sitterによる色分けを行う予定。
    func attributedString(for range: Range<Int>, tabWidth: Int? = nil) -> NSAttributedString? {
        guard let slice = self[range] else { return nil }
        
        if _tabWidthCache == nil {
            //_tabWidthCache = baseFont.advancement(forGlyph: baseFont.glyph(withName: "space")).width
            _tabWidthCache = " ".size(withAttributes: [.font: baseFont]).width
        }

        // 仮実装：全体に一律の属性を与える
        var attributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.black]
        if tabWidth != nil {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.defaultTabInterval = CGFloat(tabWidth!) * _tabWidthCache!
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
            let lowerOffset = overlap.lowerBound - range.lowerBound
            let upperOffset = overlap.upperBound - range.lowerBound

            let lowerIndex = slice.index(slice.startIndex, offsetBy: lowerOffset)
            let upperIndex = slice.index(slice.startIndex, offsetBy: upperOffset)
            let subSlice = slice[lowerIndex..<upperIndex]
            let string = String(subSlice)

            result.append(NSAttributedString(string: string, attributes: run.attributes))
        }
        return result
    }
    
    
    // MARK: - Private

    private func notifyObservers(_ event: KStorageModified) {
        _observers.forEach { $0(event) }
    }
}



