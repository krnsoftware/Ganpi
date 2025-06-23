//
//  LayoutRects+Extended.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

extension LayoutRects {
    static let zero = LayoutRects(
        bounds: .zero,
        visibleRect: .zero,
        lineNumberWidth: 0,
        padding: 0,
        showLineNumbers: false
    )
}

struct LayoutRects {
    struct Region {
        let rect: CGRect
        let lineRange: Range<Int>?
    }
    
    private let bounds: CGRect
    private let visibleRect: CGRect
    
    let textRegion: Region
    let lineNumberRegion: Region?
    let padding: CGFloat
    let showLineNumbers: Bool

    var horizontalInsets: CGFloat {
        (lineNumberRegion?.rect.width ?? 0) + padding
    }
    
    
    // paddingはLineNumberRegionの右端と、TextRegionのテキスト表示部分の左端の間のスペース。
    init(bounds: CGRect, visibleRect: CGRect, lineNumberWidth: CGFloat, padding: CGFloat, showLineNumbers: Bool) {
        self.bounds = bounds
        self.visibleRect = visibleRect
        self.padding = padding
        self.showLineNumbers = showLineNumbers
        
        print("layoutrects, init: bounds: \(bounds), lineNumberWidth: \(lineNumberWidth), padding: \(padding), showLineNumbers: \(showLineNumbers)")

        let lineNumberRect: CGRect? = showLineNumbers ?
        CGRect(x: visibleRect.origin.x, y: visibleRect.origin.y, width: lineNumberWidth, height: visibleRect.height) :
            nil

       // let textOriginX = (lineNumberRect?.width ?? 0)
        let textRect = CGRect(x: 0, //textOriginX,
                              y: 0,
                              width: bounds.width,// - textOriginX,
                              height: bounds.height)

        self.lineNumberRegion = lineNumberRect.map { Region(rect: $0, lineRange: nil) }
        self.textRegion = Region(rect: textRect, lineRange: nil)
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
            return .lineNumber(line: lineIndex)
        }

        if textRegion.rect.contains(point) {
            let relativePoint = CGPoint(
                x: point.x - textRegion.rect.origin.x,
                y: point.y - textRegion.rect.origin.y
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
            return .text(index: line.range.lowerBound + indexInLine)
        }

        return .outside
    }

    func draw(layoutManagerRef: KLayoutManagerReadable, textStorageRef: KTextStorageReadable, baseFont: NSFont) {
        let lines = layoutManagerRef.lines
        let lineHeight = layoutManagerRef.lineHeight

        for (i, line) in lines.enumerated() {
            let y = CGFloat(i) * lineHeight
            let textPoint = CGPoint(x: textRegion.rect.origin.x + horizontalInsets ,
                                    y: textRegion.rect.origin.y + y)
            let attrStr = NSAttributedString(string: line.text, attributes: [.font: baseFont, .foregroundColor: NSColor.textColor])
            attrStr.draw(at: textPoint)
            
            //print("draw: showLineNumbers: \(showLineNumbers)")
            
            if showLineNumbers, let lnRect = lineNumberRegion?.rect {
                //NSColor.textBackgroundColor.setFill()
                //lnRect.fill()
                let subrect = CGRect(x: lineNumberRegion!.rect.origin.x, y: lineNumberRegion!.rect.origin.y + y, width: lineNumberRegion!.rect.width, height: lineHeight)
                NSColor.textBackgroundColor.setFill()
                subrect.fill()
                
                let number = "\(i + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 0.9 * baseFont.pointSize, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let size = number.size(withAttributes: attrs)
                //let numberPoint = CGPoint(x: lnRect.maxX - size.width - padding,
                //                          y: lnRect.origin.y + y)
                let numberPoint = CGPoint(x: lnRect.maxX - size.width - padding,
                                          y: lnRect.origin.y + y - visibleRect.origin.y)
                number.draw(at: numberPoint, withAttributes: attrs)
            }
            
        }
    }
}
