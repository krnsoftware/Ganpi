//
//  Character.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/01.
//

import Cocoa

extension Character {
    
    // 文字種により全角・半角を判別する。
    // proportional fontでは意味がないが、将来完全な等幅フォントを使用する場合に利用する予定。
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
    
    // そのCharacterが制御文字であるか否か返す。
    // ASCIIの制御文字のみ対応。将来的にUnicode全域で必要になればまたその際に対応する。
    // string.filter { !$0.isControl } のようにして制御文字を排除する。
    var isControl: Bool {
        unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value <= 0x1F || value == 0x7F)
        }
    }
    
    // そのCharacterがUTF-8実装のUnicodeとして1バイトであるか否か返す。
    // Tree-sitterのnodeの範囲をRange<Int>互換にするで使用。
    var isSingleByteCharacterInUTF8: Bool {
        return String(self).utf8.count == 1
    }
}
