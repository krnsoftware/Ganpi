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
//  Ganpi
//

import Foundation

enum KPrefValueType {
    case bool
    case int
    case float
    case string
    case color
    case font
    case enumerated
}

struct KPrefSchema {
    let type: KPrefValueType
    
    // rawKey → schema
    static let table: [String : KPrefSchema] = [
        
        // -----------------------------
        // system
        // -----------------------------
        "system.auto_detection.newline"         : .init(type: .bool),
        "system.auto_detection.character_code"  : .init(type: .bool),
        "system.auto_detection.file_type"       : .init(type: .bool),
        
        
        // -----------------------------
        // document
        // -----------------------------
        "document.size.height"                  : .init(type: .float),
        "document.size.width"                   : .init(type: .float),
        
        "document.newline"                      : .init(type: .string),
        "document.character_code"               : .init(type: .string),
        "document.file_type"                    : .init(type: .string),
        
        "document.show_line_number"             : .init(type: .bool),
        "document.reject_font_change"           : .init(type: .bool),
        
        
        // -----------------------------
        // editor
        // -----------------------------
        "editor.key_assign"                     : .init(type: .enumerated),
        "editor.use_edit_mode"                  : .init(type: .bool),
        
        // normal|edit
        "editor.edit_mode"                      : .init(type: .enumerated),
        
        "editor.use_yank_pop"                   : .init(type: .bool),
        "editor.use_word_completion"            : .init(type: .bool),
        
        
        // -----------------------------
        // search window
        // -----------------------------
        "search_window.search_field.font.size"  : .init(type: .float),
        "search_window.search_field.font.family": .init(type: .string),
        
        "search_window.replace_field.font.size" : .init(type: .float),
        "search_window.replace_field.font.family": .init(type: .string),
        
        "search_window.close_when_done"         : .init(type: .bool),
        "search_window.ignore_case"             : .init(type: .bool),
        "search_window.use_regex"               : .init(type: .bool),
        
        
        // -----------------------------
        // color panel
        // -----------------------------
        "color_panel.with_alpha"                : .init(type: .bool),
        
        
        // -----------------------------
        // parser.base general settings
        // -----------------------------
        "parser.base.tab_width"                 : .init(type: .int),
        "parser.base.line_spacing"              : .init(type: .float),
        "parser.base.word_wrap"                 : .init(type: .bool),
        "parser.base.auto_indent"               : .init(type: .bool),
        "parser.base.show.invisibles"           : .init(type: .bool),
        
        // wrapline_offset → enumerated
        "parser.base.wrapline_offset"           : .init(type: .enumerated),
        
        "parser.base.show.invisibles.tab"       : .init(type: .bool),
        "parser.base.show.invisibles.newline"   : .init(type: .bool),
        "parser.base.show.invisibles.space"     : .init(type: .bool),
        "parser.base.show.invisibles.fullwidth_space"
        : .init(type: .bool),
        
        "parser.base.invisibles.glyph.newline"  : .init(type: .string),
        "parser.base.invisibles.glyph.tab"      : .init(type: .string),
        "parser.base.invisibles.glyph.space"    : .init(type: .string),
        "parser.base.invisibles.glyph.fullwidth_space"
        : .init(type: .string),
        
        
        // -----------------------------
        // parser.base colors（無印のみ。dark/light は派生）
        // -----------------------------
        "parser.base.color.text"                : .init(type: .color),
        "parser.base.color.background"          : .init(type: .color),
        "parser.base.color.literal"             : .init(type: .color),
        "parser.base.color.comment"             : .init(type: .color),
        "parser.base.color.variable"            : .init(type: .color),
        "parser.base.color.keyword"             : .init(type: .color),
        "parser.base.color.numeric"             : .init(type: .color),
        "parser.base.color.invisibles"          : .init(type: .color),
        "parser.base.color.completion"          : .init(type: .color),
        "parser.base.color.selection_highlight.active"        : .init(type: .color),
        "parser.base.color.selection_highlight.inactive"      : .init(type: .color),

        
        
        // -----------------------------
        // parser.base font
        // -----------------------------
        "parser.base.font.family"               : .init(type: .string),
        "parser.base.font.size"                 : .init(type: .float)
        // parserFont（抽象キー）は rawKey がないので schema 不要
    ]
}
