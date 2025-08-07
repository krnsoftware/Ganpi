//
//  FuncChar.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Foundation

// 編集・描画処理で扱う代表的な機能文字（不可視・記号）を定義する列挙型。
enum FuncChar: UInt8, CaseIterable {
    // 制御文字
    case lf           = 0x0A  // Line Feed (\n)
    case tab          = 0x09  // Tab (\t)

    // 空白・引用・記号
    case space        = 0x20  // Space
    case doubleQuote  = 0x22  // "
    case singleQuote  = 0x27  // '
    case numeric      = 0x23  // #
    case percent      = 0x25  // %
    case ampersand    = 0x26  // &
    case slash        = 0x2F  // /
    case backSlash    = 0x5C  // \

    // 区切り・構文記号
    case colon        = 0x3A  // :
    case semicolon    = 0x3B  // ;
    case lt           = 0x3C  // <
    case gt           = 0x3E  // >

    // 括弧類
    case leftParen     = 0x28  // (
    case rightParen    = 0x29  // )
    case leftBracket   = 0x5B  // [
    case rightBracket  = 0x5D  // ]
    case leftBrace     = 0x7B  // {
    case rightBrace    = 0x7D  // }
}

// MARK: - Extension

extension FuncChar {
    // 対応する `Character` を返す（描画用などに使用）
    var character: Character {
        Character(UnicodeScalar(self.rawValue))
    }
    
    // 人間向けの識別名
    var displayName: String {
        switch self {
        case .lf:           return "LF"
        case .tab:          return "Tab"
        case .space:        return "Space"
        case .doubleQuote:  return "\""
        case .singleQuote:  return "'"
        case .numeric:      return "#"
        case .percent:      return "%"
        case .ampersand:    return "&"
        case .slash:        return "/"
        case .backSlash:    return "\\"
        case .colon:        return ":"
        case .semicolon:    return ";"
        case .lt:           return "<"
        case .gt:           return ">"
        case .leftParen:    return "("
        case .rightParen:   return ")"
        case .leftBracket:  return "["
        case .rightBracket: return "]"
        case .leftBrace:    return "{"
        case .rightBrace:   return "}"
        }
    }
}
