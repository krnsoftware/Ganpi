//
//  KPrefKey.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/16,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
//
//  KPrefKey.swift
//  Ganpi
//

// Ganpi Preferences – Key Definitions (Logical Keys)

enum KPrefKey {

    // ============================
    // system
    // ============================

    case systemAutoDetectionNewline
    case systemAutoDetectionCharacterCode
    case systemAutoDetectionFileType
    case systemAppearanceMode     // enumerated


    // ============================
    // document
    // ============================

    case documentSizeHeight
    case documentSizeWidth

    case documentNewline
    case documentCharacterCode
    case documentFileType

    case documentShowLineNumber
    case documentRejectFontChange


    // ============================
    // editor
    // ============================

    case editorKeyAssign          // enumerated
    case editorUseEditMode
    case editorEditMode           // enumerated
    case editorUseYankPop
    case editorUseWordCompletion


    // ============================
    // search window
    // ============================

    case searchFieldFontSize
    case searchFieldFontFamily

    case replaceFieldFontSize
    case replaceFieldFontFamily

    case searchWindowCloseWhenDone
    case searchWindowIgnoreCase
    case searchWindowUseRegex


    // ============================
    // color panel
    // ============================

    case colorPanelWithAlpha


    // ============================
    // parser settings（base 設定の論理キー）
    //
    // rawKey は parser.base.… に紐づく。
    // lang 付き呼び出しで fallback:
    //   parser.<lang>.xxx
    //   parser.base.xxx
    //   default
    // ============================

    case parserTabWidth
    case parserLineSpacing
    case parserWordWrap
    case parserAutoIndent
    case parserShowInvisibles
    case parserWraplineOffset     // enumerated

    case parserShowInvisiblesTab
    case parserShowInvisiblesNewline
    case parserShowInvisiblesSpace
    case parserShowInvisiblesFullwidthSpace

    case parserInvisiblesGlyphNewline
    case parserInvisiblesGlyphTab
    case parserInvisiblesGlyphSpace
    case parserInvisiblesGlyphFullwidthSpace


    // ============================
    // parser color（論理キー）
    //
    // rawKey は parser.base.color.… に紐づける
    // ============================

    case parserColorText
    case parserColorBackground
    case parserColorLiteral
    case parserColorComment
    case parserColorVariable
    case parserColorKeyword
    case parserColorNumeric
    case parserColorInvisibles
    case parserColorCompletion
    case parserColorSelectionHighlight


    // ============================
    // parser font（論理キー）
    // ============================

    case parserFontFamily
    case parserFontSize
    case parserFont        // 抽象キー（rawKey: nil）


    // ============================
    // rawKey mapping
    // ============================

    var rawKey: String? {
        switch self {

        // ---- system ----
        case .systemAutoDetectionNewline:
            return "system.auto_detection.newline"
        case .systemAutoDetectionCharacterCode:
            return "system.auto_detection.character_code"
        case .systemAutoDetectionFileType:
            return "system.auto_detection.file_type"
        case .systemAppearanceMode:
            return "system.appearance_mode"

        // ---- document ----
        case .documentSizeHeight:
            return "document.size.height"
        case .documentSizeWidth:
            return "document.size.width"

        case .documentNewline:
            return "document.newline"
        case .documentCharacterCode:
            return "document.character_code"
        case .documentFileType:
            return "document.file_type"

        case .documentShowLineNumber:
            return "document.show_line_number"
        case .documentRejectFontChange:
            return "document.reject_font_change"

        // ---- editor ----
        case .editorKeyAssign:
            return "editor.key_assign"
        case .editorUseEditMode:
            return "editor.use_edit_mode"
        case .editorEditMode:
            return "editor.edit_mode"
        case .editorUseYankPop:
            return "editor.use_yank_pop"
        case .editorUseWordCompletion:
            return "editor.use_word_completion"

        // ---- search window ----
        case .searchFieldFontSize:
            return "search_window.search_field.font.size"
        case .searchFieldFontFamily:
            return "search_window.search_field.font.family"

        case .replaceFieldFontSize:
            return "search_window.replace_field.font.size"
        case .replaceFieldFontFamily:
            return "search_window.replace_field.font.family"

        case .searchWindowCloseWhenDone:
            return "search_window.close_when_done"
        case .searchWindowIgnoreCase:
            return "search_window.ignore_case"
        case .searchWindowUseRegex:
            return "search_window.use_regex"

        // ---- color panel ----
        case .colorPanelWithAlpha:
            return "color_panel.with_alpha"

        // ---- parser general ----
        case .parserTabWidth:
            return "parser.base.tab_width"
        case .parserLineSpacing:
            return "parser.base.line_spacing"
        case .parserWordWrap:
            return "parser.base.word_wrap"
        case .parserAutoIndent:
            return "parser.base.auto_indent"
        case .parserShowInvisibles:
            return "parser.base.show.invisibles"
        case .parserWraplineOffset:
            return "parser.base.wrapline_offset"

        case .parserShowInvisiblesTab:
            return "parser.base.show_invisibles.tab"
        case .parserShowInvisiblesNewline:
            return "parser.base.show_invisibles.newline"
        case .parserShowInvisiblesSpace:
            return "parser.base.show_invisibles.space"
        case .parserShowInvisiblesFullwidthSpace:
            return "parser.base.show_invisibles.fullwidth_space"

        case .parserInvisiblesGlyphNewline:
            return "parser.base.invisibles.glyph.newline"
        case .parserInvisiblesGlyphTab:
            return "parser.base.invisibles.glyph.tab"
        case .parserInvisiblesGlyphSpace:
            return "parser.base.invisibles.glyph.space"
        case .parserInvisiblesGlyphFullwidthSpace:
            return "parser.base.invisibles.glyph.fullwidth_space"

        // ---- parser color ----
        case .parserColorText:
            return "parser.base.color.text"
        case .parserColorBackground:
            return "parser.base.color.background"
        case .parserColorLiteral:
            return "parser.base.color.literal"
        case .parserColorComment:
            return "parser.base.color.comment"
        case .parserColorVariable:
            return "parser.base.color.variable"
        case .parserColorKeyword:
            return "parser.base.color.keyword"
        case .parserColorNumeric:
            return "parser.base.color.numeric"
        case .parserColorInvisibles:
            return "parser.base.color.invisibles"
        case .parserColorCompletion:
            return "parser.base.color.completion"
        case .parserColorSelectionHighlight:
            return "parser.base.color.selection_highlight"

        // ---- parser font ----
        case .parserFontFamily:
            return "parser.base.font.family"
        case .parserFontSize:
            return "parser.base.font.size"
        case .parserFont:
            return nil
        }
    }
}
