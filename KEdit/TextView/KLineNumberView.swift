//
//  KLineNumberView.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KLineNumberView: NSView {

    // MARK: - References

    private weak var textStorageRef: KTextStorageReadable?
    private weak var layoutManager: KLayoutManagerReadable?

    // MARK: - Init

    init(
        frame: NSRect,
        textStorageRef: KTextStorageReadable,
        layoutManager: KLayoutManagerReadable
    ) {
        self.textStorageRef = textStorageRef
        self.layoutManager = layoutManager
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 背景塗りつぶし
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fill(dirtyRect)

        guard let layoutManager = layoutManager else { return }

        let lineHeight: CGFloat = 20  // 仮値。今後 layoutManager から取得可能にする予定

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        let visibleHeight = self.bounds.height

        let firstLine = max(Int(dirtyRect.minY / lineHeight), 0)
        let lastLine = Int(dirtyRect.maxY / lineHeight)

        for i in firstLine...lastLine {
            let lineNum = i + 1
            let y = visibleHeight - CGFloat(i + 1) * lineHeight
            let lineRect = CGRect(x: 0, y: y, width: self.bounds.width - 4, height: lineHeight)

            let lineString = "\(lineNum)" as NSString
            lineString.draw(in: lineRect, withAttributes: attributes)
        }
    }

    // MARK: - Public Sync Method

    func syncScrollOrigin(to origin: NSPoint) {
        self.setBoundsOrigin(origin)  // NSViewのAPI
        self.needsDisplay = true
    }
}

