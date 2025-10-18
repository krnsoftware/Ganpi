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
// 主にTree-Sitterのパースと、テキスト内の制御文字等を検出するために使用される。
final class KSkeletonStringInUTF8 {
    // MARK: - Enum and Struct.
    
   
    
    
    // MARK: - Properties.
    private var _bytes: [UInt8] = []
    private var _newlineCache: [Int]? = nil
    
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

                // ★ ここを明示変換
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
        
        //log("skeleton = \(String(bytes:_bytes, encoding: .utf8)!)",from:self)
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
    
    
    
    func matchesKeyword(at index: Int, word: ArraySlice<UInt8>) -> Bool {
        let wCount = word.count
        guard wCount > 0 else { return false }
        let end = index &+ wCount
        guard index >= 0, end <= _bytes.count else {
            log("index:\(index), wordCount:\(wCount), count:\(_bytes.count) — out of range", from: self)
            return false
        }
        if wCount <= 16,
           let lhs = _bytes.withContiguousStorageIfAvailable({ $0.baseAddress?.advanced(by: index) }),
           let rhs = word.withContiguousStorageIfAvailable({ $0.baseAddress }) {
            return memcmp(lhs, rhs, wCount) == 0
        }
        return _bytes[index..<end].elementsEqual(word)
    }

    func matchesKeyword(at index: Int, word: [UInt8]) -> Bool {
        matchesKeyword(at: index, word: word[...])
    }
    
    
    // 改行コード("\n")のoffsetを全て返す。昇順。
    var newlineIndices: [Int] {
        if let cache = _newlineCache { return cache }
        
        let res = Self.indicesOfCharacter(in: _bytes, range: 0..<_bytes.count, target: FuncChar.lf)
        _newlineCache = res
        return res
    }
    
    // 行頭のインデックスを全て返す。昇順。
    var lineStartIndices: [Int] {
        [0] + newlineIndices.map { $0 + 1 }
    }
    
    
    // --- 二分探索ヘルパ（昇順配列 a 前提） ---
    @inline(__always)
    private func firstIndexGE(_ a: [Int], _ x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo // a中の最初の >= x の位置（なければ a.count）
    }
    
    @inline(__always)
    private func lastIndexLT(_ a: [Int], _ x: Int) -> Int? {
        let i = firstIndexGE(a, x) - 1
        return (i >= 0) ? i : nil
    }

    // 範囲内の行を分割、\nは含めない.
    func lineRanges(range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        let lineFeedIndices = Self.indicesOfCharacter(in: _bytes,range: range,target: FuncChar.lf)
        var result: [Range<Int>] = []
        var lineStart = range.lowerBound
        for lf in lineFeedIndices {
            result.append(lineStart..<lf)
            lineStart = lf + 1
        }
        if lineStart < range.upperBound {
            result.append(lineStart..<range.upperBound)
        }
        return result
    }

    // range を含む行すべて（\n除外で各行Range配列）
    func lineRangeExpanded(range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        let lf = newlineIndices

        let lowerIdx = lastIndexLT(lf, range.lowerBound)
        let lower = lowerIdx.map { lf[$0] + 1 } ?? 0

        let upperIdx = firstIndexGE(lf, range.upperBound)
        let upper = (upperIdx < lf.count) ? lf[upperIdx] : _bytes.count

        return lineRanges(range: lower..<upper)
    }

    // range を行単位に拡張して単一Range（末尾は \n を含む）
    func expandToFullLines(range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty else { return range }
        let lf = newlineIndices

        let lowerIdx = lastIndexLT(lf, range.lowerBound)
        let lower = lowerIdx.map { lf[$0] + 1 } ?? 0

        let upperIdx = firstIndexGE(lf, range.upperBound)
        let upper = (upperIdx < lf.count) ? (lf[upperIdx] + 1) : _bytes.count

        return lower..<upper
    }
}




