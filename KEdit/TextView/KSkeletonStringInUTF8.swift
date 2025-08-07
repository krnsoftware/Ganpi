//
//  KSkeletonStringInUTF8.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
//  Created by KARINO Masatugu on 2025/08/07.
//


import Cocoa

// KTextStorageに於いて、_characters:[Characters]の代わりに用いられる[UInt8]のwrapper。
// 主にTree-Sitterのパースと、テキスト内の制御文字等を検出するために使用される。
final class KSkeletonStringInUTF8 {
    // MARK: - Enum and Struct.
    
   
    
    
    // MARK: - Properties.
    private var _bytes: [UInt8] = []
    
    var bytes:[UInt8]  {
        _bytes
    }
    
    // MARK: - Static functions.
    
    // [Character]をUTF-8実装のUnicodeに変換するが、その際、複数バイトになる文字については"a"を代替文字とする。
    // 元の[Character]と文字の位置が一致するためRange<Int>をそのまま使用できるが、生成した文字列から元の文字列は復元できない。
    static func convertCharactersToApproximateUTF8(_ characters: [Character]) -> [UInt8] {
        var result: [UInt8] = []

        for char in characters {
            let utf8Bytes = String(char).utf8
            if utf8Bytes.count == 1 {
                result.append(contentsOf: utf8Bytes)
            } else {
                result.append(0x61) // 'a'
            }
        }

        return result
    }
    
    // [Uint8]の文字列から特定の1文字についてoffsetの配列を得る。
    static func indicesOfCharacter(in buffer: [UInt8], range: Range<Int>, target: UInt8) -> [Int] {
        if range.lowerBound < 0 || buffer.count < range.upperBound {
            log("range: out of range.", from: self)
            return []
        }

        var indices: [Int] = []
        let simdWidth = 16
        var i = range.lowerBound
        let end = range.upperBound - simdWidth

        // SIMDスキャン
        while i <= end {
            let chunk = SIMD16<UInt8>(buffer[i..<i+simdWidth])
            let matches = chunk .== SIMD16<UInt8>(repeating: target)
            for j in 0..<simdWidth where matches[j] {
                indices.append(i + j)
            }
            i += simdWidth
        }

        // 端数処理
        while i < range.upperBound {
            if buffer[i] == target {
                indices.append(i)
            }
            i += 1
        }

        return indices
    }
    
    //MARK: - Internal functions.
    
    // KTextStorage.replaceCharacters()内に於いてreplaceSubrange()の後に呼ばれる。
    func replaceCharacters(_ range: Range<Int>, with newCharacters: [Character]) {
        let addition = Self.convertCharactersToApproximateUTF8(newCharacters)
        
        _bytes.replaceSubrange(range, with: addition)
        
        //log("skeleton = \(String(bytes:_bytes, encoding: .utf8)!)",from:self)
    }
    
    // 改行コード("\n")のoffsetを全て返す。
    func newlineIndices() -> [Int] {
        return Self.indicesOfCharacter(in: _bytes, range: 0..<_bytes.count, target: FuncChar.lf.rawValue)
    }
    /*
    func newlineIndices() -> [Int] {
        let newLine:UInt8 = 0x0A // "\n"
        return _bytes.enumerated().compactMap { $0.element == newLine ? $0.offset : nil }
    }*/
    
    
    
}


/*
 
 import Foundation
 import simd

 struct LineFeedScanner {
     /// 改行文字（LF = 0x0A）を `[UInt8]` バッファから検索し、見つかったインデックスの配列を返す
     static func indicesOfLineFeeds(in buffer: [UInt8]) -> [Int] {
         let target: UInt8 = 0x0A // LF
         
         var indices: [Int] = []
         let simdWidth = 16
         var i = 0
         let end = buffer.count - (buffer.count % simdWidth)
         
         // SIMDスキャン
         while i < end {
             let chunk = SIMD16<UInt8>(buffer[i..<i+simdWidth])
             let matches = chunk .== SIMD16<UInt8>(repeating: target)
             for j in 0..<simdWidth where matches[j] {
                 indices.append(i + j)
             }
             i += simdWidth
         }

         // 端数処理
         while i < buffer.count {
             if buffer[i] == target {
                 indices.append(i)
             }
             i += 1
         }
         
         return indices
     }
 }
 
 */


