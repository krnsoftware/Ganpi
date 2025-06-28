//
//  KTextStorage.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

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
}

// 読み取り専用プロトコル
protocol KTextStorageReadable: KTextStorageCommon {
    var string: String { get }
}

// 書き込み可能プロトコル（読み取り継承なし）
protocol KTextStorageWritable: KTextStorageCommon {
    var string: String { get set }

    @discardableResult
    func replaceCharacters(in range: Range<Int>, with characters: [Character]) -> Bool

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
    enum KDirection: Int {
        case forward = 1
        case backward = -1
    }

    // MARK: - Properties

    private(set) var _characters: [Character] = []
    private var _observers: [() -> Void] = []
    private var _baseFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    // MARK: - Public API

    var count: Int { _characters.count }

    var string: String {
        get { String(_characters) }
        set { _characters = Array(newValue); notifyObservers() }
    }
    
    var characters: [Character] { // 将来的に内部データが[Character]でなくなる可能性あり。
        get { _characters }
        set { _characters = newValue; notifyObservers()}
    }

    var baseFont: NSFont {
        get { _baseFont }
        set {
            _baseFont = newValue
            notifyObservers()
        }
    }

    var fontSize: CGFloat {
        get { _baseFont.pointSize }
        set {
            _baseFont = _baseFont.withSize(newValue)
            notifyObservers()
        }
    }
    
    var characterSlice: ArraySlice<Character> {
        _characters[_characters.indices]
    }

    @discardableResult
    func replaceCharacters(in range: Range<Int>, with newCharacters: [Character]) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound <= _characters.count,
              range.lowerBound <= range.upperBound else {
            return false
        }

        _characters.replaceSubrange(range, with: newCharacters)
        notifyObservers()
        return true
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
    

    func addObserver(_ observer: @escaping () -> Void) {
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
    
    // MARK: - Utilities
    
    // 試しに実装したもの。
    func characterIndex(c: Character, from: Int, direction: KDirection = .forward) -> Int? {
        guard from >= 0 && from < characterSlice.count else { return nil }
        
        switch direction {
        case .forward:
            return characterSlice[from...].firstIndex(of: c)
        case .backward:
            return characterSlice[..<from].lastIndex(of: c)
        }
        
    }

    // MARK: - Private

    private func notifyObservers() {
        _observers.forEach { $0() }
    }
}

// MARK: - TextStorageReadable extension



extension KTextStorageReadable {
    
    // TextStorageのindexを含む単語を返す。
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
}



