//
//  KPrefKey.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/16,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



import Foundation

enum KPrefKey: String, CaseIterable {

    // ---------------------------------------------------------
    // [system]
    // ---------------------------------------------------------
    case systemAutoDetectNewline     = "system.auto_detection.newline"
    case systemAutoDetectCharCode    = "system.auto_detection.character_code"
    case systemAutoDetectFileType    = "system.auto_detection.file_type"
    case systemAppearance            = "system.appearance"

    // ---------------------------------------------------------
    // [document]
    // ---------------------------------------------------------
    case documentSizeHeight          = "document.size.height"
    case documentSizeWidth           = "document.size.width"
    case documentNewline             = "document.newline"
    case documentCharCode            = "document.character_code"
    case documentFileType            = "document.file_type"
    case documentShowLineNumber      = "document.show_line_number"
    case documentSyntaxMenu          = "document.syntax_menu"
    case documentRejectFontChange    = "document.reject_font_change"

    // ---------------------------------------------------------
    // [editor]
    // ---------------------------------------------------------
    case editorKeyAssign             = "editor.key_assign"
    case editorUseEditMode           = "editor.use_edit_mode"
    case editorEditMode              = "editor.edit_mode"
    case editorUseYankPop            = "editor.use_yank_pop"
    case editorUseWordCompletion     = "editor.use_word_completion"

    // ---------------------------------------------------------
    // [search_window]
    // ---------------------------------------------------------
    case searchWindowFont            = "search_window.search_field.font"
    case searchWindowFontSize        = "search_window.search_field.font.size"
    case searchWindowFontFamily      = "search_window.search_field.font.family"

    case searchWindowReplaceFont         = "search_window.replace_field.font"
    case searchWindowReplaceFontSize     = "search_window.replace_field.font.size"
    case searchWindowReplaceFontFamily   = "search_window.replace_field.font.family"

    case searchWindowCloseWhenDone   = "search_window.close_when_done"
    case searchWindowIgnoreCase      = "search_window.ignore_case"
    case searchWindowUseRegex        = "search_window.use_regex"

    // ---------------------------------------------------------
    // [color_panel]
    // ---------------------------------------------------------
    case colorPanelWithAlpha         = "color_panel.with_alpha"

    // ---------------------------------------------------------
    // [parser.base]
    // ---------------------------------------------------------
    case parserBaseTabWidth          = "parser.base.tab_width"
    case parserBaseLineSpacing       = "parser.base.line_spacing"
    case parserBaseWordWrap          = "parser.base.word_wrap"
    case parserBaseAutoIndent        = "parser.base.auto_indent"
    case parserBaseShowInvisibles    = "parser.base.show.invisibles"
    case parserBaseWrapLineOffset    = "parser.base.wrapline_offset"

    case parserBaseShowInvTab        = "parser.base.show.invisibles.tab"
    case parserBaseShowInvNewline    = "parser.base.show.invisibles.newline"
    case parserBaseShowInvSpace      = "parser.base.show.invisibles.space"
    case parserBaseShowInvFullWidth  = "parser.base.show.invisibles.fullwidth_space"

    case parserBaseGlyphNewline      = "parser.base.invisibles.glyph.newline"
    case parserBaseGlyphTab          = "parser.base.invisibles.glyph.tab"
    case parserBaseGlyphSpace        = "parser.base.invisibles.glyph.space"
    case parserBaseGlyphFullWidth    = "parser.base.invisibles.glyph.fullwidth_space"

    // ---- light/dark color (dark variant の存在を schema が管理) ----
    case parserBaseColorText         = "parser.base.color.text"
    case parserBaseColorBackground   = "parser.base.color.background"
    case parserBaseColorLiteral      = "parser.base.color.literal"
    case parserBaseColorComment      = "parser.base.color.comment"
    case parserBaseColorVariable     = "parser.base.color.variable"
    case parserBaseColorKeyword      = "parser.base.color.keyword"
    case parserBaseColorNumeric      = "parser.base.color.numeric"
    case parserBaseColorInvisibles   = "parser.base.color.invisibles"
    case parserBaseColorCompletion   = "parser.base.color.completion"
    case parserBaseColorSelection    = "parser.base.color.selection_highlight"

    case parserBaseFont              = "parser.base.font"
    case parserBaseFontFamily        = "parser.base.font.family"
    case parserBaseFontSize          = "parser.base.font.size"

    // ---------------------------------------------------------
    // [parser.plain]
    // ---------------------------------------------------------
    case parserPlainColorText        = "parser.plain.color.text"
    case parserPlainColorComment     = "parser.plain.color.comment"
    case parserPlainColorKeyword     = "parser.plain.color.keyword"
    case parserPlainColorLiteral     = "parser.plain.color.literal"
    case parserPlainColorBackground  = "parser.plain.color.background"

    // ---------------------------------------------------------
    // [parser.ruby]
    // ---------------------------------------------------------
    case parserRubyColorComment      = "parser.ruby.color.comment"
    case parserRubyColorKeyword      = "parser.ruby.color.keyword"
    case parserRubyColorLiteral      = "parser.ruby.color.literal"
    case parserRubyColorNumeric      = "parser.ruby.color.numeric"
    case parserRubyColorVariable     = "parser.ruby.color.variable"

    // ---------------------------------------------------------
    // [parser.html]
    // ---------------------------------------------------------
    case parserHtmlColorTag          = "parser.html.color.tag"
    case parserHtmlColorLiteral      = "parser.html.color.literal"
    case parserHtmlColorComment      = "parser.html.color.comment"
    case parserHtmlColorKeyword      = "parser.html.color.keyword"

    // ---------------------------------------------------------
    // [parser.css]
    // ---------------------------------------------------------
    case parserCssColorText          = "parser.css.color.text"
    case parserCssColorKeyword       = "parser.css.color.keyword"
    case parserCssColorComment       = "parser.css.color.comment"
    case parserCssColorLiteral       = "parser.css.color.literal"
}
