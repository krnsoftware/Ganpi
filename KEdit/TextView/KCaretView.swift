//
//  KCaretView.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/05/27.
//

import Cocoa

final class KCaretView: NSView {

    // MARK: - Properties

    var caretColor: NSColor = .keyboardFocusIndicatorColor
    var caretWidth: CGFloat = 2.5

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        _commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        _commonInit()
    }

    private func _commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 0.5
        layer?.masksToBounds = true
        isHidden = false
        alphaValue = 1.0
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        caretColor.withAlphaComponent(1.0).setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }

    // MARK: - Animation

    func fadeIn(duration: TimeInterval = 0.25) {
        self.alphaValue = 0.0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            self.animator().alphaValue = 1.0
        }
    }

    func fadeOut(duration: TimeInterval = 0.25) {
        self.alphaValue = 1.0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            self.animator().alphaValue = 0.0
        }
    }

    // MARK: - Frame 更新

    func updateFrame(x: CGFloat, y: CGFloat, height: CGFloat) {
        frame = CGRect(x: x, y: y, width: caretWidth, height: height)
        setNeedsDisplay(bounds)
    }
}
