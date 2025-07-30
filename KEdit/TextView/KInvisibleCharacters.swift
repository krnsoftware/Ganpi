//
//  KInvisibleCharacters.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KInvisibleCharacters {
    private var _dictionary: [Character: String]
    private var _cache: [Character: CTLine] = [:]
    private let _attributes: [NSAttributedString.Key: Any]
    
    private static let _defaultDictionary: [Character: String] = [
            "\u{0020}": "∙",    // SPACE → Middle Dot
            "\u{0009}": "➤",    // TAB → Right Arrow
            "\u{000A}": "⏎",    // LF → Return Symbol
            "\u{3000}": "□",     // 全角スペース
        ]
    
    private static let _defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

    init(attributes: [NSAttributedString.Key: Any] = _defaultAttributes,
             dictionary: [Character: String] = _defaultDictionary) {
            _attributes = attributes
            _dictionary = dictionary
        }

    func ctLine(for char: Character) -> CTLine? {
        if let cached = _cache[char] {
            return cached
        }

        guard let marker = _dictionary[char] else {
            return nil
        }

        let attrString = NSAttributedString(string: marker, attributes: _attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        _cache[char] = line
        return line
    }

    func updateDictionary(_ newDictionary: [Character: String]) {
        _dictionary = newDictionary
        _cache.removeAll()
    }

}
