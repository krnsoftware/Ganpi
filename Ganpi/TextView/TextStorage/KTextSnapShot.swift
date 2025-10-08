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
        guard index >= 0, index <= _storage.count else { log("index: out of range.", from: self); return nil }
        var lo = 0
        var hi = paragraphs.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let range = paragraphs[mid].range
            if index >= range.lowerBound, index <= range.upperBound { return mid }
            if index < range.lowerBound {
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        // 末尾LF直後（空段落）のケース
        if let last = paragraphs.last, index == last.range.lowerBound {
            return paragraphs.count - 1
        }
        return nil
    }
    
    func paragraphRange(containing range: Range<Int>) -> Range<Int>? {
        if range.isEmpty {
            if let idx = paragraphIndex(containing: range.lowerBound) {
                return idx..<idx + 1
            }
            return nil
        }
        // 下端の段落
        guard let lo = paragraphIndex(containing: range.lowerBound) else { return nil }
        
        // 上端は排他的なので、最後に“含まれる”位置を使う
        let lastIncluded = max(0, min(range.upperBound - 1, _storage.count - 1))
        
        guard let hi = paragraphIndex(containing: lastIncluded) else { return nil }
        
        // hiの段落も含めるので、上端は hi + 1
        return lo ..< (hi + 1)
    }
}
