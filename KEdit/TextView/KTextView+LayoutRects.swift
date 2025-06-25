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
    
    private let bounds: CGRect
    private let visibleRect: CGRect
    private let layoutManagerRef: KLayoutManagerReadable
    private let textStorageRef: KTextStorageReadable
    
    // LineNumberRegionの行数表示の最小桁数
    private let minimumLineNumberCharacterWidth = 3
    //private let lineNumberWidth: CGFloat
    
    let textRegion: Region
    let lineNumberRegion: Region?
    let showLineNumbers: Bool
    let textEdgeInsets: TextEdgeInsets
    

    // テキスト表示の右方向のオフセット
    var horizontalInsets: CGFloat {
        if let width = lineNumberRegion?.rect.width {
            return width + textEdgeInsets.left
        }
        return textEdgeInsets.left
    }
    
    
    init(layoutManagerRef: KLayoutManagerReadable, textStorageRef: KTextStorageReadable, bounds: CGRect, visibleRect: CGRect, /*lineNumberWidth: CGFloat, */showLineNumbers: Bool, textEdgeInsets: TextEdgeInsets = .default) {
        self.bounds = bounds
        self.visibleRect = visibleRect
        //self.padding = padding
        self.showLineNumbers = showLineNumbers
        self.layoutManagerRef = layoutManagerRef
        self.textStorageRef = textStorageRef
        self.textEdgeInsets = textEdgeInsets
        
        //print("layoutrects, init: bounds: \(bounds), lineNumberWidth: \(lineNumberWidth), padding: \(padding), showLineNumbers: \(showLineNumbers)")
        
        let digitCount = max(minimumLineNumberCharacterWidth, "\(layoutManagerRef.lineCount)".count)
        let attrStr = NSAttributedString(string: "M", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: textStorageRef.baseFont.pointSize * 0.95, weight: .regular)])
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        let charWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let lineNumberWidth = CGFloat(digitCount) * charWidth + 5.0

        
        let lineNumberRect: CGRect? = showLineNumbers ?
        CGRect(x: visibleRect.origin.x, y: visibleRect.origin.y, width: lineNumberWidth, height: visibleRect.height) :
            nil
        
        
        self.lineNumberRegion = lineNumberRect.map { Region(rect: $0) }

        let textWidth = CGFloat(layoutManagerRef.maxLineWidth) + textEdgeInsets.left + lineNumberWidth + textEdgeInsets.right
        let textHeight = CGFloat(layoutManagerRef.lineCount) * layoutManagerRef.lineHeight + textEdgeInsets.top + textEdgeInsets.bottom + visibleRect.height * 0.67 // 見えている領域の2/3くらいの高さを余分に設定する。
       
        /*let textRect = CGRect(x: 0,
                              y: 0,
                              width: CGFloat(layoutManagerRef.maxLineWidth) + textEdgeInsets.left + lineNumberWidth + textEdgeInsets.right,
                              height: CGFloat(layoutManagerRef.lineCount) * layoutManagerRef.lineHeight + textEdgeInsets.top + textEdgeInsets.bottom)*/
        let textRect = CGRect(x: 0, y: 0, width: textWidth, height: textHeight)

        self.textRegion = Region(rect: textRect)
    }

    enum RegionType {
        case text(index: Int)
        case lineNumber(line: Int)
        case outside
    }

    func regionType(for point: CGPoint,
                    layoutManager: KLayoutManagerReadable,
                    textStorage: KTextStorageReadable) -> RegionType {
        
        let lineHeight = layoutManager.lineHeight
        let lines = layoutManager.lines
        let lineCount = lines.count

        if let lnRect = lineNumberRegion?.rect, lnRect.contains(point) {
            let lineIndex = min(Int(point.y / lineHeight), lineCount - 1)
            print("regionType - in lineNumberRegion: \(lineIndex)")
            return .lineNumber(line: lineIndex)
        }

        if textRegion.rect.contains(point) {
            
            /*let relativePoint = CGPoint(
                x: point.x - textRegion.rect.origin.x,
                y: point.y - textRegion.rect.origin.y
            )*/
            let relativePoint = CGPoint(
                x: point.x - textRegion.rect.origin.x - horizontalInsets,
                y: point.y - textRegion.rect.origin.y - textEdgeInsets.top
            )
            
            let lineIndex = Int(relativePoint.y / lineHeight)
            

            guard lines.indices.contains(lineIndex) else {
                return .outside
            }

            let line = lines[lineIndex]
            let attrString = NSAttributedString(string: line.text, attributes: [.font: textStorage.baseFont])
            let ctLine = CTLineCreateWithAttributedString(attrString)
            let relativeX = max(0, relativePoint.x)
            let indexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
            
            //print("regionType - in textRegion, lineIndex=\(lineIndex), indexInLine=\(indexInLine)")
            
            return .text(index: line.range.lowerBound + indexInLine)
        }

        return .outside
    }

    /*
    func draw(layoutManagerRef: KLayoutManagerReadable, textStorageRef: KTextStorageReadable, baseFont: NSFont) {
        let lines = layoutManagerRef.lines
        let lineHeight = layoutManagerRef.lineHeight
        
        /*let bgColor: NSColor = .textBackgroundColor.withAlphaComponent(1.0)
        bgColor.setFill()
        bounds.fill()*/
        // 背景透け対策。
        let bgColor = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)?.withAlphaComponent(1.0) ?? .red
        bgColor.setFill()
        bounds.fill()
        
        //print("bgColor: \(bgColor.toHexString(includeAlpha: true))")
        
        // テキストを上から1行ずつ描画していくが、その後に行番号部分も描画する形式。
        for (i, line) in lines.enumerated() {
            //let y = CGFloat(i) * lineHeight
            let y = CGFloat(i) * lineHeight + textEdgeInsets.top
            
            let textPoint = CGPoint(x: textRegion.rect.origin.x + horizontalInsets ,
                                    y: textRegion.rect.origin.y + y)
            let attrStr = NSAttributedString(string: line.text, attributes: [.font: baseFont, .foregroundColor: NSColor.textColor])
            attrStr.draw(at: textPoint)
            
            //print("draw: showLineNumbers: \(showLineNumbers)")
            
            if showLineNumbers, let lnRect = lineNumberRegion?.rect {
                //NSColor.textBackgroundColor.setFill()
                //lnRect.fill()
                let subrect = CGRect(x: lineNumberRegion!.rect.origin.x, y: lineNumberRegion!.rect.origin.y + y, width: lineNumberRegion!.rect.width, height: lineHeight)
                bgColor.setFill()
                subrect.fill()
                
                //print("textBackgroundColor: \(NSColor.textBackgroundColor.toHexString(includeAlpha: true)!)")
                
                let number = "\(i + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 0.9 * baseFont.pointSize, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let size = number.size(withAttributes: attrs)
                //let numberPoint = CGPoint(x: lnRect.maxX - size.width - padding,
                //                          y: lnRect.origin.y + y)
                let numberPoint = CGPoint(x: lnRect.maxX - size.width - textEdgeInsets.left,
                                          y: lnRect.origin.y + y - visibleRect.origin.y)
                number.draw(at: numberPoint, withAttributes: attrs)
            }
            
        }
        
        // test. TextRegionの外枠を赤で描く。
        let path = NSBezierPath(rect: textRegion.rect)
        NSColor.red.setStroke()
        path.lineWidth = 2
        path.stroke()
    }*/
}
