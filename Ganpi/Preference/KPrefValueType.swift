//
//  KPrefValueType.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/16,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



//
//  KPrefSchema.swift
//  Ganpi - macOS Text Editor
//
//  設定項目の型（Bool/Int/String/Color/Font など）を記述したスキーマ。
//  Loader が読み取った String 辞書を、KPreference 内部で
//  適切な型に変換するための情報を提供する。
//  列挙型は .enumerated で分類されるが、内部保持値は String のままとする。
//  color にのみ dark variant が存在し、fallback の対象となる。
//

import AppKit

// Pref の値種別
enum KPrefValueType {
    case bool
    case int
    case float
    case string
    case color
    case font
    case enumerated     // 列挙型：内部では String として保持
}

// スキーマ 1 項目
struct KPrefSchemaEntry {
    let key: KPrefKey
    let type: KPrefValueType
    let hasDarkVariant: Bool
}

// スキーマ本体
enum KPrefSchema {

    // すべての項目を列挙
    static let all: [KPrefSchemaEntry] = [

        // -------------------------
        // [system]
        // -------------------------
        .init(key: .systemAutoDetectNewline,         type: .bool,       hasDarkVariant: false),
        .init(key: .systemAutoDetectCharCode,        type: .bool,       hasDarkVariant: false),
        .init(key: .systemAutoDetectFileType,        type: .bool,       hasDarkVariant: false),
        .init(key: .systemAppearance,                type: .enumerated, hasDarkVariant: false),

        // -------------------------
        // [document]
        // -------------------------
        .init(key: .documentSizeHeight,              type: .float,      hasDarkVariant: false),
        .init(key: .documentSizeWidth,               type: .float,      hasDarkVariant: false),
        .init(key: .documentNewline,                 type: .enumerated, hasDarkVariant: false),
        .init(key: .documentCharCode,                type: .enumerated, hasDarkVariant: false),
        .init(key: .documentFileType,                type: .enumerated, hasDarkVariant: false),
        .init(key: .documentShowLineNumber,          type: .bool,       hasDarkVariant: false),
        .init(key: .documentSyntaxMenu,              type: .string,     hasDarkVariant: false),
        .init(key: .documentRejectFontChange,        type: .bool,       hasDarkVariant: false),

        // -------------------------
        // [editor]
        // -------------------------
        .init(key: .editorKeyAssign,                 type: .enumerated, hasDarkVariant: false),
        .init(key: .editorUseEditMode,               type: .bool,       hasDarkVariant: false),
        .init(key: .editorEditMode,                  type: .enumerated, hasDarkVariant: false),
        .init(key: .editorUseYankPop,                type: .bool,       hasDarkVariant: false),
        .init(key: .editorUseWordCompletion,         type: .bool,       hasDarkVariant: false),

        // -------------------------
        // [search_window]
        // -------------------------
        .init(key: .searchWindowFont,                type: .font,       hasDarkVariant: false),
        .init(key: .searchWindowFontSize,            type: .float,      hasDarkVariant: false),
        .init(key: .searchWindowFontFamily,          type: .string,     hasDarkVariant: false),

        .init(key: .searchWindowReplaceFont,         type: .font,       hasDarkVariant: false),
        .init(key: .searchWindowReplaceFontSize,     type: .float,      hasDarkVariant: false),
        .init(key: .searchWindowReplaceFontFamily,   type: .string,     hasDarkVariant: false),

        .init(key: .searchWindowCloseWhenDone,       type: .bool,       hasDarkVariant: false),
        .init(key: .searchWindowIgnoreCase,          type: .bool,       hasDarkVariant: false),
        .init(key: .searchWindowUseRegex,            type: .bool,       hasDarkVariant: false),

        // -------------------------
        // [color_panel]
        // -------------------------
        .init(key: .colorPanelWithAlpha,             type: .bool,       hasDarkVariant: false),

        // -------------------------
        // [parser.base]
        // -------------------------
        .init(key: .parserBaseTabWidth,              type: .int,        hasDarkVariant: false),
        .init(key: .parserBaseLineSpacing,           type: .float,      hasDarkVariant: false),
        .init(key: .parserBaseWordWrap,              type: .bool,       hasDarkVariant: false),
        .init(key: .parserBaseAutoIndent,            type: .bool,       hasDarkVariant: false),
        .init(key: .parserBaseShowInvisibles,        type: .bool,       hasDarkVariant: false),
        .init(key: .parserBaseWrapLineOffset,        type: .enumerated, hasDarkVariant: false),

        .init(key: .parserBaseShowInvTab,            type: .bool,       hasDarkVariant: false),
        .init(key: .parserBaseShowInvNewline,        type: .bool,       hasDarkVariant: false),
        .init(key: .parserBaseShowInvSpace,          type: .bool,       hasDarkVariant: false),
        .init(key: .parserBaseShowInvFullWidth,      type: .bool,       hasDarkVariant: false),

        .init(key: .parserBaseGlyphNewline,          type: .string,     hasDarkVariant: false),
        .init(key: .parserBaseGlyphTab,              type: .string,     hasDarkVariant: false),
        .init(key: .parserBaseGlyphSpace,            type: .string,     hasDarkVariant: false),
        .init(key: .parserBaseGlyphFullWidth,        type: .string,     hasDarkVariant: false),

        // ---- light/dark color 群 ----
        .init(key: .parserBaseColorText,             type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorBackground,       type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorLiteral,          type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorComment,          type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorVariable,         type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorKeyword,          type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorNumeric,          type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorInvisibles,       type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorCompletion,       type: .color,      hasDarkVariant: true),
        .init(key: .parserBaseColorSelection,        type: .color,      hasDarkVariant: true),

        .init(key: .parserBaseFont,                  type: .font,       hasDarkVariant: false),
        .init(key: .parserBaseFontFamily,            type: .string,     hasDarkVariant: false),
        .init(key: .parserBaseFontSize,              type: .float,      hasDarkVariant: false),

        // -------------------------
        // [parser.plain]（全て任意）
        // -------------------------
        .init(key: .parserPlainColorText,            type: .color,      hasDarkVariant: true),
        .init(key: .parserPlainColorComment,         type: .color,      hasDarkVariant: true),
        .init(key: .parserPlainColorKeyword,         type: .color,      hasDarkVariant: true),
        .init(key: .parserPlainColorLiteral,         type: .color,      hasDarkVariant: true),
        .init(key: .parserPlainColorBackground,      type: .color,      hasDarkVariant: true),

        // -------------------------
        // [parser.ruby]
        // -------------------------
        .init(key: .parserRubyColorComment,          type: .color,      hasDarkVariant: true),
        .init(key: .parserRubyColorKeyword,          type: .color,      hasDarkVariant: true),
        .init(key: .parserRubyColorLiteral,          type: .color,      hasDarkVariant: true),
        .init(key: .parserRubyColorNumeric,          type: .color,      hasDarkVariant: true),
        .init(key: .parserRubyColorVariable,         type: .color,      hasDarkVariant: true),

        // -------------------------
        // [parser.html]
        // -------------------------
        .init(key: .parserHtmlColorTag,              type: .color,      hasDarkVariant: true),
        .init(key: .parserHtmlColorLiteral,          type: .color,      hasDarkVariant: true),
        .init(key: .parserHtmlColorComment,          type: .color,      hasDarkVariant: true),
        .init(key: .parserHtmlColorKeyword,          type: .color,      hasDarkVariant: true),

        // -------------------------
        // [parser.css]
        // -------------------------
        .init(key: .parserCssColorText,              type: .color,      hasDarkVariant: true),
        .init(key: .parserCssColorKeyword,           type: .color,      hasDarkVariant: true),
        .init(key: .parserCssColorComment,           type: .color,      hasDarkVariant: true),
        .init(key: .parserCssColorLiteral,           type: .color,      hasDarkVariant: true)
    ]
}
