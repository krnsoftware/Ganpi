//
//  KGridView.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/12,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
import AppKit

final class KGridView: NSView {

    // MARK: - 基本設定
    override var isFlipped: Bool { true }  // 左上原点・下向き増加

    // MARK: - 内部状態
    private var _phase = 1
    private var _selectedRect: CGRect?
    private var _cellRects: [Character: CGRect] = [:]
    private weak var _delegate: KTextView?

    private let _labels = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    // MARK: - 初期化
    init(delegate: KTextView) {
        _delegate = delegate

        guard let layoutRects = delegate.layoutManager.makeLayoutRects() else {
            log("#01"); super.init(frame: .zero); return
        }

        // 表示範囲（visibleRect）にグリッドを出す
        var frame = delegate.visibleRect
        frame.origin.x += layoutRects.horizontalInsets
        frame.size.width -= layoutRects.horizontalInsets

        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 描画
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let (cols, rows): (Int, Int)
        if _phase == 1 {
            let countMax = min(_labels.count, 36)
            let c = Int(ceil(sqrt(Double(countMax))))
            cols = c
            rows = Int(ceil(Double(countMax) / Double(c)))
        } else {
            cols = 3
            rows = 3
        }

        let count = min(_labels.count, cols * rows)
        let targetRect = _phase == 1 ? bounds : (_selectedRect ?? bounds)
        let w = targetRect.width / CGFloat(cols)
        let h = targetRect.height / CGFloat(rows)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1.0)
        _cellRects.removeAll()

        if let rect = _selectedRect, _phase == 2 {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.fill(rect)
        }

        var index = 0
        for row in 0..<rows {
            for col in 0..<cols {
                guard index < count else { break }
                let ch = _labels[index]; index += 1

                let x = targetRect.origin.x + CGFloat(col) * w
                let y = targetRect.origin.y + CGFloat(row) * h
                let rect = CGRect(x: x, y: y, width: w, height: h)

                ctx.stroke(rect)
                _cellRects[ch] = rect

                let attr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
                let s = NSAttributedString(string: String(ch), attributes: attr)
                let size = s.size()
                s.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2))
            }
        }
    }

    // MARK: - 入力処理
    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers,
              let lower = chars.lowercased().first else { return }

        if lower == "\u{1b}" { closeView(); return } // ESCで閉じる

        let key = Character(String(lower).uppercased())
        guard let rect = _cellRects[key],
              let delegate = _delegate,
              let layoutRects = delegate.layoutManager.makeLayoutRects() else { return }

        if _phase == 1 {
            _selectedRect = rect
            _phase = 2
            needsDisplay = true
            window?.makeFirstResponder(self)
        } else {
            // flipped前提なので座標変換は単純化できる
            // visibleRectとhorizontalInsetsの補正のみ
            let visible = delegate.visibleRect
            let x = rect.midX + layoutRects.horizontalInsets
            let y = rect.midY + visible.origin.y
            let point = CGPoint(x: x, y: y)

            delegate.selectGridCharacter(at: point)
            closeView()
        }
    }

    // MARK: - 閉鎖
    private func closeView() {
        _delegate = nil
        removeFromSuperview()
    }

    override func resignFirstResponder() -> Bool {
        closeView()
        return true
    }
}
