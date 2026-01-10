//
//  KSkeletonStringInUTF8.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
//  Created by KARINO Masatugu on 2025/08/07.
//


import Cocoa
import Darwin

// KTextStorageに於いて、_characters:[Characters]の代わりに用いられる[UInt8]のwrapper。
// 主にテキスト内の制御文字等を検出するために使用される。

final class KSkeletonStringInUTF8 {
    // MARK: - Enum and Struct.
    
   
    
    
    // MARK: - Properties.
    private var _bytes: [UInt8] = []
    private var _newlineCache: [Int]? = nil
    
    var bytes:[UInt8]  { _bytes }
    var count: Int { _bytes.count }
    
    // MARK: - Static functions.
    
    // [Character]をUTF-8実装のUnicodeに変換するが、その際、複数バイトになる文字については"a"を代替文字とする。
    // 元の[Character]と文字の位置が一致するためRange<Int>をそのまま使用できるが、生成した文字列から元の文字列は復元できない。
    static func convertCharactersToApproximateUTF8(_ characters: [Character]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(characters.count) // 出力は必ず等長

        for ch in characters {
            // ASCII: 単一スカラ かつ < 0x80
            if ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first, s.value < 0x80 {
                result.append(UInt8(truncatingIfNeeded: s.value))
            } else {
                result.append(0x61) // 'a'
            }
        }
        return result
    }
    


    static func indicesOfCharacter(in buffer: [UInt8], range: Range<Int>, target: UInt8) -> [Int] {
        guard range.lowerBound >= 0,
              range.upperBound <= buffer.count,
              range.lowerBound < range.upperBound else { return [] }

        let n = range.count
        var out: [Int] = []
        out.reserveCapacity(min(n / 8, 1 << 15))

        buffer.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) -> Void in
            guard let base: UnsafePointer<UInt8> = buf.baseAddress else { return }

            var p: UnsafePointer<UInt8> = base.advanced(by: range.lowerBound)
            let end: UnsafePointer<UInt8> = base.advanced(by: range.upperBound)

            while p < end {
                
                let remaining: Int = end - p
                let foundRaw: UnsafeMutableRawPointer? = Darwin.memchr(
                    UnsafeRawPointer(p),
                    CInt(target),
                    remaining
                )
                guard let qRaw = foundRaw else { break }
                
                // Swift+C APIの関連で一旦mutableにする必要がある。
                let qMut: UnsafeMutablePointer<UInt8> = qRaw.assumingMemoryBound(to: UInt8.self)
                let q: UnsafePointer<UInt8> = UnsafePointer(qMut)

                out.append(range.lowerBound + (q - base))
                p = q.advanced(by: 1)
            }
        }

        return out
    }
    
    init() {
        
    }
    
    //MARK: - Internal functions. (for the limited use)
    
    // KTextStorage.replaceCharacters()内に於いてreplaceSubrange()の後に呼ばれる。
    // それ以外の状況では呼んではならない。
    func replaceCharacters(_ range: Range<Int>, with newCharacters: [Character]) {
        let addition = Self.convertCharactersToApproximateUTF8(newCharacters)
        
        _bytes.replaceSubrange(range, with: addition)
        
        _newlineCache = nil
    }
    
    
    // MARK: - Internal functions.
    
    // 読み取り専用：範囲外は 0 を返し、ログに記録
    subscript(_ index: Int) -> UInt8 {
        if index < 0 || index >= _bytes.count {
            log("Index \(index) out of range (count: \(_bytes.count))", from: self)
            return 0
        }
        return _bytes[index]
    }

    // 範囲取得：範囲外は空スライスを返し、ログに記録
    func bytes(in range: Range<Int>) -> ArraySlice<UInt8> {
        guard range.lowerBound >= 0, range.upperBound <= _bytes.count else {
            log("Range \(range) out of bounds (count: \(_bytes.count))", from: self)
            return []
        }
        return _bytes[range]
    }
    
    // 渡されたwordがskeletonのrangeの文字列と一致するか否かを返す。
    func matches(range: Range<Int>, word: [UInt8]) -> Bool {
        let len = range.count
        if word.count != len { return false }
        if range.upperBound > count { log("out of range.", from:self); return false }
        
        return _bytes[range].elementsEqual(word)
    }
    
    // 渡されたwordのリストにskeletonのrangeの文字列と一致するものがあるか否かを返す。
    func matches(range: Range<Int>, words: [[UInt8]]) -> Bool {
        var lo = 0
        var hi = words.count

        while lo < hi {
            let mid = (lo + hi) >> 1
            let w = words[mid]

            let cmp = compare(range: range, word: w)
            if cmp == 0 {
                return true
            } else if cmp < 0 {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return false
    }
    
    // return <0 : range < word
    //         0 : equal
    //        >0 : range > word
    private func compare(range: Range<Int>, word: [UInt8]) -> Int {
        let rlen = range.count
        let wlen = word.count
        let minLen = (rlen < wlen) ? rlen : wlen

        var i = 0
        while i < minLen {
            let a = _bytes[range.lowerBound + i]
            let b = word[i]
            if a != b {
                return Int(a) - Int(b)
            }
            i += 1
        }

        // prefix が一致している場合は長さで決定
        return rlen - wlen
    }
    
    // 改行コード("\n")のoffsetを全て返す。昇順。
    var newlineIndices: [Int] {
        if let cache = _newlineCache { return cache }
        
        let res = Self.indicesOfCharacter(in: _bytes, range: 0..<_bytes.count, target: FuncChar.lf)
        _newlineCache = res
        return res
    }
    
    // 行頭のインデックスを全て返す。昇順。
    // キャッシュされないため頻繁に呼び出す場合はnewlineIndicesを使用すること。
    var lineStartIndices: [Int] {
        [0] + newlineIndices.map { $0 + 1 }
    }
    
    // 指定された文字インデックスの含まれる物理行の行番号を返す。0開始。
    func lineIndex(at characterIndex: Int) -> Int {
        var lo = 0, hi = newlineIndices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if newlineIndices[mid] < characterIndex { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    
    // 指定された行インデックスの行のRangeを返す。末尾の改行を含まない。
    func lineRange(at lineIndex: Int) -> Range<Int> {
        let start: Int
        if lineIndex == 0 {
            start = 0
        } else {
            start = newlineIndices[lineIndex - 1] + 1
        }

        let end: Int
        if lineIndex < newlineIndices.count {
            end = newlineIndices[lineIndex]
        } else {
            end = bytes.count
        }

        return start..<end
    }
    
    // 指定されたLFの場所を返す。
    func newlineIndex(after lineIndex: Int) -> Int? {
        guard lineIndex < newlineIndices.count else { return nil }
        return newlineIndices[lineIndex]
    }
    
    // rangeで指定された領域を含む行の行頭から行末までを返す。末尾の改行を含まない。
    func lineRange(contains range: Range<Int>) -> Range<Int> {
        let startIndex = range.lowerBound
        let endIndex = (range.upperBound > startIndex) ? range.upperBound - 1 : startIndex

        let firstLine = lineIndex(at: startIndex)
        let lastLine  = lineIndex(at: endIndex)

        let start: Int
        if firstLine == 0 {
            start = 0
        } else {
            start = newlineIndices[firstLine - 1] + 1
        }

        let end: Int
        if lastLine < newlineIndices.count {
            end = newlineIndices[lastLine]
        } else {
            end = count
        }

        return start..<end
    }

}




