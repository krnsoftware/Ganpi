//
//  KSearchEngine.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/03/12,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import Foundation

enum KSearchEngineError: Error {
    case emptySearchString
    case invalidRange
}

struct KSearchEntry {
    let searchString: String
    let replaceString: String?
    let useRegex: Bool
    let ignoreCase: Bool
}

final class KSearchEngine {
    
    let entry: KSearchEntry
    
    private let _regex: NSRegularExpression
    private let _replacementTemplate: String
    
    init(entry: KSearchEntry) throws {
        guard !entry.searchString.isEmpty else {
            throw KSearchEngineError.emptySearchString
        }
        
        self.entry = entry
        
        let pattern = entry.useRegex
            ? entry.searchString
            : NSRegularExpression.escapedPattern(for: entry.searchString)
        
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if entry.ignoreCase {
            options.insert(.caseInsensitive)
        }
        
        _regex = try NSRegularExpression(pattern: pattern, options: options)
        
        if let replaceString = entry.replaceString {
            _replacementTemplate = entry.useRegex
                ? replaceString
                : NSRegularExpression.escapedTemplate(for: replaceString)
        } else {
            _replacementTemplate = ""
        }
    }
    
    // 与えられたtargetString内において、anchorRangeを起点として、direction方向に検索した結果を返す。
    // anchorRangeと戻り値が一致していても気にせず返す。
    // 正規表現検索などで^や$など長さ0の範囲の一致を連続で検索したい場合、searchAdvancingIfNeeded()を利用すること。
    func search(in targetString: String, anchorRange: Range<Int>, direction: KDirection) -> Range<Int>? {
        guard anchorRange.lowerBound >= 0, anchorRange.upperBound <= targetString.count else {
            return nil
        }
        
        let searchRange: Range<Int>
        switch direction {
        case .forward:
            searchRange = anchorRange.upperBound..<targetString.count
            
        case .backward:
            searchRange = 0..<anchorRange.lowerBound
        }
        
        guard let nsSearchRange = nsRange(from: searchRange, in: targetString) else {
            return nil
        }
        
        switch direction {
        case .forward:
            guard let match = _regex.firstMatch(in: targetString, options: [.withoutAnchoringBounds], range: nsSearchRange),
                  let range = Range(match.range, in: targetString) else {
                return nil
            }
            return targetString.integerRange(from: range)
            
        case .backward:
            var lastMatchRange: Range<Int>?
            _regex.enumerateMatches(in: targetString, options: [.withoutAnchoringBounds], range: nsSearchRange) { result, _, _ in
                guard let result,
                      let range = Range(result.range, in: targetString),
                      let intRange = targetString.integerRange(from: range) else {
                    return
                }
                lastMatchRange = intRange
            }
            return lastMatchRange
        }
    }
    
    // searchとほぼ同じ仕様だが、戻り値がanchorそのもの(幅0)の場合に「次」を探す。
    func searchAdvancingIfNeeded(in targetString: String, anchorRange: Range<Int>, direction: KDirection) -> Range<Int>? {
        guard let firstHit = search(in: targetString, anchorRange: anchorRange, direction: direction) else {
            return nil
        }
        
        let anchorPosition: Int
        switch direction {
        case .forward:
            anchorPosition = anchorRange.upperBound
            
        case .backward:
            anchorPosition = anchorRange.lowerBound
        }
        
        // 現在位置そのものの0幅一致でなければ、そのまま返す。
        if !firstHit.isEmpty || firstHit.lowerBound != anchorPosition {
            return firstHit
        }
        
        guard let movedAnchorRange = advancedAnchorRange(in: targetString, anchorRange: anchorRange, direction: direction) else {
            return nil
        }
        
        return search(in: targetString, anchorRange: movedAnchorRange, direction: direction)
    }
    
    func containsMatch(in targetString: String, range: Range<Int>) -> Bool {
        guard let nsRange = nsRange(from: range, in: targetString) else {
            return false
        }
        return _regex.firstMatch(in: targetString, options: [], range: nsRange) != nil
    }
    
    func replaceAll(in targetString: String, range: Range<Int>) -> (count: Int, string: String)? {
        guard range.lowerBound >= 0, range.upperBound <= targetString.count else {
            return nil
        }
        guard let stringRange = targetString.stringIndexRange(from: range) else {
            return nil
        }
        
        let substring = String(targetString[stringRange])
        let mutableString = NSMutableString(string: substring)
        let mutableRange = NSRange(location: 0, length: mutableString.length)
        
        let count = _regex.replaceMatches(
            in: mutableString,
            options: [],
            range: mutableRange,
            withTemplate: _replacementTemplate
        )
        
        return (count, String(mutableString))
    }
    
    private func nsRange(from range: Range<Int>, in targetString: String) -> NSRange? {
        guard let stringRange = targetString.stringIndexRange(from: range) else {
            return nil
        }
        return NSRange(stringRange, in: targetString)
    }
    
    private func advancedAnchorRange(in targetString: String, anchorRange: Range<Int>, direction: KDirection) -> Range<Int>? {
        switch direction {
        case .forward:
            guard anchorRange.upperBound < targetString.count else {
                return nil
            }
            let nextPosition = anchorRange.upperBound + 1
            return nextPosition..<nextPosition
            
        case .backward:
            guard anchorRange.lowerBound > 0 else {
                return nil
            }
            let previousPosition = anchorRange.lowerBound - 1
            return previousPosition..<previousPosition
        }
    }
}
