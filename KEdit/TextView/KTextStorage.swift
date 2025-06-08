//
//  KTextStorage.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

/// KEdit用軽量テキストストレージ（[Character]ベース）
final class KTextStorage {

    // MARK: - Properties

    private var characters: [Character] = []
    private var observers: [() -> Void] = []
    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    // MARK: - Public API

    var count: Int { characters.count }

    var string: String {
        get { String(characters) }
        set { characters = Array(newValue); notifyObservers() }
    }
    
    var chars: [Character] {
        get { characters }
        set { characters = newValue; notifyObservers()}
    }

    var baseFont: NSFont {
        get { font }
        set {
            font = newValue
            notifyObservers()
        }
    }

    var fontSize: CGFloat {
        get { font.pointSize }
        set {
            font = font.withSize(newValue)
            notifyObservers()
        }
    }

    @discardableResult
    func replaceCharacters(in range: Range<Int>, with newCharacters: [Character]) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound <= characters.count,
              range.lowerBound <= range.upperBound else {
            return false
        }

        characters.replaceSubrange(range, with: newCharacters)
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
    

    func characters(in range: Range<Int>) -> ArraySlice<Character>? {
        guard range.lowerBound >= 0,
              range.upperBound <= characters.count,
              range.lowerBound <= range.upperBound else {
            return nil
        }
        
        return characters[range]
    }

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    // MARK: - Private

    private func notifyObservers() {
        observers.forEach { $0() }
    }
}
