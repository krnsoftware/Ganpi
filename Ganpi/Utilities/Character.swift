//
//  Character.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/06/01.
//

import Cocoa

extension Character {
    
    var displayWidth: Int {
        // 制御系は 0（既存の isControl でもOK）
        if self == "\n" || self == "\r" { return 0 }
        
        // まず絵文字をざっくり 2 桁扱い
        // （厳密化は将来でOK）
        if unicodeScalars.contains(where: { $0.properties.isEmoji || $0.properties.isEmojiPresentation }) {
            return 2
        }
        
        // 結合記号・フォーマットは 0 幅にする
        // （結合濁点/ZWJ/バリアント選択子など）
        let contributesWidth = unicodeScalars.contains { s in
            // ZWJ / Variation Selector
            if s.value == 0x200D { return false }
            if (0xFE00...0xFE0F).contains(s.value) { return false }
            if (0xE0100...0xE01EF).contains(s.value) { return false }
            
            // Category による 0 幅
            switch s.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format:
                return false
            default:
                return true
            }
        }
        if !contributesWidth { return 0 }
        
        // ここからは既存の全角/半角ざっくり判定（維持）
        guard let scalar = unicodeScalars.first else { return 1 }
        let v = scalar.value
        switch v {
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
    
    @inline(__always) var _isKanaProlong: Bool {
        unicodeScalars.allSatisfy { $0.value == 0x30FC } // 「ー」
    }
    
    // 反復記号
    @inline(__always) var _isHiraganaIteration: Bool {
        unicodeScalars.allSatisfy { $0.value == 0x309D || $0.value == 0x309E } // ゝ ゞ
    }
    @inline(__always) var _isKatakanaIteration: Bool {
        unicodeScalars.allSatisfy { $0.value == 0x30FD || $0.value == 0x30FE } // ヽ ヾ
    }
    @inline(__always) var _isKanjiIteration: Bool {
        unicodeScalars.allSatisfy { $0.value == 0x3005 || $0.value == 0x303B } // 々 〻
    }
    
    @inline(__always) var _jpScript: JpScript? {
        if _isKanji || _isKanjiIteration { return .kanji }
        if _isHiragana || _isHiraganaIteration  { return .hiragana }
        if _isKatakana || _isKatakanaIteration  { return .katakana }
        return nil
    }
}



