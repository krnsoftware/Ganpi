//
//  LayoutRects+Extended.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit


struct LayoutRects {
    struct Region {
        let rect: CGRect
    }
    
    struct TextEdgeInsets {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
        
        static let `default` = TextEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    }
    
    struct LineNumberEdgeInsets {
        let left: CGFloat
        let right: CGFloat
        
        static let `default` = LineNumberEdgeInsets(left: 10, right: 10)
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
    let textEdgeInsets: TextEdgeInsets
    

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
    
    
    //init(layoutManagerRef: KLayoutManagerReadable, textStorageRef: KTextStorageReadable, bounds: CGRect, visibleRect: CGRect, showLineNumbers: Bool, textEdgeInsets: TextEdgeInsets = .default) {
    init(layoutManagerRef: KLayoutManagerReadable, textStorageRef: KTextStorageReadable, visibleRect: CGRect, showLineNumbers: Bool, wordWrap: Bool, textEdgeInsets: TextEdgeInsets = .default) {
        //_bounds = bounds
        _visibleRect = visibleRect
        _layoutManagerRef = layoutManagerRef
        _textStorageRef = textStorageRef
        self.showLineNumbers = showLineNumbers
        self.wordWrap = wordWrap
        self.textEdgeInsets = textEdgeInsets
        
        let digitCount = max(_minimumLineNumberCharacterWidth, Int(log10(Double(textStorageRef.hardLineCount))))
        
        var charWidth: CGFloat = 20
        if let textStorage = _textStorageRef as? KTextStorage  {
            //charWidth = textStorage.lineNumberDigitWidth
            charWidth = textStorage.lineNumberCharacterMaxWidth
            //log("charWidth: \(charWidth)")
        }
        //let lineNumberWidth = CGFloat(digitCount) * charWidth + 10.0//5.0
        let lineNumberWidth = CGFloat(digitCount) * charWidth + LineNumberEdgeInsets.default.left + LineNumberEdgeInsets.default.right
        
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
            //print("regionType - in lineNumberRegion: \(lineIndex)")
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
            //if lines.indices.contains(lineIndex) {
            if 0 <= lineIndex && lineIndex < lineCount {
                
                guard let line = lines[lineIndex] else { print("\(#function) - invalid lineIndex \(lineIndex)"); return .outside}
                guard let ctLine = line.ctLine else { print("regionType - invalid line") ; return .outside }
                let relativeX = max(0, relativePoint.x)
                //let indexInLine = CTLineGetStringIndexForPosition(line.ctLine, CGPoint(x: relativeX, y: 0))
                let utf16Index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
                let string = String(textStorageRef.characterSlice[line.range])
                /*guard let indexInLine = characterIndex(fromUTF16Offset: utf16Index, in: string) else {
                    log("indexInLine is nil")
                    return .outside
                }*/
                let indexInLine = characterIndex(fromUTF16Offset: utf16Index, in: string) ?? 0
                //print("regionType - in textRegion, lineIndex=\(lineIndex), indexInLine=\(indexInLine)")
                
                // CTLineGetStringIndexForPosition()は、ドキュメントにはないが、空行の場合に-1を返す仕様らしい。
                // 空行の場合はindexは0で問題ないことから、-1の場合には0を返す。
                return .text(index: line.range.lowerBound + (indexInLine >= 0 ? indexInLine : 0))
                
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

    // 与えられた `string` において、UTF16オフセットから Character インデックス（0ベース）を返す。
    // 存在しないオフセットの場合は nil。
    private func characterIndex(fromUTF16Offset utf16Index: Int, in string: String) -> Int? {
        // UTF16オフセットから String.Index を生成
        guard let stringIndex = string.utf16.index(string.utf16.startIndex, offsetBy: utf16Index, limitedBy: string.utf16.endIndex),
              stringIndex <= string.utf16.endIndex else {
            return nil
        }

        let characterIndex = string.distance(from: string.startIndex, to: String.Index(stringIndex, within: string)!)
        return characterIndex
    }
    
}
