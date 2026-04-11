//
//  KFocusOverlayView.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/08/14.
//


import AppKit

final class KFocusOverlayView: NSView {
    // 表示のトグルだけで制御（非同期・通知なし）
    var showsFocus: Bool = false {
        didSet { isHidden = !showsFocus; if showsFocus { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard showsFocus else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let focusRect = bounds.integral.insetBy(dx: 0.0, dy: 0.0)
        guard focusRect.width >= 12.0, focusRect.height >= 12.0 else { return }

        let gradientWidth: CGFloat = 5.0
        let accentColor = NSColor.controlAccentColor.withAlphaComponent(1.0)
        let transparentColor = accentColor.withAlphaComponent(0.0)

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                accentColor.withAlphaComponent(0.26).cgColor,
                accentColor.withAlphaComponent(0.12).cgColor,
                transparentColor.cgColor
            ] as CFArray,
            locations: [0.0, 0.45, 1.0]
        ) else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }

        // 補間をきれいにする
        context.setShouldAntialias(true)
        //context.setInterpolationQuality(.high)

        // 上辺
        let topRect = CGRect(
            x: focusRect.minX,
            y: focusRect.maxY - gradientWidth,
            width: focusRect.width,
            height: gradientWidth
        )
        context.saveGState()
        context.clip(to: topRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: topRect.minX, y: topRect.maxY),
            end: CGPoint(x: topRect.minX, y: topRect.minY),
            options: []
        )
        context.restoreGState()

        // 下辺
        let bottomRect = CGRect(
            x: focusRect.minX,
            y: focusRect.minY,
            width: focusRect.width,
            height: gradientWidth
        )
        context.saveGState()
        context.clip(to: bottomRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bottomRect.minX, y: bottomRect.minY),
            end: CGPoint(x: bottomRect.minX, y: bottomRect.maxY),
            options: []
        )
        context.restoreGState()

        // 左辺
        let leftRect = CGRect(
            x: focusRect.minX,
            y: focusRect.minY,
            width: gradientWidth,
            height: focusRect.height
        )
        context.saveGState()
        context.clip(to: leftRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: leftRect.minX, y: leftRect.minY),
            end: CGPoint(x: leftRect.maxX, y: leftRect.minY),
            options: []
        )
        context.restoreGState()

        // 右辺
        let rightRect = CGRect(
            x: focusRect.maxX - gradientWidth,
            y: focusRect.minY,
            width: gradientWidth,
            height: focusRect.height
        )
        context.saveGState()
        context.clip(to: rightRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rightRect.maxX, y: rightRect.minY),
            end: CGPoint(x: rightRect.minX, y: rightRect.minY),
            options: []
        )
        context.restoreGState()
    }
}
