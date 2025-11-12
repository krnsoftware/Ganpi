//
//  KPairSpan.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/06,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

// テキストの特定の範囲において、ペアとなる括弧、クオートについてそれらの外側・内側を選択するためのクラス。

import Foundation

final class KPairSpan: CustomStringConvertible {
    var range: Range<Int>
    weak var parent: KPairSpan?
    weak var storage: KTextStorageReadable?
    var children: [KPairSpan] = []
    let bracketChar: UInt8

    var description: String {
        var str = "ch:\(Character(UnicodeScalar(bracketChar))), range:\(range)"
        for child in children {
            str += "\n  " + child.description.replacingOccurrences(of: "\n", with: "\n  ")
        }
        return str
    }

    init(bracketChar: UInt8, range: Range<Int>, parent: KPairSpan) {
        self.range = range
        self.parent = parent
        self.bracketChar = bracketChar
    }

    init(storage: KTextStorageReadable, range: Range<Int>, parent: KPairSpan? = nil) {
        self.range = range
        self.storage = storage
        self.parent = parent
        self.bracketChar = 0

        let bytes = storage.skeletonString.bytes
        let pairs: [UInt8: UInt8] = [
            FC.leftParen:   FC.rightParen,
            FC.leftBracket: FC.rightBracket,
            FC.leftBrace:   FC.rightBrace
        ]
        let quotes: Set<UInt8> = [FC.doubleQuote, FC.singleQuote, FC.backtick]

        var stack: [KPairSpan] = [self]
        var i = range.lowerBound
        let end = range.upperBound

        while i < end {
            let c = bytes[i]

            // --- クオート処理 ---
            if quotes.contains(c) {
                let start = i
                i += 1
                while i < end {
                    let d = bytes[i]
                    if d == FC.backSlash { i += 2; continue }
                    if d == c { break }
                    i += 1
                }
                if i < end {
                    let span = KPairSpan(bracketChar: c, range: start..<i + 1, parent: stack.last!)
                    stack.last!.children.append(span)
                }
                i += 1
                continue
            }

            // --- 開き括弧 ---
            if let _ = pairs[c] {
                let newSpan = KPairSpan(bracketChar: c, range: i..<end, parent: stack.last!)
                stack.last!.children.append(newSpan)
                stack.append(newSpan)
                i += 1
                continue
            }

            // --- 閉じ括弧 ---
            if let top = stack.last, let open = pairs.first(where: { $0.value == c })?.key {
                if top.bracketChar == open {
                    top.range = top.range.lowerBound..<i + 1
                    stack.removeLast()
                }
                i += 1
                continue
            }

            i += 1
        }
    }
    
    var outerRange:Range<Int> { range }
    
    var innerRange:Range<Int> { range.lowerBound + 1..<range.upperBound - 1 }
    
    var flatSpans:[KPairSpan] {
        var spans:[KPairSpan] = []
        if bracketChar != 0 { spans += [self] }
        for child in children {
            spans += child.flatSpans
        }
        return spans
    }
    
    func fit(for selection:Range<Int>) -> Bool {
        selection == outerRange || selection == innerRange
    }
    
    func span(contains selection:Range<Int>) -> KPairSpan? {
        for child in children {
            if let span = child.span(contains: selection) {
                return span
            }
        }
        // Range<Int>.contains(_ other:Range<Int>)はother.isEmpty==trueで常にtrueを返す。
        let isContained = selection.isEmpty ? range.contains(selection.lowerBound) : range.contains(selection)
        if bracketChar != 0 && isContained {
            return self
        }
        
        return nil
    }
    
    
    
    func nextSpan(contains selection: Range<Int>, includeBrackets: Bool, direction: KDirection) -> KPairSpan? {
        var allSpans = flatSpans
        if direction == .backward { allSpans = allSpans.reversed() }
        
        if let selected = span(contains: selection) {
            let isInner = selection == selected.innerRange
            let isOuter = selection == selected.outerRange
            let isFit = isInner || isOuter

            // span内部だが一致しないか、またはinnerに一致しつつouter要求またはその逆の場合はそのspanを返す。
            if !isFit || (isOuter && !includeBrackets) || (isInner && includeBrackets) {
                return selected
                
            } else {
                // outer→outer または inner→inner の場合は次へ
                if let i = allSpans.firstIndex(where: { $0 === selected }), i < allSpans.count - 1 {
                    return allSpans[allSpans.index(after: i)]
                }
            }
        } else {
            // spanの外の場合
            for span in allSpans {
                if direction == .forward {
                    if span.range.lowerBound > selection.lowerBound {
                        return span
                    }
                } else {
                    if span.range.upperBound < selection.upperBound {
                        return span
                    }
                }
            }
        }
        return nil
    }

    
}



