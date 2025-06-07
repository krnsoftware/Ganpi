//
//  KTextView.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

final class KTextView: NSView {

    // MARK: - Properties

    var textStorage: KTextStorage
    var layoutManager: KLayoutManager
    private let caretView = KCaretView()

    private let leftPadding: CGFloat = 10
    private let topPadding: CGFloat = 30
    private let lineHeight: CGFloat = 18

    var selectedRange: Range<Int> = 0..<0 {
        didSet {
            caretView.isHidden = !selectedRange.isEmpty
            needsDisplay = true
        }
    }

    var caretIndex: Int {
        get { selectedRange.upperBound }
        set { selectedRange = newValue..<newValue }
    }

    private var caretBlinkTimer: Timer?
    private var verticalCaretX: CGFloat?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        self.textStorage = KTextStorage()
        self.layoutManager = KLayoutManager(textStorage: textStorage)
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.textStorage = KTextStorage()
        self.layoutManager = KLayoutManager(textStorage: textStorage)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        addSubview(caretView)
        wantsLayer = true
        updateCaretPosition()
        startCaretBlinkTimer()
    }

    deinit {
        caretBlinkTimer?.invalidate()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.setFill()
        dirtyRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textStorage.baseFont,
            .foregroundColor: NSColor.textColor
        ]

        for (i, line) in layoutManager.lines.enumerated() {
            let y = bounds.height - (topPadding + CGFloat(i) * lineHeight)

            // ✅ 選択範囲の描画
            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)
            if !selection.isEmpty {
                let font = textStorage.baseFont
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                let endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)

                let selectionRect = CGRect(
                    x: leftPadding + startOffset,
                    y: y,
                    width: endOffset - startOffset,
                    height: lineHeight
                )
                NSColor.selectedTextBackgroundColor.setFill()
                selectionRect.fill()
            }

            // ✅ テキスト描画
            let attributedLine = NSAttributedString(string: line.text, attributes: attributes)
            attributedLine.draw(at: NSPoint(x: leftPadding, y: y))
        }
    }

    // MARK: - Private Methods

    private func updateCaretPosition(isVerticalMove: Bool = false) {
        guard let (lineInfo, lineIndex) = findCurrentLineInfo() else { return }

        let font = textStorage.baseFont
        let attrString = NSAttributedString(string: lineInfo.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        let indexInLine = caretIndex - lineInfo.range.lowerBound
        let xOffset = CTLineGetOffsetForStringIndex(ctLine, indexInLine, nil)

        let y = bounds.height - (topPadding + CGFloat(lineIndex) * lineHeight + 2)
        let x = leftPadding + xOffset

        let height = font.ascender + abs(font.descender)
        caretView.updateFrame(x: x, y: y, height: height)
        caretView.fadeIn(duration: 0.25)

        if !isVerticalMove {
            verticalCaretX = x
        }
    }

    private func findCurrentLineInfo() -> (line: LineInfo, index: Int)? {
        for (i, line) in layoutManager.lines.enumerated() {
            if line.range.contains(caretIndex) || caretIndex == line.range.upperBound {
                return (line, i)
            }
        }
        return nil
    }

    private func startCaretBlinkTimer() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.caretView.alphaValue < 0.5 {
                self.caretView.fadeIn(duration: 0.25)
            } else {
                self.caretView.fadeOut(duration: 0.25)
            }
        }
    }

    private func restartCaretBlinkTimer() {
        caretBlinkTimer?.invalidate()
        startCaretBlinkTimer()
    }

    // MARK: - Public API

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 123: // ←
            moveCaretLeft(extendSelection: isShift)
        case 124: // →
            moveCaretRight(extendSelection: isShift)
        case 125: // ↓
            moveCaretDown(extendSelection: isShift)
        case 126: // ↑
            moveCaretUp(extendSelection: isShift)
        default:
            interpretKeyEvents([event])
        }

        restartCaretBlinkTimer()
        needsDisplay = true
    }

    override func insertText(_ insertString: Any) {
        guard let text = insertString as? String else { return }

        if textStorage.insertString(text, at: caretIndex) {
            caretIndex += text.count
            layoutManager.rebuildLayout()
            verticalCaretX = nil
            updateCaretPosition()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        caretIndex = caretIndexForClickedPoint(location)
        selectedRange = caretIndex..<caretIndex
        verticalCaretX = nil
        updateCaretPosition()
        caretView.fadeIn(duration: 0)
        restartCaretBlinkTimer()
    }

    // MARK: - Caret Movement

    private func moveCaretLeft(extendSelection: Bool) {
        guard caretIndex > 0 else { return }
        let newIndex = caretIndex - 1

        if extendSelection {
            /*
            // 起点 = 選択範囲の反対側
            let anchor = (selectedRange.lowerBound == caretIndex) ? selectedRange.upperBound : selectedRange.lowerBound
            selectedRange = newIndex..<anchor
            // caretIndex = selectedRange.upperBound なので自然に整合する
            */
            selectedRange = selectedRange.lowerBound - 1..<selectedRange.upperBound
        } else {
            selectedRange = newIndex..<newIndex
        }

        verticalCaretX = nil
        updateCaretPosition()
    }


    private func moveCaretRight(extendSelection: Bool) {
        guard caretIndex < textStorage.count else { return }
        let newIndex = caretIndex + 1

        if extendSelection {
            if selectedRange.isEmpty {
                selectedRange = caretIndex..<newIndex
            } else if caretIndex == selectedRange.lowerBound {
                selectedRange = newIndex..<selectedRange.upperBound
            } else {
                selectedRange = selectedRange.lowerBound..<newIndex
            }
        } else {
            selectedRange = newIndex..<newIndex
        }

        verticalCaretX = nil
        updateCaretPosition()
    }

    private func moveCaretUp(extendSelection: Bool) {
        guard let (currentLine, currentLineIndex) = findCurrentLineInfo() else { return }
        let newLineIndex = currentLineIndex - 1
        guard newLineIndex >= 0 else { return }

        let newLine = layoutManager.lines[newLineIndex]
        let font = textStorage.baseFont
        let attrString = NSAttributedString(string: newLine.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        if verticalCaretX == nil {
            let currentAttrString = NSAttributedString(string: currentLine.text, attributes: [.font: font])
            let currentCtLine = CTLineCreateWithAttributedString(currentAttrString)
            let indexInLine = caretIndex - currentLine.range.lowerBound
            verticalCaretX = CTLineGetOffsetForStringIndex(currentCtLine, indexInLine, nil) + leftPadding
        }

        let relativeX = verticalCaretX! - leftPadding
        let targetIndexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
        let newCaretIndex = newLine.range.lowerBound + targetIndexInLine

        if extendSelection {
            selectedRange = newCaretIndex..<selectedRange.upperBound
        } else {
            selectedRange = newCaretIndex..<newCaretIndex
        }

        updateCaretPosition(isVerticalMove: true)
    }

    private func moveCaretDown(extendSelection: Bool) {
        guard let (currentLine, currentLineIndex) = findCurrentLineInfo() else { return }
        let newLineIndex = currentLineIndex + 1
        guard newLineIndex < layoutManager.lines.count else { return }

        let newLine = layoutManager.lines[newLineIndex]
        let font = textStorage.baseFont
        let attrString = NSAttributedString(string: newLine.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        if verticalCaretX == nil {
            let currentAttrString = NSAttributedString(string: currentLine.text, attributes: [.font: font])
            let currentCtLine = CTLineCreateWithAttributedString(currentAttrString)
            let indexInLine = caretIndex - currentLine.range.lowerBound
            verticalCaretX = CTLineGetOffsetForStringIndex(currentCtLine, indexInLine, nil) + leftPadding
        }

        let relativeX = verticalCaretX! - leftPadding
        let targetIndexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
        let newCaretIndex = newLine.range.lowerBound + targetIndexInLine

        if extendSelection {
            selectedRange = selectedRange.lowerBound..<newCaretIndex
        } else {
            selectedRange = newCaretIndex..<newCaretIndex
        }

        updateCaretPosition(isVerticalMove: true)
    }

    private func caretIndexForClickedPoint(_ point: NSPoint) -> Int {
        for (i, line) in layoutManager.lines.enumerated() {
            let lineY = bounds.height - (topPadding + CGFloat(i) * lineHeight)
            let lineRect = CGRect(x: 0, y: lineY, width: bounds.width, height: lineHeight)
            if lineRect.contains(point) {
                let font = textStorage.baseFont
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)
                let relativeX = point.x - leftPadding
                let indexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
                return line.range.lowerBound + indexInLine
            }
        }
        return textStorage.count
    }
}
