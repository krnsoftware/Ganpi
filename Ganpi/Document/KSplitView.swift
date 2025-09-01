//
//  KSplitView.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/08/13.
//


import AppKit

/// 見た目は常に 1pt。掴み幅は delegate 側で拡張する前提。
final class KSplitView: NSSplitView {

    override var dividerThickness: CGFloat { 1.0 }

    override func drawDivider(in rect: NSRect) {
        // 目印：一時的に色を変える（確認後は元に戻してください）
        //NSColor.magenta.setFill()
        //rect.fill()

        //Swift.print("[KSplitView] drawDivider rect=\(rect) thickness=\(dividerThickness) isVertical=\(isVertical)")

        // 本来の細線
        NSColor.separatorColor.setFill()
        if isVertical {
            NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        } else {
            NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
        }
    }
}
