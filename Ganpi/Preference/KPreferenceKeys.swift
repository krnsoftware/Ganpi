//
//  KPreferenceKeys.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/29,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

/// INIキーはすべてフラットな文字列。タイポ防止のため定数化する。
enum KPrefKey {
    // parser.base: 初期値・色・フォント
    static let parserBaseShowInvisiblesDefault = "parser.base.default.show.invisibles"

    static let parserBaseShowInvisiblesTab     = "parser.base.show.invisibles.tab"
    static let parserBaseShowInvisiblesNewline = "parser.base.show.invisibles.newline"
    static let parserBaseShowInvisiblesSpace   = "parser.base.show.invisibles.space"
    static let parserBaseShowInvisiblesFull    = "parser.base.show.invisibles.fullwidth_space"

    static let parserBaseGlyphNewline = "parser.base.invisibles.glyph.newline"
    static let parserBaseGlyphTab     = "parser.base.invisibles.glyph.tab"
    static let parserBaseGlyphSpace   = "parser.base.invisibles.glyph.space"
    static let parserBaseGlyphFull    = "parser.base.invisibles.glyph.fullwidth_space"

    static let parserBaseColorInvisibles = "parser.base.color.invisibles"
    static let parserBaseColorSelection  = "parser.base.color.selection_highlight"
    static let parserBaseColorText       = "parser.base.color.text"
    static let parserBaseColorBackground = "parser.base.color.background"

    static let parserBaseFont                 = "parser.base.font"          // "<PS> <size>"
    static let parserBaseFontFamilyDeprecated = "parser.base.font.family"   // 読み込み時のみ許可（非推奨）
    static let parserBaseFontSizeDeprecated   = "parser.base.font.size"     // 読み込み時のみ許可（非推奨）

    // default 群（言語ごとの上書き可能）
    static let parserBaseDefaultTabWidth    = "parser.base.default.tab_width"
    static let parserBaseDefaultLineSpacing = "parser.base.default.line_spacing"
    static let parserBaseDefaultWordWrap    = "parser.base.default.word_wrap"
    static let parserBaseDefaultAutoIndent  = "parser.base.default.auto_indent"
}
