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
    
    static func leadingWhitespaceWidth(storage: KTextStorageReadable, range: Range<Int>, tabWidth: Int) -> Int {
        let skeleton = storage.skeletonString
        var whitespaceWidth = 0
        var isInLeadingTabs = true
        for i in range {
            if skeleton[i] == FC.tab {
                if isInLeadingTabs {
                    whitespaceWidth += tabWidth
                } else {
                    whitespaceWidth += 1
                }
                continue
            } else if skeleton[i] == FC.space {
                whitespaceWidth += 1
                isInLeadingTabs = false
                continue
            }
            break
        }
        return whitespaceWidth
    }
    
    init(storage: KTextStorageReadable, range: Range<Int>) {
        _storage = storage
        self.range = range
    }
    
    var string: String { _storage.string(in: range) }
    
    // 行頭の連続するtab|spaceの範囲を返す。
    var leadingWhitespaceRange: Range<Int> {
        let (spaces, tabs) = leadingSpacesAndTabs()
        return range.lowerBound..<range.lowerBound + spaces + tabs
    }
    
    // spaceの幅に換算した行頭の連続するtab|spaceの幅を返す。
    func leadingWhitespaceWidth(tabWidth: Int) -> Int {
        return Self.leadingWhitespaceWidth(storage: _storage, range: range, tabWidth: tabWidth)
    }
    
    // 行頭の連続するtab|spaceの個数を返す。
    func leadingSpacesAndTabs() -> (spaces:Int, tabs:Int) {
        let skeleton = _storage.skeletonString
        var spaces = 0
        var tabs = 0
        for i in range {
            if skeleton[i] == FC.tab {
                tabs += 1
            } else if skeleton[i] == FC.space {
                spaces += 1
            } else {
                break
            }
        }
        return (spaces:spaces, tabs:tabs)
    }
    
    
    
    /// インデント内（右端は「外側」扱い）で、次/前のタブストップまでの差分を返す。
    /// - 規約: 行頭“連続タブ”のみタブストップ進行。spaceが出た後のtabは幅1。
    /// - ゾーン外や右端（=可視文字直前）では 1 を返す。
    func tabStopDeltaInIndent(at index: Int, tabWidth: Int, direction: KDirection) -> Int {
        precondition(tabWidth > 0)
        guard index >= range.lowerBound, index <= range.upperBound else { log("index out of paragraph", from: self); return 1 }

        let head = leadingWhitespaceRange
        // ★ 境界も“内側”として扱う（contains || == upperBound）
        let isInIndent = head.contains(index) || index == head.upperBound
        guard isInIndent else { return 1 }

        // 行頭から index 手前までを描画規約通りに積算
        let skeleton = _storage.skeletonString
        var columns = 0
        var inLeadingTabs = true
        var cursor = range.lowerBound
        while cursor < index, cursor < range.upperBound {
            let ch = skeleton[cursor]
            if ch == FC.tab {
                if inLeadingTabs {
                    let rem = columns % tabWidth
                    columns += (rem == 0) ? tabWidth : (tabWidth - rem)
                } else {
                    columns += 1
                }
            } else if ch == FC.space {
                columns += 1
                inLeadingTabs = false
            } else {
                break
            }
            cursor += 1
        }

        let rem = columns % tabWidth
        switch direction {
        case .forward:  return (rem == 0) ? tabWidth : (tabWidth - rem)
        case .backward: return (rem == 0) ? tabWidth : rem
        }
    }
    
    
}

class KTextSnapShot {
    private unowned let _storage: KTextStorageReadable
    var paragraphs: [KTextParagraph]
    
    init(storage: KTextStorageReadable) {
        _storage = storage
        
        var parags:[KTextParagraph] = []
        var lower = 0
        for (i, ch) in _storage.skeletonString.bytes.enumerated() {
            if ch == FC.lf {
                parags += [KTextParagraph(storage: _storage, range: lower..<i)]
                lower = i + 1
            }
        }
        parags += [KTextParagraph(storage: _storage, range: lower..<_storage.count)]
        paragraphs = parags
    }
    
    func paragraphIndex(containing index: Int) -> Int? {
        // 許容範囲：0...count（count は文末直後）
        guard index >= 0, index <= _storage.count else { log("out of range.", from: self); return nil }
        if paragraphs.isEmpty { log("empty.", from: self); return nil }

        // 文末（index == count）は最後の段落
        if index == _storage.count { return paragraphs.count - 1 }

        var lo = 0
        var hi = paragraphs.count  // 半開区間
        while lo < hi {
            let mid = (lo + hi) >> 1
            let range = paragraphs[mid].range // [lower, upper)
            if index < range.lowerBound {
                hi = mid
            } else if index >= range.upperBound {
                lo = mid + 1
            } else {
                return mid // lower <= index < upper
            }
        }
        // ここに来るのは “境界ジャスト（= upperBound）”
        return lo > 0 ? (lo - 1) : 0
    }
    
    // rangeを含むparagraphのindexの範囲を返す。
    func paragraphIndexRange(containing range: Range<Int>) -> Range<Int>? {
        if range.isEmpty {
            guard let idx = paragraphIndex(containing: range.lowerBound) else { return nil }
            return idx..<(idx + 1)
        } else {
            guard let lo = paragraphIndex(containing: range.lowerBound) else { return nil }

            let hi: Int
            if range.upperBound == _storage.count {
                // 文末まで選択されている場合：最終段落を含める（末尾が空段落でも漏らさない）
                hi = paragraphs.count - 1
            } else {
                guard let hiIndex = paragraphIndex(containing: range.upperBound - 1) else { return nil }
                hi = hiIndex
            }
            return lo..<(hi + 1) // 半開区間に揃える
        }
    }
    
    // indexの範囲で表されるパラグラフの範囲を返す。最後の行の行末の改行は含まない。
    func paragraphRange(indexRange: Range<Int>) -> Range<Int> {
        precondition(!indexRange.isEmpty)
        let lower = paragraphs[indexRange.lowerBound].range.lowerBound
        let upper = paragraphs[indexRange.upperBound - 1].range.upperBound
        return lower..<upper
    }
}
