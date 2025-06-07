//
//  GlyphAdvanceCalculator.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import CoreText
import Cocoa

final class GlyphAdvanceCalculator {
    private var cache: [Character: CGFloat] = [:]
    private let ctFont: CTFont

    init(font: NSFont) {
        self.ctFont = font as CTFont // ← これで安全に変換
    }

    func advanceForCharacter(_ char: Character) -> CGFloat {
        if let cached = cache[char] {
            return cached
        }

        guard let uniScalar = char.unicodeScalars.first else {
            cache[char] = 0
            return 0
        }

        let characters: [UniChar] = [UniChar(uniScalar.value)]
        var glyphs: [CGGlyph] = [0]
        let success = CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, 1)
        let glyph = glyphs[0]

        var advance = CGSize.zero
        if success {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, [glyph], &advance, 1)
        }

        cache[char] = advance.width
        return advance.width
    }
}
