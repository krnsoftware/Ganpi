//
//  KTextView.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

final class KTextView: NSView {

    private enum KTextEditDirection : Int {
        case forward = 1
        case backward = -1
    }
    
    // MARK: - Properties

    private var textStorage: KTextStorage
    private var layoutManager: KLayoutManager
    private let caretView = KCaretView()

    private var caretBlinkTimer: Timer?
    private var verticalCaretX: CGFloat?        // 縦方向にキャレットを移動する際の基準X。
    private var verticalSelectionBase: Int?     // 縦方向に選択範囲を拡縮する際の基準点。
    private var horizontalSelectionBase: Int?   // 横方向に選択範囲を拡縮する際の基準点。
    private var lastActionSelector: Selector?   // 前回受け取ったセレクタ。
    private var currentActionSelector: Selector? { // 今回受け取ったセレクタ。
        willSet { lastActionSelector = currentActionSelector }
    }

    private let lineHeight: CGFloat = 18
    private let leftPadding: CGFloat = 10
    private let topPadding: CGFloat = 30

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
    
    // 今回のセレクタが垂直方向にキャレット選択範囲を動かすものであるか返す。
    private var isVerticalAction: Bool {
        guard let sel = currentActionSelector else { return false }
        return sel == #selector(moveUp(_:)) ||
        sel == #selector(moveDown(_:)) ||
        sel == #selector(moveUpAndModifySelection(_:)) ||
        sel == #selector(moveDownAndModifySelection(_:))
    }
    
    // 前回のセレクタが垂直方向にキャレット・選択範囲を動かすものだったか返す。
    private var wasVerticalAction: Bool {
        guard let sel = lastActionSelector else { return false }
        return sel == #selector(moveUp(_:)) ||
                sel == #selector(moveDown(_:)) ||
                sel == #selector(moveUpAndModifySelection(_:)) ||
                sel == #selector(moveDownAndModifySelection(_:))
    }
    
    // 前回のセレクタが垂直方向の選択範囲を動かすものだったか返す。
    private var wasVerticalActionWithModifySelection: Bool {
        guard let sel = lastActionSelector else { return false }
        return sel == #selector(moveUpAndModifySelection(_:)) ||
                sel == #selector(moveDownAndModifySelection(_:))
    }

    // 前回のセレクタが水平方向に選択範囲を動かすものだったか返す。
    private var wasHorizontalActionWithModifySelection: Bool {
        guard let sel = lastActionSelector else { return false }
        return sel == #selector(moveLeftAndModifySelection(_:)) ||
                sel == #selector(moveRightAndModifySelection(_:))
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }


    // MARK: - Initialization (KTextView methods)

    override init(frame: NSRect) {
        self.textStorage = KTextStorage()
        self.layoutManager = KLayoutManager(textStorage: textStorage)
        super.init(frame: frame)
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
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    
        // 古い監視を解除
        NotificationCenter.default.removeObserver(self)
        
        // 新しい window があれば監視を開始
        if let window = self.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
                
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }
    
    override func becomeFirstResponder() -> Bool {
        updateActiveState()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        updateActiveState()
        return super.resignFirstResponder()
    }
    
    //testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        print("hitTest: \(point)")
        return super.hitTest(point)
    }



    deinit {
        caretBlinkTimer?.invalidate()
        
        NotificationCenter.default.removeObserver(self)
    }
    

    // MARK: - Caret (KTextView methods)
    /*
    private func updateCaretPosition(isVerticalMove: Bool = false) {
        guard let (lineInfo, lineIndex) = findLineInfo(containing: caretIndex) else { return }

        let font = textStorage.baseFont
        let attrString = NSAttributedString(string: lineInfo.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        let indexInLine = caretIndex - lineInfo.range.lowerBound
        let xOffset = CTLineGetOffsetForStringIndex(ctLine, indexInLine, nil)
        
        let x = leftPadding + xOffset
        let y = topPadding + CGFloat(lineIndex) * lineHeight
        let height = font.ascender + abs(font.descender)
        caretView.updateFrame(x: x, y: y, height: height)

        
        caretView.alphaValue = 1.0

        if !isVerticalMove { verticalCaretX = x }
        restartCaretBlinkTimer()
        scrollCaretToVisible()
    }*/
    
    private func updateCaretPosition(isVerticalMove: Bool = false) {
        guard let (lineInfo, lineIndex) = findLineInfo(containing: caretIndex) else { return }

        let font = textStorage.baseFont
        let attrString = NSAttributedString(string: lineInfo.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        let indexInLine = caretIndex - lineInfo.range.lowerBound
        let xOffset = CTLineGetOffsetForStringIndex(ctLine, indexInLine, nil)

        let rects = LayoutRects(bounds: bounds)
        let x = rects.textRegion.rect.origin.x + xOffset
        //let y = rects.textRegion.rect.origin.y + CGFloat(lineIndex) * (font.ascender + abs(font.descender))
        let y = layoutRects.textRegion.rect.origin.y + CGFloat(lineIndex) * layoutManager.lineHeight

        let height = font.ascender + abs(font.descender)
        caretView.updateFrame(x: x, y: y, height: height)
        caretView.alphaValue = 1.0
    }

    private func startCaretBlinkTimer() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.caretView.alphaValue = (self.caretView.alphaValue < 0.5) ? 1.0 : 0.0
        }
    }

    private func restartCaretBlinkTimer() {
        caretBlinkTimer?.invalidate()
        startCaretBlinkTimer()
    }

    private func scrollCaretToVisible() {
        guard let scrollView = self.enclosingScrollView else { return }
        let caretRect = caretView.frame.insetBy(dx: -10, dy: -10)
        scrollView.contentView.scrollToVisible(caretRect)
    }

    // MARK: - Drawing (NSView methods)
    /*
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // 背景色の塗り潰し
        NSColor.white.setFill()
        dirtyRect.fill()
                
        let selectedTextBGColor = window?.isKeyWindow == true ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textStorage.baseFont,
            .foregroundColor: NSColor.textColor
        ]

        for (i, line) in layoutManager.lines.enumerated() {
            //let y = bounds.height - (topPadding + CGFloat(i) * lineHeight)
            let y = topPadding + CGFloat(i) * lineHeight
            
            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)
            if !selection.isEmpty {
                let font = textStorage.baseFont
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                 let endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)
                
                // その行における選択部分の横幅。
                var selectionWidth = endOffset - startOffset
                
                // もしその行の最後の文字が改行文字であり、その文字が選択されているなら右端まで塗り潰す。
                let lastCharIndex = line.range.upperBound
                if let lastChar = textStorage[lastCharIndex], lastChar == "\n", selectedRange.contains(lastCharIndex){
                    selectionWidth = bounds.width - leftPadding - startOffset
                }                
                
                let selectionRect = CGRect(
                    x: leftPadding + startOffset,
                    y: y,
                    width: selectionWidth,
                    height: lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            }

            let attributedLine = NSAttributedString(string: line.text, attributes: attributes)
            attributedLine.draw(at: NSPoint(x: leftPadding, y: y))
        }
    }
     */
    /*
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let ctx = NSGraphicsContext.current?.cgContext
        let rects = LayoutRects(bounds: bounds)

        // 背景色の塗り潰し
        NSColor.white.setFill()
        dirtyRect.fill()

        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor

        let font = textStorage.baseFont
        let lineHeight = font.ascender + abs(font.descender)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]

        for (i, line) in layoutManager.lines.enumerated() {
            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)

            let y = rects.textRegion.rect.origin.y + CGFloat(i) * lineHeight

            if !selection.isEmpty {
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                let endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)

                var selectionWidth = endOffset - startOffset

                // 改行文字を選択している場合、行末まで塗り潰す
                let lastCharIndex = line.range.upperBound
                if let lastChar = textStorage[lastCharIndex],
                   lastChar == "\n",
                   selectedRange.contains(lastCharIndex) {
                    selectionWidth = rects.textRegion.rect.width - startOffset
                }

                let selectionRect = CGRect(
                    x: rects.textRegion.rect.origin.x + startOffset,
                    y: y,
                    width: selectionWidth,
                    height: lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            }

            let attributedLine = NSAttributedString(string: line.text, attributes: attributes)
            attributedLine.draw(at: NSPoint(x: rects.textRegion.rect.origin.x, y: y))
        }
    }*/
    /*override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let layoutRects = self.layoutRects
        let lineHeight = layoutManager.lineHeight
        let leftX = layoutRects.lineNumberRegion.rect.maxX
        let top = layoutRects.edgePadding.top

        // 背景塗りつぶし
        NSColor.white.setFill()
        dirtyRect.fill()

        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textStorage.baseFont,
            .foregroundColor: NSColor.textColor
        ]

        for (i, line) in layoutManager.lines.enumerated() {
            let y = top + CGFloat(i) * lineHeight
            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)

            if !selection.isEmpty {
                let font = textStorage.baseFont
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                let endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)
                var selectionWidth = endOffset - startOffset

                // 行末の改行文字を含む場合は、右端まで塗りつぶす
                let lastCharIndex = line.range.upperBound
                if let lastChar = textStorage[lastCharIndex],
                   lastChar == "\n",
                   selectedRange.contains(lastCharIndex) {
                    selectionWidth = layoutRects.textRegion.visibleWidth - startOffset
                }

                let selectionRect = CGRect(
                    x: leftX + startOffset,
                    y: y,
                    width: selectionWidth,
                    height: lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            }

            // テキスト描画
            let attributedLine = NSAttributedString(string: line.text, attributes: attributes)
            attributedLine.draw(at: NSPoint(x: leftX, y: y))
        }
    }*/
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.setFill()
        dirtyRect.fill()

        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textStorage.baseFont,
            .foregroundColor: NSColor.textColor
        ]

        for (i, line) in layoutManager.lines.enumerated() {
            let y = CGFloat(i) * layoutManager.lineHeight

            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)
            if !selection.isEmpty {
                let attrString = NSAttributedString(string: line.text, attributes: [.font: textStorage.baseFont])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                var endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)

                // 改行が line の後ろにある場合
                let newlineIndex = lineRange.upperBound
                if newlineIndex < textStorage.count,
                   let char = textStorage[newlineIndex],
                   char == "\n",
                   selectedRange.contains(newlineIndex) {
                    endOffset = bounds.width - layoutRects.textRegion.rect.origin.x - startOffset
                } else {
                    endOffset -= startOffset
                }

                let selectionRect = CGRect(
                    x: layoutRects.textRegion.rect.origin.x + startOffset,
                    y: layoutRects.textRegion.rect.origin.y + y,
                    width: endOffset,
                    height: layoutManager.lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            }

            let attributedLine = NSAttributedString(string: line.text, attributes: attributes)
            let drawPoint = CGPoint(
                x: layoutRects.textRegion.rect.origin.x,
                y: layoutRects.textRegion.rect.origin.y + y
            )
            attributedLine.draw(at: drawPoint)
        }
    }
    
    // MARK: - Keyboard Input (NSResponder methods)

    override func keyDown(with event: NSEvent) {
        let isShift = event.modifierFlags.contains(.shift)
        let selector: Selector?

        switch event.keyCode {
        case 123: // ←
            selector = isShift ? #selector(moveLeftAndModifySelection(_:)) : #selector(moveLeft(_:))
        case 124: // →
            selector = isShift ? #selector(moveRightAndModifySelection(_:)) : #selector(moveRight(_:))
        case 125: // ↓
            selector = isShift ? #selector(moveDownAndModifySelection(_:)) : #selector(moveDown(_:))
        case 126: // ↑
            selector = isShift ? #selector(moveUpAndModifySelection(_:)) : #selector(moveUp(_:))
        case 51: // delete
            selector = #selector(deleteBackward(_:))
        default:
            selector = nil
        }

        if let sel = selector {
            doCommand(by: sel)
        } else if let characters = event.characters, !characters.isEmpty, !event.modifierFlags.contains(.control) {
            // 文字入力（直接挿入）用のロジック
            insertDirectText(characters)
        } else {
            interpretKeyEvents([event])
        }
    }

    
    // テキスト入力に関する実装が済むまでの簡易入力メソッド
    private func insertDirectText(_ text: String) {
        if !selectedRange.isEmpty {
            textStorage.replaceCharacters(in: selectedRange, with: [])
            caretIndex = selectedRange.lowerBound
        }

        textStorage.insertString(text, at: caretIndex)
        caretIndex += text.count

        layoutManager.rebuildLayout()
        //verticalCaretX = nil
        updateCaretPosition()
        needsDisplay = true
    }



    // MARK: - Horizontal Movement (NSResponder methods)

    override func moveLeft(_ sender: Any?) {
        
        moveCaretHorizontally(to: .backward, extendSelection: false)
    }

    override func moveRight(_ sender: Any?) {
        
        moveCaretHorizontally(to: .forward, extendSelection: false)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        
        moveCaretHorizontally(to: .forward, extendSelection: true)
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        
        moveCaretHorizontally(to: .backward, extendSelection: true)
    }
    
    private func moveCaretHorizontally(to direction: KTextEditDirection, extendSelection: Bool) {
        
        if !wasHorizontalActionWithModifySelection && extendSelection {
            horizontalSelectionBase = selectedRange.lowerBound
        }
        
        if extendSelection {
            if horizontalSelectionBase! == selectedRange.lowerBound {
                let newBound = selectedRange.upperBound + direction.rawValue
                
                guard newBound <= textStorage.count && newBound >= 0 else { return }
                
                selectedRange = min(newBound, horizontalSelectionBase!)..<max(newBound, horizontalSelectionBase!)
            } else {
                let newBound = selectedRange.lowerBound + direction.rawValue
                
                guard newBound <= textStorage.count && newBound >= 0 else { return }
                
                selectedRange = min(newBound, horizontalSelectionBase!)..<max(newBound, horizontalSelectionBase!)
            }
        } else {
            if direction == .forward {
                if selectedRange.isEmpty {
                    guard caretIndex < textStorage.count else { return }
                    caretIndex += 1
                } else {
                    caretIndex = selectedRange.upperBound
                }
            } else {
                if selectedRange.isEmpty {
                    guard caretIndex > 0 else { return }
                    caretIndex -= 1
                } else {
                    caretIndex = selectedRange.lowerBound
                }
            }
        }
        
        updateCaretPosition()
    }


    // MARK: - Vertical Movement (NSResponder methods)

    override func moveUp(_ sender: Any?) {
        moveCaretVertically(to: .backward, extendSelection: false)
    }

    override func moveDown(_ sender: Any?) {
        moveCaretVertically(to: .forward, extendSelection: false)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        moveCaretVertically(to: .backward, extendSelection: true)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        moveCaretVertically(to: .forward, extendSelection: true)
    }

    
    private func moveCaretVertically(to direction: KTextEditDirection, extendSelection: Bool) {
        // anchor（verticalSelectionBase）を初回のみセット
        if !wasVerticalActionWithModifySelection && extendSelection {
            verticalSelectionBase = selectedRange.lowerBound
        }
        
        // 初回使用時に問題が出ないように。
        if verticalSelectionBase == nil { verticalSelectionBase = caretIndex }

        // 基準インデックス決定（A/Bパターンに基づく）
        let indexForLineSearch: Int = (selectedRange.lowerBound < verticalSelectionBase!) ? selectedRange.lowerBound : selectedRange.upperBound

        // 基準行情報取得
        guard let (currentLine, currentLineIndex) = findLineInfo(containing: indexForLineSearch) else { return }

        let newLineIndex = currentLineIndex + direction.rawValue
        // newLineIndexがTextStorageインスタンスのcharacterの領域を越えている場合には両端まで広げる。
        if newLineIndex < 0 {
            selectedRange = 0..<selectedRange.upperBound
            return
        }
        if newLineIndex >= layoutManager.lines.count {
            selectedRange = selectedRange.lowerBound..<textStorage.count
            return
        }

        let newLine = layoutManager.lines[newLineIndex]
        let font = textStorage.baseFont
        let attrString = NSAttributedString(string: newLine.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        // 初回のみ verticalCaretX をセット
        if isVerticalAction && !wasVerticalAction {
            let currentAttrString = NSAttributedString(string: currentLine.text, attributes: [.font: font])
            let currentCtLine = CTLineCreateWithAttributedString(currentAttrString)
            let indexInLine = caretIndex - currentLine.range.lowerBound
            verticalCaretX = CTLineGetOffsetForStringIndex(currentCtLine, indexInLine, nil) + leftPadding
        }

        // 行末補正
        let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let adjustedX = min(verticalCaretX! - leftPadding, lineWidth)
        var targetIndexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: adjustedX, y: 0))

        // 行末にいる場合の補正
        if caretIndex == currentLine.range.upperBound {
            targetIndexInLine = newLine.text.count
        }

        let newCaretIndex = newLine.range.lowerBound + targetIndexInLine

        // 選択範囲更新（verticalSelectionBaseは常に基準点として使用）
        if extendSelection {
            let lower = min(verticalSelectionBase!, newCaretIndex)
            let upper = max(verticalSelectionBase!, newCaretIndex)
            selectedRange = lower..<upper
            
            
        } else {
            selectedRange = newCaretIndex..<newCaretIndex
        }

        updateCaretPosition(isVerticalMove: true)
    }
    
    // MARK: - COPY and Paste (NSResponder method)
    
    @IBAction func cut(_ sender: Any?) {
        copy(sender)

        textStorage.replaceCharacters(in: selectedRange, with: [])
        caretIndex = selectedRange.lowerBound
        
        layoutManager.rebuildLayout()
        updateCaretPosition()
        needsDisplay = true
    }
    
    @IBAction func copy(_ sender: Any?) {
        guard !selectedRange.isEmpty else { return }
        //guard let slicedCharacters = textStorage.characters(in: selectedRange) else { return }
        guard let slicedCharacters = textStorage[selectedRange] else { return }
        let selectedText = String(slicedCharacters)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    @IBAction func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let string = pasteboard.string(forType: .string) else { return }

        textStorage.replaceCharacters(in: selectedRange, with: Array(string))
        caretIndex = selectedRange.lowerBound + string.count

        layoutManager.rebuildLayout()
        updateCaretPosition()
        needsDisplay = true
    }

    @IBAction override func selectAll(_ sender: Any?) {
        selectedRange = 0..<textStorage.count
        
    }



    // MARK: - Deletion (NSResponder methods)

    override func deleteBackward(_ sender: Any?) {
        guard caretIndex > 0 else { return }

        if !selectedRange.isEmpty {
            textStorage.replaceCharacters(in: selectedRange, with: [])
            caretIndex = selectedRange.lowerBound
        } else {
            textStorage.replaceCharacters(in: caretIndex - 1..<caretIndex, with: [])
            caretIndex -= 1
        }

        layoutManager.rebuildLayout()
        verticalCaretX = nil
        updateCaretPosition()
        needsDisplay = true
    }
    
    // 前回のアクションのセレクタを保存するために実装
    override func doCommand(by selector: Selector) {
        currentActionSelector = selector
        super.doCommand(by: selector)
        //print(selector)
    }

    // MARK: - Mouse Interaction (NSView methods)
    
    /*override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let location = convert(event.locationInWindow, from: nil)
        let rects = LayoutRects(bounds: bounds)

        // テキスト表示領域外なら無視
        guard rects.textRegion.rect.contains(location) else { return }

        // クリック位置をもとに caretIndex を決定
        let relativePoint = CGPoint(
            x: location.x - rects.textRegion.rect.origin.x,
            y: location.y - rects.textRegion.rect.origin.y
        )

        // 行のインデックスを計算
        let font = textStorage.baseFont
        let lineHeight = font.ascender + abs(font.descender)
        let lineIndex = Int(relativePoint.y / lineHeight)

        guard lineIndex >= 0 && lineIndex < layoutManager.lines.count else { return }
        let line = layoutManager.lines[lineIndex]

        let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)

        let indexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativePoint.x, y: 0))
        let newCaretIndex = line.range.lowerBound + indexInLine

        caretIndex = newCaretIndex
        selectedRange = newCaretIndex..<newCaretIndex
        horizontalSelectionBase = newCaretIndex

        updateCaretPosition()
        scrollCaretToVisible()
    }*/
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let location = convert(event.locationInWindow, from: nil)
        let index = caretIndexForClickedPoint(location)

        caretIndex = index
        selectedRange = index..<index
        horizontalSelectionBase = index

        updateCaretPosition()
        scrollCaretToVisible()
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let dragCaretIndex = caretIndexForClickedPoint(location)

        // selectionBase を基準に選択範囲を構築
        let base = horizontalSelectionBase ?? caretIndex
        let lower = min(base, dragCaretIndex)
        let upper = max(base, dragCaretIndex)
        selectedRange = lower..<upper

        updateCaretPosition()
        scrollCaretToVisible()
    }
    
    // MARK: - KTextView methods (notification)
    
    @objc private func windowBecameKey(_ notification: Notification) {
        updateActiveState()
    }
        
    @objc private func windowResignedKey(_ notification: Notification) {
        updateActiveState()
    }

    // MARK: - KTextView methods (helpers)
    
    private func caretIndexForClickedPoint(_ point: NSPoint) -> Int {
        let relativePoint = CGPoint(
            x: point.x - layoutRects.textRegion.rect.origin.x,
            y: point.y - layoutRects.textRegion.rect.origin.y
        )

        let lineHeight = layoutManager.lineHeight
        let lines = layoutManager.lines
        let lineCount = lines.count

        // 上方向に外れている場合：最初の行で X 座標に近い index を返す
        if relativePoint.y < 0,
           let firstLine = lines.first {
            let attrString = NSAttributedString(string: firstLine.text, attributes: [.font: textStorage.baseFont])
            let ctLine = CTLineCreateWithAttributedString(attrString)
            let relativeX = max(0, relativePoint.x)
            let indexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
            return firstLine.range.lowerBound + indexInLine
        }

        // 下方向に外れている場合：最終行で X 座標に近い index を返す
        if relativePoint.y >= CGFloat(lineCount) * lineHeight,
           let lastLine = lines.last {
            let attrString = NSAttributedString(string: lastLine.text, attributes: [.font: textStorage.baseFont])
            let ctLine = CTLineCreateWithAttributedString(attrString)
            let relativeX = max(0, relativePoint.x)
            let indexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
            return lastLine.range.lowerBound + indexInLine
        }

        // 通常の行内クリック
        let lineIndex = Int(relativePoint.y / lineHeight)
        let line = lines[lineIndex]
        let attrString = NSAttributedString(string: line.text, attributes: [.font: textStorage.baseFont])
        let ctLine = CTLineCreateWithAttributedString(attrString)
        let relativeX = max(0, relativePoint.x)
        let indexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relativeX, y: 0))
        return line.range.lowerBound + indexInLine
    }
     
     

    private func findLineInfo(containing index: Int) -> (LineInfo, Int)? {
        for (i, line) in layoutManager.lines.enumerated() {
            if line.range.contains(index) || index == line.range.upperBound {
                return (line, i)
            }
        }
        return nil
    }

    private func updateActiveState() {
        let isActive = (window?.isKeyWindow == true) && (window?.firstResponder === self)
        caretView.isHidden = !isActive
        needsDisplay = true
    }

    
}


extension KTextView {
    struct LayoutRects {
        struct EdgePadding {
            let top: CGFloat
            let bottom: CGFloat
            let left: CGFloat
            let right: CGFloat
        }

        struct LineNumberRegion {
            let rect: CGRect
            let isVisible: Bool

            var width: CGFloat {
                return isVisible ? rect.width : 0
            }
        }

        struct TextRegion {
            let rect: CGRect

            var visibleWidth: CGFloat {
                return rect.width
            }

            var visibleHeight: CGFloat {
                return rect.height
            }
        }

        let bounds: CGRect
        let edgePadding: EdgePadding
        let lineNumberRegion: LineNumberRegion
        let textRegion: TextRegion

        init(bounds: CGRect) {
            self.bounds = bounds
            self.edgePadding = KTextView.LayoutRects.EdgePadding(top: 4, bottom: 4, left: 8, right: 8)

            let lineNumberWidth: CGFloat = 40
            let showLineNumber = true

            let lineRect = CGRect(
                x: edgePadding.left,
                y: edgePadding.bottom,
                width: showLineNumber ? lineNumberWidth : 0,
                height: bounds.height - edgePadding.top - edgePadding.bottom
            )

            let textRect = CGRect(
                x: lineRect.maxX,
                y: edgePadding.bottom,
                width: bounds.width - edgePadding.left - edgePadding.right - lineRect.width,
                height: bounds.height - edgePadding.top - edgePadding.bottom
            )

            self.lineNumberRegion = KTextView.LayoutRects.LineNumberRegion(rect: lineRect, isVisible: showLineNumber)
            self.textRegion = KTextView.LayoutRects.TextRegion(rect: textRect)
        }
    }

    fileprivate var layoutRects: LayoutRects {
        LayoutRects(bounds: self.bounds)
    }
}
