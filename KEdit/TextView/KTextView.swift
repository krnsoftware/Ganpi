//
//  KTextView.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

final class KTextView: NSView, NSTextInputClient, NSDraggingSource {

    // MARK: - Struct and Enum
    private enum KTextEditDirection : Int {
        case forward = 1
        case backward = -1
    }
    
    private enum KMouseSelectionMode {
        case character
        case word
        case line
    }
    
    // MARK: - Properties
    
    private var _textStorageRef: KTextStorageProtocol = KTextStorage()
    private var _layoutManager: KLayoutManager
    private let _caretView = KCaretView()
    
    // キャレットの表示に関するプロパティ
    private var _caretBlinkTimer: Timer?
    
    // キャレットの動作に関するプロパティ
    private var _verticalCaretX: CGFloat?        // 縦方向にキャレットを移動する際の基準X。
    private var _verticalSelectionBase: Int?     // 縦方向に選択範囲を拡縮する際の基準点。
    private var _horizontalSelectionBase: Int?   // 横方向に選択範囲を拡縮する際の基準点。
    private var _lastActionSelector: Selector?   // 前回受け取ったセレクタ。
    private var _currentActionSelector: Selector? { // 今回受け取ったセレクタ。
        willSet { _lastActionSelector = _currentActionSelector }
    }
    
    // マウスによる領域選択に関するプロパティ
    private var _latestClickedCharacterIndex: Int?
    private var _mouseSelectionMode: KMouseSelectionMode = .character
    
    // マウスによる領域選択でvisibleRectを越えた場合のオートスクロールに関するプロパティ
    private var _dragTimer: Timer?
    
    // ドラッグ&ドロップに関するプロパティ
    private var _dragStartPoint: NSPoint? = nil
    private var _prepareDraggingText: Bool = false
    private let _minimumDragDistance: CGFloat = 3.0
    private var _singleClickPending: Bool = false
    
    // 文書の編集や外見に関するプロパティ
    private var _showLineNumbers: Bool = true
    private var _autoIndent: Bool = true
    private var _wordWrap: Bool = true
    
    // Text Input Clientの実装。
    // IME変換中のテキスト（確定前）
    private var _markedText: NSAttributedString = NSAttributedString()

    // 変換中の範囲（nilなら非存在）
    private var _markedTextRange: Range<Int>? = nil
    
    // required.
    var markedText: NSAttributedString {
        get { _markedText }
    }
    
    var markedTextRange: Range<Int>? {
        get { _markedTextRange }
    }
    
    // not required.
    private var _replacementRange: Range<Int>? = nil
    var replacementRange: Range<Int>? { get { _replacementRange } }
    
    
    // MARK: - Computed variables
    
    var selectionRange: Range<Int> = 0..<0 {
        didSet {
            _caretView.isHidden = !selectionRange.isEmpty
            //scrollCaretToVisible()
            needsDisplay = true
        }
    }

    var caretIndex: Int {
        get { selectionRange.upperBound }
        set { selectionRange = newValue..<newValue }
    }
    
    var wordWrap: Bool {
        get { _wordWrap }
        set { _wordWrap = newValue }
    }
    
    var showLineNumbers: Bool {
        get { _showLineNumbers }
        set { _showLineNumbers = newValue }
    }
    
    // 今回のセレクタが垂直方向にキャレット選択範囲を動かすものであるか返す。
    private var isVerticalAction: Bool {
        guard let sel = _currentActionSelector else { return false }
        return sel == #selector(moveUp(_:)) ||
        sel == #selector(moveDown(_:)) ||
        sel == #selector(moveUpAndModifySelection(_:)) ||
        sel == #selector(moveDownAndModifySelection(_:))
    }
    
    // 前回のセレクタが垂直方向にキャレット・選択範囲を動かすものだったか返す。
    private var wasVerticalAction: Bool {
        guard let sel = _lastActionSelector else { return false }
        return sel == #selector(moveUp(_:)) ||
                sel == #selector(moveDown(_:)) ||
                sel == #selector(moveUpAndModifySelection(_:)) ||
                sel == #selector(moveDownAndModifySelection(_:))
    }
    
    // 前回のセレクタが垂直方向の選択範囲を動かすものだったか返す。
    private var wasVerticalActionWithModifySelection: Bool {
        guard let sel = _lastActionSelector else { return false }
        return sel == #selector(moveUpAndModifySelection(_:)) ||
                sel == #selector(moveDownAndModifySelection(_:))
    }

    // 前回のセレクタが水平方向に選択範囲を動かすものだったか返す。
    private var wasHorizontalActionWithModifySelection: Bool {
        guard let sel = _lastActionSelector else { return false }
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
        self._textStorageRef = storage
        _layoutManager = KLayoutManager(textStorageRef: storage)
        super.init(frame: frame)
        
        self.wantsLayer = false
        commonInit()
    }

    // Designated Initializer #2（外部からストレージ注入）
    init(frame: NSRect, textStorageRef: KTextStorageProtocol) {
        self._textStorageRef = textStorageRef
        self._layoutManager = KLayoutManager(textStorageRef: textStorageRef)
        super.init(frame: frame)
        commonInit()
    }

    // Designated Initializer #3（完全注入: 将来用）
    init(frame: NSRect, textStorageRef: KTextStorageProtocol, layoutManager: KLayoutManager) {
        self._textStorageRef = textStorageRef
        self._layoutManager = layoutManager
        super.init(frame: frame)
        commonInit()
    }

    // Interface Builder用
    required init?(coder: NSCoder) {
        let storage = KTextStorage()
        self._textStorageRef = storage
        self._layoutManager = KLayoutManager(textStorageRef: storage)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        addSubview(_caretView)
        wantsLayer = true
        updateCaretPosition()
        startCaretBlinkTimer()
        
        registerForDraggedTypes([.string])
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        /*
        // IMEのためのサンプル
        if let context = self.inputContext {
            print("✅ inputContext is available: \(context)")
        } else {
            print("❌ inputContext is nil")
        }*/
        
        _layoutManager.textView = self

        window?.makeFirstResponder(self)  // 念のため明示的に指定
       
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
    
    override func viewWillDraw() {
        super.viewWillDraw()
        
        // ソフトラップの場合、visibleRectに合わせて行の横幅を変更する必要があるが、
        // scrollview.clipViewでの変更がないため通知含めvisibleRectの変更を知るすべがない。
        // このため、viewWillDraw()でdraw()される直前に毎回チェックを行なうことにした。
        if wordWrap {
            _layoutManager.textViewFrameInvalidated()
            updateCaretPosition()
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
        let width = frame.size.width
        frame.size = NSSize(width: width+10, height: frame.size.height)
        if bounds.contains(localPoint) {
            //print("✅ Returning self")
            return self
        } else {
            //print("❌ Returning nil")
            return nil
        }
    }

    deinit {
        _caretBlinkTimer?.invalidate()
        
        NotificationCenter.default.removeObserver(self)
    }
    

    // MARK: - Caret (KTextView methods)
    
    private func updateCaretPosition() {
        let caretPosition = characterPosition(at: caretIndex)
        _caretView.updateFrame(x: caretPosition.x, y: caretPosition.y, height: _layoutManager.lineHeight)
        
        _caretView.alphaValue = 1.0
        restartCaretBlinkTimer()
        
    }

    private func startCaretBlinkTimer() {
        _caretBlinkTimer?.invalidate()
        _caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self._caretView.alphaValue = (self._caretView.alphaValue < 0.5) ? 1.0 : 0.0
        }
    }

    private func restartCaretBlinkTimer() {
        _caretBlinkTimer?.invalidate()
        startCaretBlinkTimer()
    }

    private func scrollCaretToVisible() {
        guard let scrollView = self.enclosingScrollView else { return }
        DispatchQueue.main.async {
            let caretRect = self._caretView.frame.insetBy(dx: -10, dy: -10)
            scrollView.contentView.scrollToVisible(caretRect)
        }
        
    }

    // MARK: - Drawing (NSView methods)
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        //print("\(#function): done.")
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        // test. TextRegionの外枠を赤で描く。
        /*
        let path = NSBezierPath(rect: layoutRects.textRegion.rect)
        NSColor.red.setStroke()
        path.lineWidth = 1
        path.stroke()
        */
        
        let lines = _layoutManager.lines
        let lineHeight = _layoutManager.lineHeight
        let textRect = layoutRects.textRegion.rect
        
        // 行が見える範囲にあるかどうか確認するためのRange。
        // if verticalRange.contains(textPoint.y) のようにして使う。
        let verticalRange = (visibleRect.minY - lineHeight)..<visibleRect.maxY
        
        // 背景透け対策。
        let bgColor = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)?.withAlphaComponent(1.0) ?? .red
        bgColor.setFill()
        bounds.fill()
        
        let selectedTextBGColor = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        
        
        for i in 0..<lines.count {
            guard let line = lines[i] else { log("line[i] is nil.", from:self); continue }
            let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
            
            // 選択範囲の描画
            let lineRange = line.range
            let selection = selectionRange.clamped(to: lineRange)
            
            let startOffset = line.characterOffset(at: selection.lowerBound - lineRange.lowerBound)
            var endOffset = line.characterOffset(at: selection.upperBound - lineRange.lowerBound)
            
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
                height: _layoutManager.lineHeight
            )
            selectedTextBGColor.setFill()
            selectionRect.fill()
            
            
        }
        
        // テキストを描画
        if hasMarkedText(), let repRange = _replacementRange{
            lines.addFakeLine(replacementRange: repRange, attrString: _markedText)
        }
        for i in 0..<lines.count {
            let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
            
            let textPoint = CGPoint(x: textRect.origin.x + layoutRects.horizontalInsets ,
                                    y: textRect.origin.y + y)
            
            guard let line = lines[i] else { continue }
            
            if verticalRange.contains(textPoint.y) {
                guard let ctLine = line.ctLine else { continue }
                drawCTLine(ctLine: ctLine, x: textPoint.x, y: y)
            }
        }
        lines.removeFakeLines()
        
        // 行番号部分を描画。
        if _showLineNumbers, let lnRect = layoutRects.lineNumberRegion?.rect {
            NSColor.white.setFill()
            lnRect.fill()
            
            // 非選択行の文字のattribute
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 0.9 * _textStorageRef.baseFont.pointSize,weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            // 選択行の文字のattribute
            let attrs_emphasized: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 0.9 * _textStorageRef.baseFont.pointSize,weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
            
            for i in 0..<lines.count {
                guard let line = lines[i] else { log("line number: line[i] is nil.", from:self); continue }
                let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
                
                if line.softLineIndex > 0 || !verticalRange.contains(y) {
                    continue
                }
                
                let number = "\(line.hardLineIndex + 1)"
                
                let size = number.size(withAttributes: attrs)
                
                let numberPointX = lnRect.maxX - size.width - layoutRects.textEdgeInsets.left
                let numberPointY = lnRect.origin.y + y - visibleRect.origin.y
                let numberPoint = CGPoint(x: numberPointX, y: numberPointY)
                
                if !verticalRange.contains(numberPoint.y) { continue }
                
                let lineRange = _textStorageRef.lineRange(at: line.range.lowerBound) ?? line.range
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
   
    
    override func setFrameSize(_ newSize: NSSize) {
        guard let rects = _layoutManager.makeLayoutRects() else {
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
        
        scrollCaretToVisible()
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
            _horizontalSelectionBase = selectionRange.lowerBound
        }
        
        if extendSelection {
            if _horizontalSelectionBase! == selectionRange.lowerBound {
                let newBound = selectionRange.upperBound + direction.rawValue
                
                guard newBound <= _textStorageRef.count && newBound >= 0 else { return }
                
                selectionRange = min(newBound, _horizontalSelectionBase!)..<max(newBound, _horizontalSelectionBase!)
            } else {
                let newBound = selectionRange.lowerBound + direction.rawValue
                
                guard newBound <= _textStorageRef.count && newBound >= 0 else { return }
                
                selectionRange = min(newBound, _horizontalSelectionBase!)..<max(newBound, _horizontalSelectionBase!)
            }
        } else {
            if direction == .forward {
                if selectionRange.isEmpty {
                    guard caretIndex < _textStorageRef.count else { return }
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
            _verticalSelectionBase = selectionRange.lowerBound
        }
        
        // 初回使用時に問題が出ないように。
        if _verticalSelectionBase == nil { _verticalSelectionBase = caretIndex }

        // 基準インデックス決定（A/Bパターンに基づく）
        let indexForLineSearch: Int = (selectionRange.lowerBound < _verticalSelectionBase!) ? selectionRange.lowerBound : selectionRange.upperBound

        // 基準行情報取得
        let info = _layoutManager.line(at: indexForLineSearch)
        guard let currentLine = info.line else { print("\(#function): currentLine is nil.");  return }

        let newLineIndex = info.lineIndex + direction.rawValue
        
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
        if newLineIndex >= _layoutManager.lines.count {
            if extendSelection {
                selectionRange = selectionRange.lowerBound..<_textStorageRef.count
            } else {
                caretIndex = _textStorageRef.count
            }
            updateCaretPosition()
            return
        }
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else { print("\(#function); makeLayoutRects error"); return }
        guard let newLineInfo = _layoutManager.lines[newLineIndex] else { log("newLineInfo is nil.", from:self); return }
        guard let ctLine = newLineInfo.ctLine else { print("\(#function): newLineInfo.ctLine nil"); return}

        // 初回のみ verticalCaretX をセット
        if isVerticalAction && !wasVerticalAction {
            guard let currentCtLine = currentLine.ctLine else { print("\(#function): currentLine.ctLine nil"); return}
            let indexInLine = caretIndex - currentLine.range.lowerBound
            _verticalCaretX = CTLineGetOffsetForStringIndex(currentCtLine, indexInLine, nil) + layoutRects.horizontalInsets
        }

        // 行末補正
        // 次の行のテキストの横幅より右にキャレットが移動する場合、キャレットはテキストの右端へ。
        let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let adjustedX = min(_verticalCaretX! - layoutRects.horizontalInsets, lineWidth)
        let targetIndexInLine = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: adjustedX, y: 0))
        
        // CTLineGetStringIndexForPositionは空行の場合に-1を返すため、その場合のindexは0にする。
        let newCaretIndex = newLineInfo.range.lowerBound + (targetIndexInLine < 0 ? 0 : targetIndexInLine)

        // 選択範囲更新（verticalSelectionBaseは常に基準点として使用）
        if extendSelection {
            let lower = min(_verticalSelectionBase!, newCaretIndex)
            let upper = max(_verticalSelectionBase!, newCaretIndex)
            selectionRange = lower..<upper
            
            
        } else {
            selectionRange = newCaretIndex..<newCaretIndex
        }
        
        updateCaretPosition()
    }
    
    // MARK: - Text Editing
    
    override func insertNewline(_ sender: Any?) {
        
        var spaces:[Character] = ["\n"]
        
        if _autoIndent && selectionRange.lowerBound != 0 {
            var range = 0..<0
            for i in (0..<selectionRange.lowerBound - 1).reversed() {
                if i == 0 {
                    range = 0..<selectionRange.lowerBound
                } else if _textStorageRef[i] == "\n" {
                    range = (i + 1)..<selectionRange.lowerBound
                    break
                }
            }
            
            for i in range {
                if let c = _textStorageRef[i] {
                    if !" \t".contains(c) { break }
                    spaces.append(c)
                }
            }
        }
        
        _textStorageRef.replaceString(in: selectionRange, with: String(spaces))
    }
    
    override func insertTab(_ sender: Any?) {
        _textStorageRef.replaceString(in: selectionRange, with: "\t")
    }
    
    // MARK: - COPY and Paste (NSResponder method)
    
    @IBAction func cut(_ sender: Any?) {
        copy(sender)

        _textStorageRef.replaceCharacters(in: selectionRange, with: [])
        
    }
    
    @IBAction func copy(_ sender: Any?) {
        guard !selectionRange.isEmpty else { return }
        guard let slicedCharacters = _textStorageRef[selectionRange] else { return }
        let selectedText = String(slicedCharacters)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    @IBAction func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let string = pasteboard.string(forType: .string) else { return }

        _textStorageRef.replaceCharacters(in: selectionRange, with: Array(string))
        
    }

    @IBAction override func selectAll(_ sender: Any?) {
        selectionRange = 0..<_textStorageRef.count
        
    }



    // MARK: - Deletion (NSResponder methods)

    override func deleteBackward(_ sender: Any?) {
        guard caretIndex > 0 else { return }

        if !selectionRange.isEmpty {
            _textStorageRef.replaceCharacters(in: selectionRange, with: [])
        } else {
            _textStorageRef.replaceCharacters(in: caretIndex - 1..<caretIndex, with: [])
        }

        _verticalCaretX = nil
    }
    
    // 前回のアクションのセレクタを保存するために実装
    override func doCommand(by selector: Selector) {
        _currentActionSelector = selector
        super.doCommand(by: selector)
        //print(selector)
    }

    // MARK: - Mouse Interaction (NSView methods)
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        
        //キャレット移動のセレクタ記録に残すためのダミーセレクタ。
        doCommand(by: #selector(clearCaretContext(_:)))
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        // 日本語入力中の場合はクリックに対応して変換を確定する。
        if hasMarkedText() {
            _textStorageRef.replaceString(in: selectionRange, with: markedText.string)
            inputContext?.discardMarkedText()
            unmarkText()
            return
        }
        
        let location = convert(event.locationInWindow, from: nil)
        
        
        switch layoutRects.regionType(for: location, layoutManagerRef: _layoutManager, textStorageRef: _textStorageRef){
        case .text(let index):
            _latestClickedCharacterIndex = index
            _singleClickPending = false
            
            switch event.clickCount {
            case 1: // シングルクリック - クリック位置にキャレットを移動。
                _horizontalSelectionBase = selectionRange.lowerBound
                _mouseSelectionMode = .character
                
                // 選択領域がありその領域をクリックしている場合、テキストのドラッグ開始とみなす。
                if !selectionRange.isEmpty, selectionRange.contains(index) {
                    _prepareDraggingText = true
                    _dragStartPoint = location
                    _singleClickPending = true
                    return
                }
                
                // シフトキーを押しながらシングルクリックすると、現在の選択領域からクリックした文字まで選択領域を拡大する。
                let flags = event.modifierFlags
                if flags.contains(.shift) {
                    let lower = min(index, selectionRange.lowerBound)
                    let upper = max(index, selectionRange.upperBound)
                    selectionRange = lower..<upper
                    return
                }
                
                caretIndex = index
                
            case 2: // ダブルクリック - クリックした部分を単語選択。
                if let wordRange = _textStorageRef.wordRange(at: index) {
                    selectionRange = wordRange
                } else {
                    caretIndex = index
                }
                _horizontalSelectionBase = selectionRange.lowerBound
                _mouseSelectionMode = .word
            case 3: // トリプルクリック - クリックした部分の行全体を選択。
                guard let hardLineRange = _textStorageRef.lineRange(at: index) else { log("lineRange is nil", from:self); return }
                let isLastLine = hardLineRange.upperBound == _textStorageRef.count
                selectionRange = hardLineRange.lowerBound..<hardLineRange.upperBound + (isLastLine ? 0 : 1)
                
                _horizontalSelectionBase = selectionRange.lowerBound
                _mouseSelectionMode = .line
            default:
                break
            }
        case .lineNumber(let line):
            
            guard let line = _layoutManager.lines[line] else { log("line is nil", from:self); return }
            //selectionRange = lineInfo.range
            guard let hardLineRange = _textStorageRef.lineRange(at: line.range.lowerBound) else { log("lineRange is nil", from:self); return }
            let isLastLine = hardLineRange.upperBound == _textStorageRef.count
            selectionRange = hardLineRange.lowerBound..<hardLineRange.upperBound + (isLastLine ? 0 : 1)
            _horizontalSelectionBase = hardLineRange.lowerBound
            
            //_horizontalSelectionBase = lineInfo.range.lowerBound
        case .outside:
            break
        }

        updateCaretPosition()
        scrollCaretToVisible()
        
    }
    
    override func mouseUp(with event: NSEvent) {
        
        // マウスボタンがアップされたら選択モードを.characterに戻す。
        _mouseSelectionMode = .character
        
        // mouseDown()の際に選択領域の内部をシングルクリックした後、ドラッグ&ドロップが発生せずにmouseUp()した場合の処理。
        // 単純なシングルクリックの動作をするだけだが、普通のシングルクリックはmouseDown()時に確定するが、こちらはmouseUp()時に確定する。
        // _latestClickedCharacterIndexを参照させたいところだが、draggingSesson()でtermnateが呼ばれるため、参照しにくい。
        // 仕方なくlayoutRectを利用して現在のマウス位置からクリック位置を推測している。
        if _singleClickPending {
            let location = convert(event.locationInWindow, from: nil)
            if let layoutRect = _layoutManager.makeLayoutRects() {
                switch layoutRect.regionType(for: location, layoutManagerRef: _layoutManager, textStorageRef: _textStorageRef) {
                case .text(let index):
                    caretIndex = index
                    //log("text: \(index)", from:self)
                case .lineNumber(let line):
                    log("lineNumber: \(line)", from:self)
                case .outside:
                    log("outside: ", from:self)
                }
            }
        }
        
        // マウスドラッグによる域外選択の際のオートスクロールに関するプロパティを初期化する。
        terminateDraggingOperation()

    }
    

    
    
    override func mouseDragged(with event: NSEvent) {
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        //キャレット移動のセレクタ記録に残すためのダミーセレクタ。
        doCommand(by: #selector(clearCaretContext(_:)))
        
        
        let location = convert(event.locationInWindow, from: nil)
        
        // オートスクロール用のタイマー設定
        if _dragTimer == nil {
            _dragTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateDraggingSelection()
            }
        }
        
        // テキストのドラッグ中の場合、draggingSessionを開始する。
        if _prepareDraggingText, let dragStartPoint = _dragStartPoint {
            let dragDistance: CGFloat = hypot(location.x - dragStartPoint.x, location.y - dragStartPoint.y)
            if dragDistance >= _minimumDragDistance {
                let str = String(_textStorageRef.characterSlice[selectionRange])
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(str, forType: .string)
                
                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
                let imageSize = NSSize(width: 120, height: 30)
                let image = NSImage(size: imageSize)
                let imageOrigin = CGPoint(x: location.x - imageSize.width / 2, y: location.y - imageSize.height / 2)
                
                // とりあえずの処置として、draggingItemには赤い矩形を設定しておく。
                image.lockFocus()
                NSColor.red.set()
                NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
                image.unlockFocus()
                
                draggingItem.setDraggingFrame(NSRect(origin: imageOrigin, size: image.size), contents: image)
                log("DRAGGING.", from:self)
                beginDraggingSession(with: [draggingItem], event: event, source: self)
                _singleClickPending = false
            }
            return
        }
        
        switch layoutRects.regionType(for: location, layoutManagerRef: _layoutManager, textStorageRef: _textStorageRef){
        case .text(let index):
            guard let anchor = _latestClickedCharacterIndex else { log("_latestClickedCharacterIndex is nil", from:self); return }
            
            switch _mouseSelectionMode {
            case .character:
                selectionRange = min(anchor, index)..<max(anchor, index)
            case .word:
                if let wordRange1 = _textStorageRef.wordRange(at: index),
                   let wordRange2 = _textStorageRef.wordRange(at: anchor) {
                    selectionRange = min(wordRange1.lowerBound, wordRange2.lowerBound)..<max(wordRange1.upperBound, wordRange2.upperBound)
                }
            case .line:
                if let lineRangeForIndex = _textStorageRef.lineRange(at: index),
                   let lineRangeForAnchor = _textStorageRef.lineRange(at: anchor) {
                    let lower = min(lineRangeForIndex.lowerBound, lineRangeForAnchor.lowerBound)
                    let upper = max(lineRangeForIndex.upperBound, lineRangeForAnchor.upperBound)
                    let isLastLine = (_textStorageRef.count == upper)
                    selectionRange = lower..<(isLastLine ? upper : upper + 1)
                }
            }
            
            // スクロールがcaretの位置で行なわれるため上方向の領域拡大で上スクロールが生じないためコードを追加する。
            if index < anchor {
                guard let scrollView = self.enclosingScrollView else { return }
                let point = characterPosition(at: index)
                DispatchQueue.main.async {
                    scrollView.contentView.scrollToVisible(NSRect(x:point.x, y:point.y, width: 1, height: 1))
                }
                //log("selectionRange: \(selectionRange)", from:self)
                //updateCaretPosition()
                return
            }
            
            
        case .lineNumber(let lineNumber):
            //現在の選択範囲から、指定れた行の最後(改行含む)までを選択する。
            //horizontalSelectionBaseより前であれば、行頭までを選択する。
            guard let line = _layoutManager.lines[lineNumber] else { log(".lineNumber. line = nil.", from:self); return }
            let lineRange = line.range
            let base = _horizontalSelectionBase ?? caretIndex
            if lineRange.upperBound > base {
                selectionRange = base..<lineRange.upperBound
            } else {
                selectionRange = lineRange.lowerBound..<base
            }
            
        case .outside:
            // textRegionより上なら文頭まで、下なら文末まで選択する。
            let textRect = layoutRects.textRegion.rect
            
            log(".outside", from:self)
            
            if location.y < textRect.minY {
                //selectionRange = 0..<(_horizontalSelectionBase ?? caretIndex)
                selectionRange = 0..<selectionRange.upperBound
            } else if location.y > (_layoutManager.lineHeight * CGFloat(_layoutManager.lineCount) + layoutRects.textEdgeInsets.top)  {
                selectionRange = (_horizontalSelectionBase ?? caretIndex)..<_textStorageRef.count
            }
            return
        }
        
        _ = self.autoscroll(with: event)

        updateCaretPosition()
        scrollCaretToVisible()
    }
    
    // MARK: - DraggingSource methods
    
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return [.copy, .move]
        case .outsideApplication:
            return [.copy]
        @unknown default:
            return []
        }
    }
    
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        log("Dragging session ended", from: self)

        terminateDraggingOperation()
        updateCaretPosition()
    }
    
    // MARK: - DraggingDestination methods
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSString.self], options: nil) {
            return .copy
        }
        return []
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let items = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String],
              let droppedString = items.first else {
            log("items is nil", from: self)
            return false
        }

        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let layoutRects = _layoutManager.makeLayoutRects() else { log("layoutRects is nil", from: self); return false }
        
        switch layoutRects.regionType(for: locationInView, layoutManagerRef: _layoutManager, textStorageRef: _textStorageRef) {
        case .text(let index):
            let isSenderMyself = sender.draggingSource as AnyObject? === self
            let isOptionKeyPressed = NSEvent.modifierFlags.contains(.option)
            
            // 自身のdrag and dropで現在の選択範囲内部をポイントした場合は無効。
            if isSenderMyself && selectionRange.contains(index) { return false }
            
            if isOptionKeyPressed || !isSenderMyself { // .copy  オプションキーが押下されているか外部からのdrag and drop.
                //log(".copy: ", from: self)
                _textStorageRef.replaceCharacters(in: index..<index, with: Array(droppedString))
                selectionRange = index..<index + droppedString.count
            } else  { // .move
                if isSenderMyself { // 自分自身からのdrag and drop
                    if index < selectionRange.lowerBound {
                        _textStorageRef.replaceCharacters(in: selectionRange, with: Array(""))
                        _textStorageRef.replaceCharacters(in: index..<index, with: Array(droppedString))
                        selectionRange = index..<index + droppedString.count
                    } else {
                        let selectionLengh = selectionRange.upperBound - selectionRange.lowerBound
                        _textStorageRef.replaceCharacters(in: selectionRange, with: Array(""))
                        _textStorageRef.replaceCharacters(in: index - selectionLengh..<index - selectionLengh, with: Array(droppedString))
                        selectionRange = index - selectionLengh..<index - selectionLengh + droppedString.count
                    }
                }
            }
            return true
        default:
            return false
        }
    }
    
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let draggingLocationInWindow = sender.draggingLocation
        let locationInView = convert(draggingLocationInWindow, from: nil)
        
        let isOptionKeyPressed = NSEvent.modifierFlags.contains(.option)
        let isSenderMyself = sender.draggingSource as AnyObject? === self
        let dragOperation: NSDragOperation = isSenderMyself ?  (isOptionKeyPressed ? .copy : .move) : .copy
        //log("dragOperation: \(dragOperation), isSenderMyself: \(isSenderMyself)", from: self)

        // 該当位置の文字インデックスを取得
        guard let layoutRects = _layoutManager.makeLayoutRects() else { log("layoutRects is nil", from: self); return []}
        switch layoutRects.regionType(for: locationInView, layoutManagerRef: _layoutManager, textStorageRef: _textStorageRef) {
        case .text(let index):
            // キャレットを一時的に移動（選択範囲は変更しない）
            moveDropCaret(to: index)
            return dragOperation

        default:
            // テキスト領域外の場合はキャレットを非表示にしてコピーを拒否
            hideDropCaret()
            return []
        }
    }
    
    // ドロップ用のキャレット位置へ移動（通常の updateCaretPosition を使わない）
    private func moveDropCaret(to index: Int) {
        let point = characterPosition(at: index)
        _caretView.updateFrame(x: point.x, y: point.y, height: _layoutManager.lineHeight)
        _caretView.isHidden = false
        
        guard let scrollView = self.enclosingScrollView else { return }
        DispatchQueue.main.async {
            scrollView.contentView.scrollToVisible(NSRect(x:point.x, y:point.y, width: 1, height: 1))
        }
    }

    // ドロップ候補がなくなった場合にキャレットを非表示に
    private func hideDropCaret() {
        _caretView.isHidden = true
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
        return _markedTextRange != nil
    }

    func markedRange() -> NSRange {
        guard let range = _markedTextRange else {
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
        
        let range = Range(replacementRange) ?? selectionRange
        
        //_textStorageRef.replaceCharacters(in: range, with: Array(text))
        
        // 渡されたstringをCharacter.isControlでフィルターして制御文字を除去しておく。
        _textStorageRef.replaceCharacters(in: range, with: text.filter { !$0.isControl })
       
        _markedTextRange = nil
        _markedText = NSAttributedString()
        
    }
    
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        
        let attrString: NSAttributedString
        if let str = string as? String {
            attrString = NSAttributedString(string: str)
            //print("setMarkedText: as? String")
        } else if let aStr = string as? NSAttributedString {
            attrString = aStr
            //print("setMarkedText: as? NSAttributedString")
        } else {
            return
        }
        
        // selectedRangeは「挿入される文字列のどこが選択されているか」、replacementRangeは「どこに挿入するか」を示す。
        
        // 選択範囲がある場合は、その部分を削除しておく。
        if selectionRange.count > 0 {
            _textStorageRef.replaceCharacters(in: selectionRange, with: [])
            selectionRange = selectionRange.lowerBound..<selectionRange.lowerBound
        }
        
        // もし文字列が空の場合は変換が終了したとみなしてunmarkText()を呼び出す。
        // OS標準のIMとAquaSKKを試したがいずれも変換終了時にunmarkedText()を呼び出さないことを確認。2025-07-10
        if attrString.string.count == 0 {
            unmarkText()
            return
        }
        
        let range = Range(replacementRange) ?? selectionRange
        let plain = attrString.string
        _markedTextRange = range.lowerBound..<(range.lowerBound + plain.count)
        _markedText = attrString
        _replacementRange = range
        
        _caretView.isHidden = true
        
        needsDisplay = true
        
    }
    
    func unmarkText() {
        _markedTextRange = nil
        _markedText = NSAttributedString()
        
        _caretView.isHidden = false
        
        needsDisplay = true
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let swiftRange = Range(range),
              swiftRange.upperBound <= _textStorageRef.count,
              let chars = _textStorageRef[swiftRange] else {
            return nil
        }

        actualRange?.pointee = range
        return NSAttributedString(string: String(chars))
    }

    func characterIndex(for point: NSPoint) -> Int {
        caretIndex // 仮実装（後でマウス位置計算を追加）
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var point = characterPosition(at: caretIndex)
        point = CGPoint(x: point.x, y: point.y + _layoutManager.lineHeight)
        point = self.convert(point, from: nil)
        
        guard let window = self.window else { print("\(#function): window is nil"); return .zero }
        
        point = window.convertPoint(toScreen: point)
        
        return NSRect(x: point.x, y: point.y, width: 1, height: _layoutManager.lineHeight)
        
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
        _caretView.isHidden = !isActive
        needsDisplay = true
    }
    
    
    // 現在のところinternalとしているが、将来的に公開レベルを変更する可能性あり。
    func updateFrameSizeToFitContent() {
        let totalLines = _layoutManager.lines.count
        let lineHeight = _layoutManager.lineHeight

        let showLineNumber = true
        let lineNumberWidth: CGFloat = showLineNumber ? 40 : 0

        let height = CGFloat(totalLines) * lineHeight * 4 / 3
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): makeLayoutRects failed.")
            return
        }
        let width = _layoutManager.maxLineWidth
                    + lineNumberWidth
                    + layoutRects.textEdgeInsets.left * 2
        
        self.setFrameSize(CGSize(width: width, height: height))

        enclosingScrollView?.contentView.needsLayout = true
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
        enclosingScrollView?.tile()

    }
    
    
    // characterIndex文字目の文字が含まれる行の位置。textRegion左上原点。
    private func linePosition(at characterIndex:Int) -> CGPoint {
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): failed to make layoutRects"); return .zero }
        let lineInfo = _layoutManager.line(at: characterIndex)
        /*guard let line = lineInfo.line else {
            print("\(#function): failed to make line"); return .zero }*/
                
        let x = layoutRects.textRegion.rect.origin.x + layoutRects.horizontalInsets
        let y = layoutRects.textRegion.rect.origin.y + CGFloat(lineInfo.lineIndex) * _layoutManager.lineHeight + layoutRects.textEdgeInsets.top
        return CGPoint(x: x, y: y)
    }
    
    // characterIndex文字目の文字の位置。textRegion左上原点。
    private func characterPosition(at characterIndex:Int) -> CGPoint {
        let lineInfo = _layoutManager.line(at: characterIndex)
        guard let line = lineInfo.line else {
            print("\(#function): failed to make line"); return .zero }
        
        let linePoint = linePosition(at: characterIndex)
        
        let indexInLine = characterIndex - line.range.lowerBound
        
        return CGPoint(x: linePoint.x + line.characterOffset(at: indexInLine), y: linePoint.y)

    }
    
    private func drawCTLine(ctLine: CTLine, x: CGFloat, y: CGFloat) {
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.translateBy(x: 0, y: bounds.height)
        context?.scaleBy(x: 1.0, y: -1.0)
        
        let ascent = CTFontGetAscent(_textStorageRef.baseFont)
        let lineOriginY = bounds.height - y - ascent
        
        context?.textPosition = CGPoint(x: x, y: lineOriginY)
        CTLineDraw(ctLine, context!)
        context?.restoreGState()
    }
    
    // オートスクロール用のメソッド。タイマーから呼び出される。
    private func updateDraggingSelection() {
        guard let window = self.window else { log("updateDraggingSelection: self or window is nil", from:self); return }
        
        // 現在のマウスポインタの位置を取得
        let location = window.mouseLocationOutsideOfEventStream
        
        guard let contentView = self.enclosingScrollView?.contentView else { log("contentView is nil", from:self); return }
        let locationInClipView = contentView.convert(location, from: nil)
        if  contentView.bounds.contains(locationInClipView) {
            // テキストが見えている場所にマウスポインタがある場合はなにもせず待機。
            return
        }
        
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: location,
                                       modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 0)
        
        if let event = event {
            self.mouseDragged(with: event)
        }
    }
    
    private func terminateDraggingOperation() {
        _dragTimer?.invalidate()
        _dragTimer = nil
        _latestClickedCharacterIndex = nil
        _dragStartPoint = nil
        _prepareDraggingText = false
        //log("done.",from:self)
    }
    
    // mouseDown()などのセレクター履歴を残すためのダミー。
    @objc func clearCaretContext(_ sender: Any?) { }
    
}

