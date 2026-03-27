//
//  KCompletionMenuView.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/03/27,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

final class KCompletionMenuView: NSView {

    private let _visibleRowCount = 5
    private let _horizontalPadding: CGFloat = 3.0
    private let _verticalPadding: CGFloat = 2.0
    private let _fadeHeight: CGFloat = 10.0
    private let _cornerRadius: CGFloat = 2.0

    private var _entries: [String] = []
    private var _showsLowerFade = false
    private var _font: NSFont = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
    private var _lineHeight: CGFloat = 14.0

    override var isFlipped: Bool { true }

    var textOriginX: CGFloat { _horizontalPadding }

    func update(entries: [String], showsLowerFade: Bool, font: NSFont, lineHeight: CGFloat) {
        _entries = entries
        _showsLowerFade = showsLowerFade
        _font = font
        _lineHeight = lineHeight
        needsDisplay = true
    }

    func preferredSize() -> NSSize {
        let visibleEntries = _entries.prefix(_visibleRowCount)
        let maxTextWidth = visibleEntries.reduce(CGFloat.zero) { partialResult, entry in
            let width = (entry as NSString).size(withAttributes: [.font: _font]).width
            return max(partialResult, width)
        }

        let width = max(36.0, ceil(maxTextWidth) + _horizontalPadding * 2.0)
        let height = _verticalPadding * 2.0 + _lineHeight * CGFloat(_visibleRowCount)
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let boundsPath = NSBezierPath(roundedRect: bounds, xRadius: _cornerRadius, yRadius: _cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        boundsPath.fill()

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        boundsPath.lineWidth = 1.0
        boundsPath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: _font,
            .foregroundColor: NSColor.labelColor
        ]

        for rowIndex in 0..<_visibleRowCount {
            guard rowIndex < _entries.count else { continue }
            let y = _verticalPadding + CGFloat(rowIndex) * _lineHeight
            let rect = NSRect(
                x: _horizontalPadding,
                y: y,
                width: bounds.width - _horizontalPadding * 2.0,
                height: _lineHeight
            )
            (_entries[rowIndex] as NSString).draw(in: rect, withAttributes: attributes)
        }

        guard _showsLowerFade else { return }

        let fadeRect = NSRect(
            x: 0.0,
            y: bounds.height - _fadeHeight,
            width: bounds.width,
            height: _fadeHeight
        )

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: fadeRect)

        let colors = [
            NSColor.clear.cgColor,
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        ] as CFArray

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0.0, 1.0]
        ) else {
            context.restoreGState()
            return
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: fadeRect.minX, y: fadeRect.minY),
            end: CGPoint(x: fadeRect.minX, y: fadeRect.maxY),
            options: []
        )

        context.restoreGState()
    }
}
