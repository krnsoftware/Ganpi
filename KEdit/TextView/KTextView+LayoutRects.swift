//
//  KTextView+LayoutRects.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/14.
//

import Cocoa

extension KTextView {
    struct LayoutRects {
        var bounds: CGRect
        var padding: EdgePadding
        var lineNumberRegion: LineNumberRegion
        var textRegion: TextRegion

        init(bounds: CGRect, showLineNumber: Bool = true, lineNumberWidth: CGFloat = 40, padding: EdgePadding = .defaultValue) {
            self.bounds = bounds
            self.padding = padding

            let fullWidth = bounds.width - padding.left - padding.right
            let fullHeight = bounds.height - padding.top - padding.bottom

            let lineRect = CGRect(
                x: padding.left,
                y: padding.bottom,
                width: showLineNumber ? lineNumberWidth : 0,
                height: fullHeight
            )
            let textRect = CGRect(
                x: lineRect.maxX,
                y: padding.bottom,
                width: fullWidth - lineRect.width,
                height: fullHeight
            )

            self.lineNumberRegion = LineNumberRegion(rect: lineRect, isVisible: showLineNumber)
            self.textRegion = TextRegion(rect: textRect)
        }
    }
}

extension KTextView.LayoutRects {
    struct EdgePadding {
        var top: CGFloat
        var bottom: CGFloat
        var left: CGFloat
        var right: CGFloat

        static let defaultValue = EdgePadding(top: 8, bottom: 8, left: 8, right: 8)
    }
}

extension KTextView.LayoutRects {
    struct LineNumberRegion {
        let rect: CGRect
        let isVisible: Bool

        var width: CGFloat {
            return isVisible ? rect.width : 0
        }

        func contains(_ point: CGPoint) -> Bool {
            isVisible && rect.contains(point)
        }
    }
}

extension KTextView.LayoutRects {
    struct TextRegion {
        let rect: CGRect

        var visibleWidth: CGFloat { rect.width }
        var visibleHeight: CGFloat { rect.height }

        func contains(_ point: CGPoint) -> Bool {
            rect.contains(point)
        }
    }
}

