//
//  Character.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/01.
//

import Cocoa

extension Character {
    
    var displayWidth: Int {
        guard let scalar = unicodeScalars.first else { return 1 }
        let value = scalar.value

        // 簡易全角・半角判定
        switch value {
        case 0x1100...0x11FF,       // Hangul Jamo
             0x2E80...0x9FFF,       // CJK系（部首/漢字など）
             0xAC00...0xD7A3,       // Hangul Syllables
             0xF900...0xFAFF,       // CJK互換漢字
             0xFE10...0xFE1F,       // 縦書き用句読点
             0xFF01...0xFF60,       // 全角記号/英数
             0xFFE0...0xFFE6:       // 全角記号
            return 2
        default:
            return 1
        }
    }
    
}
