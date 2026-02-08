//
//  KSyntaxParserIni.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/11,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

final class KSyntaxParserIni: KSyntaxParser {

    init(storage: KTextStorageReadable) {
        super.init(storage: storage, type: .ini)
    }

    override func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] {
        guard range.count > 0 else { return [] }

        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let lineRange = skeleton.lineRange(contains: range)

        var spans: [KAttributedSpan] = []

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        // 行頭の空白/タブをスキップ
        var i = lineRange.lowerBound
        let end = lineRange.upperBound
        while i < end && isSpaceOrTab(bytes[i]) { i += 1 }

        // 空行
        if i >= end { return spans }

        // コメント行
        if bytes[i] == FC.numeric || bytes[i] == FC.semicolon {
            spans.append(makeSpan(range: lineRange.clamped(to: range), role: .comment))
            return spans
        }

        // セクション行: [ ... ]
        if bytes[i] == FC.leftBracket {
            let start = i
            var j = i
            while j < end {
                if bytes[j] == FC.rightBracket {
                    spans.append(makeSpan(range: (start..<j + 1).clamped(to: range), role: .variable))
                    break
                }
                j += 1
            }
            return spans
        }

        // 通常行：キー（左辺）だけ色を当てる
        let dominant = determineDominantSeparatorInFirst100Lines()

        // この行にある最初の '=' と ':' を探す
        var firstEquals: Int? = nil
        var firstColon: Int? = nil
        var p = i
        while p < end {
            let b = bytes[p]
            if b == FC.equals {
                if firstEquals == nil { firstEquals = p }
            } else if b == FC.colon {
                if firstColon == nil { firstColon = p }
            }
            if firstEquals != nil && firstColon != nil { break }
            p += 1
        }

        // どちらも無いなら何もしない
        if firstEquals == nil && firstColon == nil { return spans }

        // セパレータ位置を決める
        var sepPos: Int? = nil
        if let eq = firstEquals, firstColon == nil {
            sepPos = eq
        } else if let co = firstColon, firstEquals == nil {
            sepPos = co
        } else if let eq = firstEquals, let co = firstColon {
            if dominant == FC.colon {
                sepPos = co
            } else if dominant == FC.equals {
                sepPos = eq
            } else {
                // 優勢が決められない場合は、より左のものを採用（最後の保険）
                sepPos = min(eq, co)
            }
        }

        guard let sep = sepPos else { return spans }

        // 左辺（キー）範囲：行頭(i)〜セパレータ直前（末尾空白/タブは除く）
        let keyStart = i
        var keyEnd = sep

        while keyEnd > keyStart && isSpaceOrTab(bytes[keyEnd - 1]) { keyEnd -= 1 }

        // 空キーは無視
        if keyStart >= keyEnd { return spans }

        spans.append(makeSpan(range: (keyStart..<keyEnd).clamped(to: range), role: .keyword))
        return spans
    }

    // 先頭100行だけ見て、このファイルの優勢セパレータを決める（= / : / 0）
    private func determineDominantSeparatorInFirst100Lines() -> UInt8 {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        if bytes.isEmpty { return 0 }

        let lineCount = max(1, skeleton.newlineIndices.count + 1)
        let scanLines = min(100, lineCount)

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        var equalsCount = 0
        var colonCount = 0

        for lineIndex in 0..<scanLines {
            let lr = skeleton.lineRange(at: lineIndex)
            var i = lr.lowerBound
            let end = lr.upperBound

            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
            if i >= end { continue }

            // コメント / セクション行は除外
            let head = bytes[i]
            if head == FC.numeric || head == FC.semicolon { continue }
            if head == FC.leftBracket { continue }

            // その行で「キーが空でない」形の '=' / ':' をカウント
            // （単に存在するだけでなく、左側に空白以外があること）
            var seenNonSpaceInKey = false
            var p = i
            while p < end {
                let b = bytes[p]
                if !isSpaceOrTab(b) { seenNonSpaceInKey = true }

                if b == FC.equals {
                    if seenNonSpaceInKey { equalsCount += 1 }
                    break
                }
                if b == FC.colon {
                    if seenNonSpaceInKey { colonCount += 1 }
                    break
                }
                p += 1
            }
        }

        if equalsCount > colonCount { return FC.equals }
        if colonCount > equalsCount { return FC.colon }
        return 0
    }

    // INIのアウトライン： [section] だけを拾う
    override func outline(in range: Range<Int>?) -> [KOutlineItem] {     // range is ignored for now.
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        if bytes.isEmpty { return [] }

        let lineCount = max(1, skeleton.newlineIndices.count + 1)

        var items: [KOutlineItem] = []
        items.reserveCapacity(64)

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        for lineIndex in 0..<lineCount {
            let lr = skeleton.lineRange(at: lineIndex)
            var i = lr.lowerBound
            let end = lr.upperBound

            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
            if i >= end { continue }

            if bytes[i] != FC.leftBracket { continue }
            i += 1
            if i >= end { continue }

            let nameStart0 = i
            while i < end && bytes[i] != FC.rightBracket { i += 1 }
            if i >= end { continue }   // ']' が無い壊れ行は無視

            let nameEnd0 = i
            var nameStart = nameStart0
            var nameEnd = nameEnd0

            while nameStart < nameEnd && isSpaceOrTab(bytes[nameStart]) { nameStart += 1 }
            while nameEnd > nameStart && isSpaceOrTab(bytes[nameEnd - 1]) { nameEnd -= 1 }

            if nameStart >= nameEnd { continue } // 空のセクション名は無視

            items.append(KOutlineItem(kind: .heading, nameRange: nameStart..<nameEnd, level: 0, isSingleton: false))
        }

        return items
    }

    // 直近の [section] を outer として返す（innerは常にnil）
    override func currentContext(at index: Int) -> (outer: String?, inner: String?) {
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes
        let n = bytes.count
        if n == 0 { return (nil, nil) }

        let clamped = max(0, min(index, n))
        let caretLine = skeleton.lineIndex(at: clamped)

        let maxBackLines = 1000
        let lineCount = max(1, skeleton.newlineIndices.count + 1)

        func isSpaceOrTab(_ b: UInt8) -> Bool { b == FC.space || b == FC.tab }

        var scanned = 0
        var line = min(caretLine, lineCount - 1)

        while line >= 0 && scanned < maxBackLines {
            let lr = skeleton.lineRange(at: line)
            var i = lr.lowerBound
            let end = lr.upperBound

            while i < end && isSpaceOrTab(bytes[i]) { i += 1 }
            if i < end && bytes[i] == FC.leftBracket {
                i += 1
                if i < end {
                    let nameStart0 = i
                    while i < end && bytes[i] != FC.rightBracket { i += 1 }
                    if i < end { // found ']'
                        let nameEnd0 = i
                        var nameStart = nameStart0
                        var nameEnd = nameEnd0

                        while nameStart < nameEnd && isSpaceOrTab(bytes[nameStart]) { nameStart += 1 }
                        while nameEnd > nameStart && isSpaceOrTab(bytes[nameEnd - 1]) { nameEnd -= 1 }

                        if nameStart < nameEnd {
                            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                            return (name, nil)
                        }
                    }
                }
            }

            line -= 1
            scanned += 1
        }

        return (nil, nil)
    }
}
