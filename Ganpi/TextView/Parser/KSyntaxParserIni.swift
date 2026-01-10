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
        //let lineRange = skeleton.expandToFullLines(range: range)
        let lineRange = skeleton.lineRange(contains: range)
        
        var i = lineRange.lowerBound
        let end = lineRange.upperBound
        
        var spans: [KAttributedSpan] = []
        
        if skeleton[i] == FC.numeric || skeleton[i] == FC.semicolon {
            spans += [makeSpan(range: lineRange.clamped(to: range), role: .comment)]
        } else if skeleton[i] == FC.leftBracket {
            let start = i
            
            while i < end {
                if skeleton[i] == FC.rightBracket {
                    spans += [makeSpan(range: (start..<i + 1).clamped(to: range), role: .variable)]
                }
                i &+= 1
            }
        }
        return spans
    }
}
