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
    @inline(__always)
    var isControl: Bool {
        unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value <= 0x1F || value == 0x7F)
        }
    }
    
    // そのCharacterがUTF-8実装のUnicodeとして1バイトであるか否か返す。
    // Tree-sitterのnodeの範囲をRange<Int>互換にするで使用。
    @inline(__always)
    var isSingleByteCharacterInUTF8: Bool {
        return String(self).utf8.count == 1
    }
    
    @inline(__always)
    var isAllASCII: Bool { unicodeScalars.allSatisfy { $0.isASCII } }
    

}


// KSyntaxParserProtocolのwordRange(at:)で仕様される関数群。
enum JpScript {
    case kanji, hiragana, katakana
}

extension Character {
    @inline(__always) var _isHiragana: Bool {
        unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
    }
    @inline(__always) var _isKatakana: Bool {
        unicodeScalars.allSatisfy {
            (0x30A0...0x30FF).contains($0.value) ||    // カタカナ
            (0x31F0...0x31FF).contains($0.value) ||    // 小書きカタカナ拡張
            (0xFF66...0xFF9D).contains($0.value)       // 半角カタカナ
        }
    }
    @inline(__always) var _isKanji: Bool {
        unicodeScalars.allSatisfy {
            (0x3400...0x4DBF).contains($0.value) ||     // 拡張A
            (0x4E00...0x9FFF).contains($0.value) ||     // 基本面
            (0xF900...0xFAFF).contains($0.value)        // 互換漢字
        }
    }
    @inline(__always) var _jpScript: JpScript? {
        if _isKanji     { return .kanji }
        if _isHiragana  { return .hiragana }
        if _isKatakana  { return .katakana }
        return nil
    }
}
