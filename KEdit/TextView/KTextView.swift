//
//  KTextView.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

final class KTextView: NSView, NSTextInputClient {

    // MARK: - Struct and Enum
    private enum KTextEditDirection : Int {
        case forward = 1
        case backward = -1
    }
    
    // MARK: - Properties
    
    private var textStorageRef: KTextStorageProtocol = KTextStorage()
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
    
    private let showLineNumbers: Bool = true
    private let textPadding: CGFloat = 8
    
    // MARK: - Properties - IME入力用
    
    /// IME変換中のテキスト（確定前）
    private var markedText: NSAttributedString = NSAttributedString()

    /// 変換中の範囲（nilなら非存在）
    private var markedTextRange: Range<Int>? = nil
    
    // MARK: - Computed variables
    
    var selectionRange: Range<Int> = 0..<0 {
        didSet {
            caretView.isHidden = !selectionRange.isEmpty
            scrollCaretToVisible()
            needsDisplay = true
        }
    }

    var caretIndex: Int {
        get { selectionRange.upperBound }
        set { selectionRange = newValue..<newValue }
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
    override var canBecomeKeyView: Bool { return true } // for IME testing. then remove.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }


    // MARK: - Initialization (KTextView methods)

    // Designated Initializer #1（既定: 新規生成）
    override init(frame: NSRect) {
        let storage:KTextStorageProtocol = KTextStorage()
        self.textStorageRef = storage
        layoutManager = KLayoutManager(textStorageRef: storage)
        super.init(frame: frame)
        
        self.wantsLayer = false
        commonInit()
    }

    // Designated Initializer #2（外部からストレージ注入）
    init(frame: NSRect, textStorageRef: KTextStorageProtocol) {
        self.textStorageRef = textStorageRef
        self.layoutManager = KLayoutManager(textStorageRef: textStorageRef)
        super.init(frame: frame)
        commonInit()
    }

    // Designated Initializer #3（完全注入: 将来用）
    init(frame: NSRect, textStorageRef: KTextStorageProtocol, layoutManager: KLayoutManager) {
        self.textStorageRef = textStorageRef
        self.layoutManager = layoutManager
        super.init(frame: frame)
        commonInit()
    }

    // Interface Builder用
    required init?(coder: NSCoder) {
        let storage = KTextStorage()
        self.textStorageRef = storage
        self.layoutManager = KLayoutManager(textStorageRef: storage)
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
        
        // IMEのためのサンプル
        if let context = self.inputContext {
            print("✅ inputContext is available: \(context)")
        } else {
            print("❌ inputContext is nil")
        }
        
        layoutManager.textView = self

        window?.makeFirstResponder(self)  // 念のため明示的に指定
        updateCaretPosition()
       
        // キャレットの位置を再計算して表示しておく。
        updateCaretPosition()
        
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
        
        if let clipView = enclosingScrollView?.contentView {
               NotificationCenter.default.addObserver(
                   self,
                   selector: #selector(clipViewBoundsDidChange(_:)),
                   name: NSView.boundsDidChangeNotification,
                   object: clipView
               )
        }
    }
    
    
    
    
    override func becomeFirstResponder() -> Bool {
        print("\(#function)")
        updateActiveState()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        print("\(#function)")
        updateActiveState()
        return super.resignFirstResponder()
    }
    
    //testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        //print("🧭 Global point: \(point), Local point: \(localPoint), Bounds: \(bounds)")
        //print("scrollview.contentView.frame: \(String(describing: enclosingScrollView?.contentView.frame))")
        //print("self.frame: \(String(describing: frame))")
        let width = frame.size.width
        frame.size = NSSize(width: width+10, height: frame.size.height)
        if bounds.contains(localPoint) {
            print("✅ Returning self")
            return self
        } else {
            print("❌ Returning nil")
            return nil
        }
    }

    deinit {
        caretBlinkTimer?.invalidate()
        
        NotificationCenter.default.removeObserver(self)
    }
    

    // MARK: - Caret (KTextView methods)
    
    private func updateCaretPosition() {
        
        guard let lineInfo = layoutManager.lineInfo(at: caretIndex) else { print("\(#function): updateCaretPosition() failed to find lineInfo"); return }

        let ctLine = lineInfo.ctLine

        let indexInLine = caretIndex - lineInfo.range.lowerBound
        
        guard let layoutRects = makeLayoutRects(bounds: bounds) else {
            print("\(#function): updateCaretPosition() failed to make layoutRects"); return }
        
        let xOffset = CTLineGetOffsetForStringIndex(ctLine, indexInLine, nil)
        
        let x = layoutRects.textRegion.rect.origin.x + layoutRects.horizontalInsets + xOffset
        //let y = layoutRects.textRegion.rect.origin.y + CGFloat(lineIndex) * layoutManager.lineHeight + layoutRects.textEdgeInsets.top
        let y = layoutRects.textRegion.rect.origin.y + CGFloat(lineInfo.hardLineIndex) * layoutManager.lineHeight + layoutRects.textEdgeInsets.top
        let height = layoutManager.lineHeight//font.ascender + abs(font.descender)
        
        caretView.updateFrame(x: x, y: y, height: height)
        caretView.alphaValue = 1.0
        restartCaretBlinkTimer()
        
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
        DispatchQueue.main.async {
            let caretRect = self.caretView.frame.insetBy(dx: -10, dy: -10)
            scrollView.contentView.scrollToVisible(caretRect)
        }
        
    }

    // MARK: - Drawing (NSView methods)
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // test. TextRegionの外枠を赤で描く。
        /*
        let path = NSBezierPath(rect: layoutRects.textRegion.rect)
        NSColor.red.setStroke()
        path.lineWidth = 1
        path.stroke()
         */
        
        guard let layoutRects = makeLayoutRects(bounds: bounds) else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        let lines = layoutManager.lines
        let lineHeight = layoutManager.lineHeight
        let textRect = layoutRects.textRegion.rect
        // 行が見える範囲にあるかどうか確認するためのRange。
        // if verticalRange.contains(textPoint.y) のようにして使う。
        let verticalRange = (visibleRect.minY - lineHeight)..<visibleRect.maxY
        
        /*let bgColor: NSColor = .textBackgroundColor.withAlphaComponent(1.0)
        bgColor.setFill()
        bounds.fill()*/
        // 背景透け対策。
        let bgColor = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)?.withAlphaComponent(1.0) ?? .red
        bgColor.setFill()
        bounds.fill()
        
        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        
        //print("bgColor: \(bgColor.toHexString(includeAlpha: true))")
        //print("layoutManager.maxLineWidth: \(layoutManager.maxLineWidth)")
        
        for (i, line) in lines.enumerated() {
            //let y = CGFloat(i) * lineHeight
            let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
            
            let textPoint = CGPoint(x: textRect.origin.x + layoutRects.horizontalInsets ,
                                    y: textRect.origin.y + y)
            
            // 選択範囲の描画
            let lineRange = line.range
            let selection = selectionRange.clamped(to: lineRange)
            //if !selection.isEmpty {
                
                let startOffset = CTLineGetOffsetForStringIndex(line.ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                var endOffset = CTLineGetOffsetForStringIndex(line.ctLine, selection.upperBound - lineRange.lowerBound, nil)
                //print("startOffset \(startOffset) endOffset \(endOffset)")

                // 改行選択補正
                /*
                let newlineIndex = lineRange.upperBound
                if newlineIndex < textStorageRef.count,
                   let char = textStorageRef[newlineIndex],
                   char == "\n",
                   selection.isEmpty,
                   selectionRange.contains(newlineIndex){
                    print("char")
                    endOffset = bounds.width - textRect.origin.x - startOffset
                } else {
                    endOffset -= startOffset
                }
                 */
            
            // 改行が選択範囲に含まれている場合、その行はboundsの右端まで選択描画。
            if selectionRange.contains(lineRange.upperBound) {
                endOffset = bounds.width - textRect.origin.x - startOffset
            } else {
                endOffset -= startOffset
            }

                let selectionRect = CGRect(
                    x: textRect.origin.x + startOffset + layoutRects.horizontalInsets,
                    y: y,
                    width: endOffset,
                    height: layoutManager.lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            //}
            
            // テキスト部分を描画。
            // 見えている範囲をy方向にlineHeightだけ拡大したもの。見えていない場所は描画しない。
            if verticalRange.contains(textPoint.y) {
            
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState()
                context?.translateBy(x: 0, y: bounds.height)
                context?.scaleBy(x: 1.0, y: -1.0)
                
                let yInFlipped = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
                let ascent = CTFontGetAscent(textStorageRef.baseFont)
                let lineOriginY = bounds.height - yInFlipped - ascent
                
                context?.textPosition = CGPoint(x: textPoint.x, y: lineOriginY)
                CTLineDraw(line.ctLine, context!)
                context?.restoreGState()
            }
            
        }
        
        // 行番号部分を描画。
        if showLineNumbers, let lnRect = layoutRects.lineNumberRegion?.rect {
            NSColor.white.setFill()
            lnRect.fill()
            
            for i in 0..<lines.count {
                let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
                
                let number = "\(i + 1)"
                
                // 非選択行の文字のattribute
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 0.9 * textStorageRef.baseFont.pointSize,weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                // 選択行の文字のattribute
                let attrs_emphasized: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 0.9 * textStorageRef.baseFont.pointSize,weight: .bold),
                    .foregroundColor: NSColor.labelColor
                ]
                
                let size = number.size(withAttributes: attrs)
                //let numberPoint = CGPoint(x: lnRect.maxX - size.width - padding,
                //                          y: lnRect.origin.y + y)
                
                let numberPointX = lnRect.maxX - size.width - layoutRects.textEdgeInsets.left
                let numberPointY = lnRect.origin.y + y - visibleRect.origin.y
                let numberPoint = CGPoint(x: numberPointX, y: numberPointY)
                
                // 見えている範囲をy方向にlineHeightだけ拡大したもの。見えていない場所は描画しない。
                let lineRange = lines[i].range
                let caretIsInLine = lineRange.contains(caretIndex) || caretIndex == lineRange.upperBound
                let selectionOverlapsLine =
                    selectionRange.overlaps(lineRange) ||
                    (!selectionRange.isEmpty &&
                     selectionRange.lowerBound <= lineRange.lowerBound &&
                     selectionRange.upperBound >= lineRange.upperBound)
                
                if caretIsInLine || selectionOverlapsLine {
                    number.draw(at: numberPoint, withAttributes: attrs_emphasized)
                } else {
                    number.draw(at: numberPoint, withAttributes: attrs)
                }
                
            }
        }
        
    }
    /*
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        

        guard let rect = makeLayoutRects(bounds: bounds) else {
            print("\(#function): failed to make layout rects")
            return
        }
        rect.draw(layoutManagerRef: layoutManager, textStorageRef: textStorageRef,baseFont: textStorageRef.baseFont )
    }*/

    /*
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.setFill()
        dirtyRect.fill()

        let rects = layoutRects
        let lines = layoutManager._lines
        let font = textStorageRef.baseFont

        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]

        let lineNumberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.95, weight: .regular),
            .foregroundColor: NSColor.gray
        ]

        for (i, line) in lines.enumerated() {
            let y = rects.textRegion.rect.origin.y + CGFloat(i) * layoutManager.lineHeight

            // 選択範囲の描画
            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)
            if !selection.isEmpty {
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                var endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)

                // 改行選択補正
                let newlineIndex = lineRange.upperBound
                if newlineIndex < textStorageRef.count,
                   let char = textStorageRef[newlineIndex],
                   char == "\n",
                   selectedRange.contains(newlineIndex) {
                    endOffset = bounds.width - rects.textRegion.rect.origin.x - startOffset
                } else {
                    endOffset -= startOffset
                }

                let selectionRect = CGRect(
                    x: rects.textRegion.rect.origin.x + startOffset,
                    y: y,
                    width: endOffset,
                    height: layoutManager.lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            }

            // 行番号の描画
            let lineNumberString = "\(i + 1)" as NSString
            let lineNumberSize = lineNumberString.size(withAttributes: lineNumberAttributes)
            let numberOrigin = CGPoint(
                x: rects.lineNumberRegion.rect.maxX - lineNumberSize.width - 6,
                y: y + (layoutManager.lineHeight - lineNumberSize.height) / 2
            )
            lineNumberString.draw(at: numberOrigin, withAttributes: lineNumberAttributes)

            // 本文描画
            let attributedLine = NSAttributedString(string: line.text, attributes: textAttributes)
            let textPoint = CGPoint(x: rects.textRegion.rect.origin.x, y: y)
            attributedLine.draw(at: textPoint)
        }
    }
     */
    /*
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.setFill()
        dirtyRect.fill()

        let rects = layoutRects
        let lines = layoutManager._lines
        let font = textStorageRef.baseFont

        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        /*
        let lineNumberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.95, weight: .regular),
            .foregroundColor: NSColor.gray
        ]*/

        for (i, line) in lines.enumerated() {
            let y = rects.textRegion.rect.origin.y + CGFloat(i) * layoutManager.lineHeight

            // 選択範囲の描画
            let lineRange = line.range
            let selection = selectedRange.clamped(to: lineRange)
            if !selection.isEmpty {
                let attrString = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attrString)

                let startOffset = CTLineGetOffsetForStringIndex(ctLine, selection.lowerBound - lineRange.lowerBound, nil)
                var endOffset = CTLineGetOffsetForStringIndex(ctLine, selection.upperBound - lineRange.lowerBound, nil)

                // 改行選択補正
                let newlineIndex = lineRange.upperBound
                if newlineIndex < textStorageRef.count,
                   let char = textStorageRef[newlineIndex],
                   char == "\n",
                   selectedRange.contains(newlineIndex) {
                    endOffset = bounds.width - rects.textRegion.rect.origin.x - startOffset
                } else {
                    endOffset -= startOffset
                }

                let selectionRect = CGRect(
                    x: rects.textRegion.rect.origin.x + startOffset,
                    y: y,
                    width: endOffset,
                    height: layoutManager.lineHeight
                )
                selectedTextBGColor.setFill()
                selectionRect.fill()
            }

            // テキスト描画
            let attributedLine = NSAttributedString(string: line.text, attributes: textAttributes)
            let textPoint = CGPoint(x: rects.textRegion.rect.origin.x, y: y)
            attributedLine.draw(at: textPoint)

        }
    }*/
    
    override func setFrameSize(_ newSize: NSSize) {
        guard let rects = makeLayoutRects(bounds: bounds) else {
            print("\(#function) error")
            return
        }
        
        super.setFrameSize(NSSize(width: rects.textRegion.rect.width, height: rects.textRegion.rect.height))
    }
    
    // MARK: - Keyboard Input (NSResponder methods)

    override func keyDown(with event: NSEvent) {
        /*
        window?.makeFirstResponder(self)

        
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
            return
        } /*else if let characters = event.characters, !characters.isEmpty, !event.modifierFlags.contains(.control) {
            // 文字入力（直接挿入）用のロジック
            insertDirectText(characters)
        } else {
            interpretKeyEvents([event])
        }*/
        interpretKeyEvents( [event] )
         */
        
        //print("\(#function) - keyDown()")
        //print("inputContext = \(inputContext?.debugDescription ?? "nil")")
        interpretKeyEvents( [event] )
    }

    
    // テキスト入力に関する実装が済むまでの簡易入力メソッド
    private func insertDirectText(_ text: String) {
        if !selectionRange.isEmpty {
            textStorageRef.replaceCharacters(in: selectionRange, with: [])
            caretIndex = selectionRange.lowerBound
        }

        textStorageRef.insertString(text, at: caretIndex)
        caretIndex += text.count

        layoutManager.rebuildLayout()
        updateFrameSizeToFitContent() // ← これを追加
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
            horizontalSelectionBase = selectionRange.lowerBound
        }
        
        if extendSelection {
            if horizontalSelectionBase! == selectionRange.lowerBound {
                let newBound = selectionRange.upperBound + direction.rawValue
                
                guard newBound <= textStorageRef.count && newBound >= 0 else { return }
                
                selectionRange = min(newBound, horizontalSelectionBase!)..<max(newBound, horizontalSelectionBase!)
            } else {
                let newBound = selectionRange.lowerBound + direction.rawValue
                
                guard newBound <= textStorageRef.count && newBound >= 0 else { return }
                
                selectionRange = min(newBound, horizontalSelectionBase!)..<max(newBound, horizontalSelectionBase!)
            }
        } else {
            if direction == .forward {
                if selectionRange.isEmpty {
                    guard caretIndex < textStorageRef.count else { return }
                    caretIndex += 1
                } else {
                    caretIndex = selectionRange.upperBound
                }
            } else {
                if selectionRange.isEmpty {
                    guard caretIndex > 0 else { return }
                    caretIndex -= 1
                } else {
                    caretIndex = selectionRange.lowerBound
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
        /*
         private var isVerticalAction: 今回のセレクタが垂直方向にキャレット・選択範囲を動かすか否か。
         private var wasVerticalAction: 前回のセレクタが垂直方向にキャレット・選択範囲を動かしたか否か。
         private var wasVerticalActionWithModifySelection: 前回のセレクタが垂直方向の選択範囲を動かしたか否か。
         private var wasHorizontalActionWithModifySelection: 全体のセレクタが水平方向に選択範囲を動かしたか否か。
         private var verticalCaretX: CGFloat?        // 縦方向にキャレットを移動する際の基準X。
         private var verticalSelectionBase: Int?     // 縦方向に選択範囲を拡縮する際の基準点。
         private var horizontalSelectionBase: Int?   // 横方向に選択範囲を拡縮する際の基準点。
         */
        
        // anchor（verticalSelectionBase）を初回のみセット
        if !wasVerticalActionWithModifySelection && extendSelection {
            verticalSelectionBase = selectionRange.lowerBound
        }
        
        // 初回使用時に問題が出ないように。
        if verticalSelectionBase == nil { verticalSelectionBase = caretIndex }

        // 基準インデックス決定（A/Bパターンに基づく）
        let indexForLineSearch: Int = (selectionRange.lowerBound < verticalSelectionBase!) ? selectionRange.lowerBound : selectionRange.upperBound

        // 基準行情報取得
        guard let currentLine = layoutManager.lineInfo(at: indexForLineSearch) else { print("\(#function): lineInfoFor(index:) error \(indexForLineSearch)");  return }

        let newLineIndex = currentLine.hardLineIndex + direction.rawValue
        
        // newLineIndexがTextStorageインスタンスのcharacterの領域を越えている場合には両端まで広げる。
        if newLineIndex < 0 {
            if extendSelection {
                selectionRange = 0..<selectionRange.upperBound
            } else {
                caretIndex = 0
            }
            updateCaretPosition()
            return
        }
        if newLineIndex >= layoutManager.lines.count {
            if extendSelection {
                selectionRange = selectionRange.lowerBound..<textStorageRef.count
            } else {
                caretIndex = textStorageRef.count
            }
            updateCaretPosition()
            return
        }
        
        guard let layoutRects = makeLayoutRects(bounds: bounds) else { print("\(#function); makeLayoutRects error"); return }
        
        let newLineInfo = layoutManager.lines[newLineIndex]
        let ctLine = newLineInfo.ctLine

        // 初回のみ verticalCaretX をセット
        if isVerticalAction && !wasVerticalAction {
            let currentCtLine = currentLine.ctLine
            let indexInLine = caretIndex - currentLine.range.lowerBound
            //verticalCaretX = CTLineGetOffsetForStringIndex(currentCtLine, indexInLine, nil) + layoutRects.textEdgeInsets.left
            verticalCaretX = CTLineGetOffsetForStringIndex(currentCtLine, indexInLine, nil) + layoutRects.horizontalInsets
            //print("first time verticalaction. verticalCaretX:\(verticalCaretX!)")
        }

        // 行末補正
        // 次の行のテキストの横幅より右にキャレットが移動する場合、キャレットはテキストの右端へ。
        let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        //let adjustedX = min(verticalCaretX! - layoutRects.textEdgeInsets.left, lineWidth)
        let adjustedX = min(verticalCaretX! - layoutRects.horizontalInsets, lineWidth)
        //print("adjustedX:\(adjustedX)")
        let targetIndexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: adjustedX, y: 0))
        
        
        // CTLineGetStringIndexForPositionは空行の場合に-1を返すため、その場合のindexは0にする。
        let newCaretIndex = newLineInfo.range.lowerBound + (targetIndexInLine < 0 ? 0 : targetIndexInLine)

        // 選択範囲更新（verticalSelectionBaseは常に基準点として使用）
        if extendSelection {
            let lower = min(verticalSelectionBase!, newCaretIndex)
            let upper = max(verticalSelectionBase!, newCaretIndex)
            selectionRange = lower..<upper
            
            
        } else {
            selectionRange = newCaretIndex..<newCaretIndex
        }
        
        updateCaretPosition()
    }
    
    // MARK: - Text Editing
    
    override func insertNewline(_ sender: Any?) {
        textStorageRef.insertCharacter(String.ReturnCharacter.lf.rawValue, at: caretIndex)
        //caretIndex += 1
        //print("caretIndex: \(caretIndex)")
        /*
        updateFrameSizeToFitContent()
        updateCaretPosition()
        needsDisplay = true*/
    }
    
    // MARK: - COPY and Paste (NSResponder method)
    
    @IBAction func cut(_ sender: Any?) {
        copy(sender)

        textStorageRef.replaceCharacters(in: selectionRange, with: [])
        /*caretIndex = selectionRange.lowerBound
        
        updateFrameSizeToFitContent()
        updateCaretPosition()
        needsDisplay = true*/
    }
    
    @IBAction func copy(_ sender: Any?) {
        guard !selectionRange.isEmpty else { return }
        //guard let slicedCharacters = textStorage.characters(in: selectedRange) else { return }
        guard let slicedCharacters = textStorageRef[selectionRange] else { return }
        let selectedText = String(slicedCharacters)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    @IBAction func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let string = pasteboard.string(forType: .string) else { return }

        textStorageRef.replaceCharacters(in: selectionRange, with: Array(string))
        /*caretIndex = selectionRange.lowerBound + string.count

        updateFrameSizeToFitContent()
        updateCaretPosition()
        needsDisplay = true*/
    }

    @IBAction override func selectAll(_ sender: Any?) {
        selectionRange = 0..<textStorageRef.count
        
    }



    // MARK: - Deletion (NSResponder methods)

    override func deleteBackward(_ sender: Any?) {
        guard caretIndex > 0 else { return }

        if !selectionRange.isEmpty {
            textStorageRef.replaceCharacters(in: selectionRange, with: [])
            //caretIndex = selectionRange.lowerBound
        } else {
            textStorageRef.replaceCharacters(in: caretIndex - 1..<caretIndex, with: [])
            //caretIndex -= 1
        }

        //updateFrameSizeToFitContent()
        verticalCaretX = nil
        //updateCaretPosition()
        //needsDisplay = true
    }
    
    // 前回のアクションのセレクタを保存するために実装
    override func doCommand(by selector: Selector) {
        currentActionSelector = selector
        super.doCommand(by: selector)
        //print(selector)
    }

    // MARK: - Mouse Interaction (NSView methods)
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        
        //キャレット移動のセレクタ記録に残すためのダミーセレクタ。
        doCommand(by: #selector(clearCaretContext(_:)))
        
        guard let layoutRects = makeLayoutRects(bounds: bounds) else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        
        let location = convert(event.locationInWindow, from: nil)
        switch layoutRects.regionType(for: location, layoutManagerRef: layoutManager, textStorageRef: textStorageRef){
        case .text(let index):
            switch event.clickCount {
            case 1: // シングルクリック - クリック位置にキャレットを移動。
                caretIndex = index
                horizontalSelectionBase = index
            case 2: // ダブルクリック - クリックした部分を単語選択。
                if let wordRange = textStorageRef.wordRange(at: index) {
                    selectionRange = wordRange
                } else {
                    caretIndex = index
                }
                horizontalSelectionBase = selectionRange.lowerBound
            case 3: // トリプルクリック - クリックした部分の行全体を選択。
                if let lineInfo = layoutManager.lineInfo(at: index) {
                    let isLastLine = lineInfo.range.upperBound == textStorageRef.count
                    selectionRange = lineInfo.range.lowerBound..<lineInfo.range.upperBound + (isLastLine ? 0 : 1)
                }
                horizontalSelectionBase = selectionRange.lowerBound
            default:
                break
            }
        case .lineNumber(let line):
            let lineInfo = layoutManager.lines[line]
            selectionRange = lineInfo.range
            horizontalSelectionBase = lineInfo.range.lowerBound
        case .outside:
            break
        }

        updateCaretPosition()
        scrollCaretToVisible()
        
    }
    
    
    override func mouseDragged(with event: NSEvent) {
        guard let layoutRects = makeLayoutRects(bounds: bounds) else {
            print("\(#function): layoutRects is nil")
            return
        }
        //キャレット移動のセレクタ記録に残すためのダミーセレクタ。
        doCommand(by: #selector(clearCaretContext(_:)))
        
        let location = convert(event.locationInWindow, from: nil)
        
        switch layoutRects.regionType(for: location, layoutManagerRef: layoutManager, textStorageRef: textStorageRef){
        case .text(let index):
            let dragCaretIndex = index
            let base = horizontalSelectionBase ?? caretIndex
            let lower = min(base, dragCaretIndex)
            let upper = max(base, dragCaretIndex)
            selectionRange = lower..<upper
            
        case .lineNumber(let line):
            //現在の選択範囲から、指定れた行の最後(改行含む)までを選択する。
            //horizontalSelectionBaseより前であれば、行頭までを選択する。
            let lineRange = layoutManager.lines[line].range
            let base = horizontalSelectionBase ?? caretIndex
            if lineRange.upperBound > base {
                selectionRange = base..<lineRange.upperBound
            } else {
                selectionRange = lineRange.lowerBound..<base
            }
            
        case .outside:
            // textRegionより上なら文頭まで、下なら文末まで選択する。
            let textRect = layoutRects.textRegion.rect
            if location.y < textRect.minY {
                selectionRange = 0..<(horizontalSelectionBase ?? caretIndex)
            } else if location.y > (layoutManager.lineHeight * CGFloat(layoutManager.lineCount) + layoutRects.textEdgeInsets.top)  {
                selectionRange = (horizontalSelectionBase ?? caretIndex)..<textStorageRef.count
            }
        }

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
    
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }
    
    
    // MARK: - NSTextInputClient Implementation

    func hasMarkedText() -> Bool {
        return markedTextRange != nil
    }

    func markedRange() -> NSRange {
        guard let range = markedTextRange else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(range)
    }

    func selectedRange() -> NSRange {
        NSRange(selectionRange)
    }
    
    func insertText(_ string: Any, replacementRange: NSRange) {
        
        let text: String
        if let str = string as? String {
            text = str
        } else if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else {
            return
        }

        /*
        let range = Range(replacementRange) ?? selectionRange
        textStorageRef.replaceCharacters(in: range, with: Array(text))
        let insertionPoint = range.lowerBound + text.count
        selectionRange = insertionPoint..<insertionPoint
         */
        
        
        let range = Range(replacementRange) ?? selectionRange
        
        /*let insertionPoint = range.lowerBound + text.count
        selectionRange = insertionPoint..<insertionPoint
        */
        
        textStorageRef.replaceCharacters(in: range, with: Array(text))
       
        markedTextRange = nil
        markedText = NSAttributedString()
        /*
        layoutManager.rebuildLayout()
        updateFrameSizeToFitContent() // ← これを追加
        updateCaretPosition()
        needsDisplay = true
         */
    }
    
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        print("✏️ setMarkedText called with: \(string)")
        
        let attrString: NSAttributedString
        if let str = string as? String {
            attrString = NSAttributedString(string: str)
        } else if let aStr = string as? NSAttributedString {
            attrString = aStr
        } else {
            return
        }

        let plain = attrString.string
        let range = Range(replacementRange) ?? selectionRange

        textStorageRef.replaceCharacters(in: range, with: Array(plain))

        let start = range.lowerBound
        let end = start + plain.count
        markedTextRange = start..<end
        markedText = attrString

        if let sel = Range(selectedRange), sel.upperBound <= markedText.length {
            let selStart = start + sel.lowerBound
            let selEnd = start + sel.upperBound
            selectionRange = selStart..<selEnd
        } else {
            selectionRange = end..<end
        }
    }
    
    func unmarkText() {
        markedTextRange = nil
        markedText = NSAttributedString()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let swiftRange = Range(range),
              swiftRange.upperBound <= textStorageRef.count,
              let chars = textStorageRef[swiftRange] else {
            return nil
        }

        actualRange?.pointee = range
        return NSAttributedString(string: String(chars))
    }

    func characterIndex(for point: NSPoint) -> Int {
        caretIndex // 仮実装（後でマウス位置計算を追加）
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        NSRect(x: 0, y: 0, width: 1, height: 1) // 仮実装（CTLineから取得へ）
    }
    
    /*
    func doCommand(by selector: Selector) {
        // 例: deleteBackward:, insertNewline: などに対応するならここに分岐追加
    }*/

    func baselineDelta(for characterIndex: Int) -> CGFloat {
        0
    }

    func windowLevel() -> Int {
        0
    }

    // MARK: - KTextView methods (helpers)
    
    func textStorageDidModify(_ modification: KStorageModified) {
        switch modification {
        case let .textChanged(range, insertedCount):
            //print("テキスト変更: range = \(range), inserted = \(insertedCount)")
            
            if range.lowerBound == selectionRange.lowerBound /*(削除+)追記*/ ||
                range.upperBound == selectionRange.lowerBound /*1文字削除*/ {
                // このtextviewによる編集。
                caretIndex = range.lowerBound + insertedCount
                //print("自viewによる編集")
            } else {
                // 他のtextviewやapplescriptなどによる編集。動作検証は未。
                print("外部による編集")
                if !(selectionRange.upperBound < range.lowerBound || selectionRange.lowerBound > range.upperBound) {
                    print("選択範囲が外部により変更された部位に重なっている。")
                    caretIndex = range.lowerBound + insertedCount // 暫定的に挿入部の後端に置く。
                }
            }
        case let .colorChanged(range):
            print("カラー変更: range = \(range)")
        }
        
        updateFrameSizeToFitContent()
        updateCaretPosition()
        needsDisplay = true
    }

    private func updateActiveState() {
        let isActive = (window?.isKeyWindow == true) && (window?.firstResponder === self)
        caretView.isHidden = !isActive
        needsDisplay = true
    }
    
    
    // 現在のところinternalとしているが、将来的に公開レベルを変更する可能性あり。
    func updateFrameSizeToFitContent() {
        //print("func name = \(#function)")
        layoutManager.rebuildLayout()

        let totalLines = layoutManager._lines.count
        let lineHeight = layoutManager.lineHeight

        //let edgePadding = KTextView.defaultEdgePadding
        let showLineNumber = true
        let lineNumberWidth: CGFloat = showLineNumber ? 40 : 0

        let height = CGFloat(totalLines) * lineHeight * 4 / 3
        
        //print("layoutManager.maxLineWidth = \(layoutManager.maxLineWidth)")
        guard let layoutRects = makeLayoutRects(bounds: bounds) else {
            print("\(#function): makeLayoutRects failed.")
            return
        }
        let width = layoutManager.maxLineWidth
                    + lineNumberWidth
                    + layoutRects.textEdgeInsets.left * 2
        //+ edgePadding.left
                    //+ edgePadding.right

        //self.frame.size = CGSize(width: width, height: height)
        self.setFrameSize(CGSize(width: width, height: height))

        enclosingScrollView?.contentView.needsLayout = true
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
        enclosingScrollView?.tile()

    }
    
    // LayoutRectsを生成するメソッド。KTextView内ではこれ以外の方法で生成してはならない。
    private func makeLayoutRects(bounds: CGRect) -> LayoutRects? {
        guard let clipBounds = enclosingScrollView?.contentView.bounds else {
            print("\(#function) - clipBound is nil")
            return nil
        }
        
        return LayoutRects(
            layoutManagerRef: layoutManager,
            textStorageRef: textStorageRef,
            bounds: clipBounds,
            visibleRect: visibleRect,
            showLineNumbers: showLineNumbers,
            textEdgeInsets: .default
        )
    }
    
    
    
    // mouseDown()などのセレクター履歴を残すためのダミー。
    @objc func clearCaretContext(_ sender: Any?) { }
    
}

