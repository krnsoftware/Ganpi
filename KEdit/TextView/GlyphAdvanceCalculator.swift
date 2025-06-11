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
        self.ctFont = font as CTFont
    }

    func advanceForCharacter(_ char: Character) -> CGFloat {
        if let cached = cache[char] {
            return cached
        }

        let utf16Units = Array(char.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16Units.count)

        let success = CTFontGetGlyphsForCharacters(ctFont, utf16Units, &glyphs, utf16Units.count)
        var totalAdvance: CGFloat = 0

        if success {
            var advances = [CGSize](repeating: .zero, count: utf16Units.count)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, utf16Units.count)

            totalAdvance = advances.reduce(0) { $0 + $1.width }
        }

        cache[char] = totalAdvance
        return totalAdvance
    }

}
