//
//  KTextSnapShot.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/08,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

struct KTextWord {
    private unowned let _storage: KTextStorageReadable
    let range: Range<Int>
    
    init(storage: KTextStorageReadable, range: Range<Int>) {
        _storage = storage
        self.range = range
    }
    
    var string: String { _storage.string(in: range) }
}

class KTextParagraph {
    private unowned let _storage: KTextStorageReadable
    let range: Range<Int>
    
    init(storage: KTextStorageReadable, range: Range<Int>) {
        _storage = storage
        self.range = range
    }
    
    var string: String { _storage.string(in: range) }
}

class KTextSnapShot {
    private unowned let _storage: KTextStorageReadable
    var paragraphs: [KTextParagraph]
    
    init(storage: KTextStorageReadable) {
        _storage = storage
        
        var parags:[KTextParagraph] = []
        var lower = 0
        for (i, ch) in _storage.skeletonString.bytes.enumerated() {
            if ch == FuncChar.lf {
                parags += [KTextParagraph(storage: _storage, range: lower..<i)]
                lower = i + 1
            }
        }
        parags += [KTextParagraph(storage: _storage, range: lower..<_storage.count)]
        paragraphs = parags
    }
    
    func paragraphIndex(containing index: Int) -> Int? {
        // 許容範囲：0...count（countは文末直後を指す）
        guard index >= 0, index <= _storage.count else { return nil }
        if paragraphs.isEmpty { return nil }

        // 文末（index == count）は「最後の段落」を返す
        if index == _storage.count { return paragraphs.count - 1 }

        var lo = 0
        var hi = paragraphs.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = paragraphs[mid].range   // [lower, upper) …… upperは排他的
            if index >= r.lowerBound && index < r.upperBound {
                return mid
            } else if index < r.lowerBound {
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        return nil
    }
    
    // rangeを含むparagraphのindexの範囲を返す。
    func paragraphIndexRange(containing range: Range<Int>) -> Range<Int>? {
        if range.isEmpty {
            guard let idx = paragraphIndex(containing: range.lowerBound) else { return nil }
            return idx..<(idx + 1)
        } else {
            guard let lo = paragraphIndex(containing: range.lowerBound),
                  let hi = paragraphIndex(containing: range.upperBound - 1) else { return nil }
            return lo..<(hi + 1)
        }
    }
    
    func paragraphRange(indexRange: Range<Int>) -> Range<Int> {
        precondition(!indexRange.isEmpty)
        let lower = paragraphs[indexRange.lowerBound].range.lowerBound
        let upper = paragraphs[indexRange.upperBound - 1].range.upperBound
        return lower..<upper
    }
}
