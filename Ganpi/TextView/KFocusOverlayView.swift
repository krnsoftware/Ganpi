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

        // 可視領域いっぱい＝自分の bounds に沿って描く（スクロールで変わらない）
        let r    = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        let accent = NSColor.controlAccentColor

        // ふんわり（外側グロー）
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = 3
        glow.shadowColor = accent.withAlphaComponent(0.35)
        glow.set()
        accent.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 芯（1pt）
        accent.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
