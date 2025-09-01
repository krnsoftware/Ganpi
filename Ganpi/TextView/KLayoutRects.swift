//
//  LayoutRects+Extended.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit


struct KLayoutRects {
    struct Region {
        let rect: CGRect
    }
    
    struct KTextEdgeInsets {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
        
        static let `default` = KTextEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    }
    
    struct KLineNumberEdgeInsets {
        let left: CGFloat
        let right: CGFloat
        
        static let `default` = KLineNumberEdgeInsets(left: 5, right: 10)
    }
    
    //private let _bounds: CGRect
    private let _visibleRect: CGRect
    private let _layoutManagerRef: KLayoutManagerReadable
    private let _textStorageRef: KTextStorageReadable
    
    // LineNumberRegionの行数表示の最小桁数
    private let _minimumLineNumberCharacterWidth = 3
    //private let lineNumberWidth: CGFloat
    
    let textRegion: Region
    let lineNumberRegion: Region?
    let showLineNumbers: Bool
    let wordWrap: Bool
    let textEdgeInsets: KTextEdgeInsets
    

    // テキスト表示の右方向のオフセット
    var horizontalInsets: CGFloat {
        if let width = lineNumberRegion?.rect.width {
            return width + textEdgeInsets.left
        }
        return textEdgeInsets.left
    }
    
    // テキスト表示部分(行番号部分を除く)の横幅
    var textRegionWidth: CGFloat {
        return textRegion.rect.width - horizontalInsets - textEdgeInsets.right 
    }
    
    
    init(layoutManagerRef: KLayoutManagerReadable, textStorageRef: KTextStorageReadable, visibleRect: CGRect, showLineNumbers: Bool, wordWrap: Bool, textEdgeInsets: KTextEdgeInsets = .default) {
        _visibleRect = visibleRect
        _layoutManagerRef = layoutManagerRef
        _textStorageRef = textStorageRef
        self.showLineNumbers = showLineNumbers
        self.wordWrap = wordWrap
        self.textEdgeInsets = textEdgeInsets
        
        let digitCount = max(_minimumLineNumberCharacterWidth, Int(log10(Double(textStorageRef.hardLineCount))) + 1)
        
        var charWidth: CGFloat = 100
        if let textStorage = _textStorageRef as? KTextStorage  {
            charWidth = textStorage.lineNumberCharacterMaxWidth
        }
        let lineNumberWidth = CGFloat(digitCount) * charWidth + KLineNumberEdgeInsets.default.left + KLineNumberEdgeInsets.default.right
        
        let lineNumberRect: CGRect? = showLineNumbers ?
        CGRect(x: visibleRect.origin.x, y: visibleRect.origin.y, width: lineNumberWidth, height: visibleRect.height) :
            nil
        
        self.lineNumberRegion = lineNumberRect.map { Region(rect: $0) }

        let textWidth = wordWrap ? visibleRect.width : max(CGFloat(layoutManagerRef.maxLineWidth) + textEdgeInsets.left + lineNumberWidth + textEdgeInsets.right, visibleRect.width)
        let textHeight = max(CGFloat(layoutManagerRef.lineCount) * layoutManagerRef.lineHeight + textEdgeInsets.top + textEdgeInsets.bottom + visibleRect.height * 0.67,visibleRect.height)
        
        let textRect = CGRect(x: 0, y: 0, width: textWidth, height: textHeight)

        self.textRegion = Region(rect: textRect)
        
    }

    enum RegionType {
        case text(index: Int)
        case lineNumber(line: Int)
        case outside
    }

    func regionType(for point: CGPoint,
                    layoutManagerRef: KLayoutManagerReadable,
                    textStorageRef: KTextStorageReadable) -> RegionType {
        
        let lineHeight = layoutManagerRef.lineHeight
        let lines = layoutManagerRef.lines
        let lineCount = lines.count

        // LineNumberRegionの場合
        if let lnRect = lineNumberRegion?.rect, lnRect.contains(point) {
            let lineIndex = min(Int((point.y - textEdgeInsets.top ) / lineHeight), lineCount - 1)
            return .lineNumber(line: lineIndex)
        }

        // TextRegionの場合
        if textRegion.rect.contains(point) {
            
            let relativePoint = CGPoint(
                x: point.x - textRegion.rect.origin.x - horizontalInsets,
                y: point.y - textRegion.rect.origin.y - textEdgeInsets.top
            )
            
            let lineIndex = Int(relativePoint.y / lineHeight)
            
            // TextRegion内でLineに含まれる場合
            if 0 <= lineIndex && lineIndex < lineCount {
                guard let line = lines[lineIndex] else { log("invalid lineIndex \(lineIndex)"); return .outside}
                let relativeX = max(0, relativePoint.x)
                
                var indexInLine = 0
                if !line.range.isEmpty {
                    let edges = line.characterOffsets()
                    indexInLine = characterIndex(for: relativeX, edges: edges)
                }
                
                return .text(index: line.range.lowerBound + indexInLine)
                
            } else {
                // 1行目より上の場合は0を、下の場合は文末のindexを返す。
                if relativePoint.y < textEdgeInsets.top {
                    return .text(index: 0)
                } else if relativePoint.y >= (CGFloat(lineCount) * lineHeight - textEdgeInsets.bottom) {
                    return .text(index: textStorageRef.count)
                }
                
            }
        }

        return .outside
    }
    
    
    // relativeX: 行左端=0基準のクリックX
    // edges: 各文字の左端 + 行末の終端オフセット（count = 文字数 + 1）
    // 戻り値: caret を置く index（0...文字数）
    @inline(__always)
    private func characterIndex(for relativeX: CGFloat, edges: [CGFloat]) -> Int {
        // 空行（edges==[0] 想定）
        guard edges.count >= 2 else { return 0 }

        let n = edges.count - 1 // 文字数
        let x = max(0, relativeX)

        // 端点ケア
        if x <= edges[0] { return 0 }
        if x >= edges[n] { return n }

        // 区間 [lo, lo+1) を二分探索で特定（edges[lo] <= x < edges[lo+1]）
        var lo = 0, hi = n
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1
            if x < edges[mid] { hi = mid } else { lo = mid }
        }

        // 左75%なら lo、その右25%なら lo+1
        let left = edges[lo], right = edges[lo + 1]
        let threshold = left + (right - left) * 0.75
        return (x < threshold) ? lo : (lo + 1)
    }
    
}
