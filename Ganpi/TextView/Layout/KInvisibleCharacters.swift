//
//  KInvisibleCharacters.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

// 不可視文字の表示用クラス。不可視文字の代替文字の管理とCTLineの保持・提供を目的とする。
final class KInvisibleCharacters {
    private let _syntaxType: KSyntaxType
    private var _dictionary: [Character: String] = [:]
    private var _cache: [Character: CTLine] = [:]
    private let _attributes: [NSAttributedString.Key: Any]
    
    /*private static let _defaultDictionary: [Character: String] = [
            "\u{0020}": "∙",    // SPACE → Middle Dot
            "\u{0009}": "➤",    // TAB → Right Arrow
            "\u{000A}": "⏎",    // LF → Return Symbol
            "\u{3000}": "□",     // 全角スペース
        ]*/
    
    private static let _defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            //.foregroundColor: NSColor.secondaryLabelColor
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

    
    init(syntaxType: KSyntaxType, attributes: [NSAttributedString.Key: Any] = _defaultAttributes){
        _attributes = attributes
        _syntaxType = syntaxType

        let prefs = KPreference.shared

        // 空（または空白のみ）の場合は「描画しない」扱いとして辞書に登録しない
        func normalizedGlyph(key: KPrefKey) -> String? {
            let trimmed = prefs.string(key, lang: _syntaxType).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        
        // 不可視文字が表示されるべきか否か返す。
        func show(_ key: KPrefKey) -> Bool {
            return prefs.bool(key, lang: _syntaxType)
        }
        
        // space
        if show(.parserShowInvisiblesSpace), let glyph = normalizedGlyph(key: .parserInvisiblesGlyphSpace) {
            _dictionary["\u{0020}"] = glyph
        }
        
        // tab
        if show(.parserShowInvisiblesTab), let glyph = normalizedGlyph(key: .parserInvisiblesGlyphTab) {
            _dictionary["\u{0009}"] = glyph
        }
        
        // new line
        if show(.parserShowInvisiblesNewline), let glyph = normalizedGlyph(key: .parserInvisiblesGlyphNewline) {
            _dictionary["\u{000A}"] = glyph
        }
        
        // full-width space
        if show(.parserShowInvisiblesFullwidthSpace), let glyph = normalizedGlyph(key: .parserInvisiblesGlyphFullwidthSpace) {
            _dictionary["\u{3000}"] = glyph
        }
    }

    // 与えられた文字について、それが登録された不可視文字であればその文字のCTLineを返す。
    // 登録されていなければnilを返す。
    func ctLine(for char: Character) -> CTLine? {
        if let cached = _cache[char] {
            return cached
        }

        guard let marker = _dictionary[char] else {
            //log("dictionary[char] is nil.",from:self)
            return nil
        }

        let attrString = NSAttributedString(string: marker, attributes: _attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        _cache[char] = line
        return line
    }

}
