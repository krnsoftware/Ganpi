//
//  KTextView.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/06/08.
//

import Cocoa

final class KTextView: NSView, NSTextInputClient, NSDraggingSource {
    
    // MARK: - Struct and Enum
    /*
    private enum KTextEditDirection : Int {
        case forward = 1
        case backward = -1
    }*/
    
    private enum KMouseSelectionMode {
        case character
        case word
        case line
    }
    
    // MARK: - Properties
    // 外部インスタンスの参照
    private var _textStorageRef: KTextStorageProtocol// = KTextStorage()
    private var _layoutManager: KLayoutManager
    private let _caretView = KCaretView()
    private var _containerView: KTextViewContainerView?
    
    // 選択範囲
    private var _selectionRange: Range<Int> = 0..<0
    
    // キャレットの表示に関するプロパティ
    private var _caretBlinkTimer: Timer?
    
    // フォーカスリングの表示に関するプロパティ
    private weak var _owningContainer: KTextViewContainerView?
    
    // 前回のcontentview.boundsを記録しておくためのプロパティ
    private var _prevContentViewBounds: CGRect = .zero
    
    // キャレットの動作に関するプロパティ
    private var _caretIndex: Int
    private var _verticalCaretX: CGFloat?        // 縦方向にキャレットを移動する際の基準X。
    private var _verticalSelectionBase: Int?     // 縦方向に選択範囲を拡縮する際の基準点。
    private var _horizontalSelectionBase: Int?   // 横方向に選択範囲を拡縮する際の基準点。
    private var _lastActionSelector: Selector?   // 前回受け取ったセレクタ。
    private var _currentActionSelector: Selector? { // 今回受け取ったセレクタ。
        willSet { _lastActionSelector = _currentActionSelector }
    }
    // キャレット位置に於ける現在の行。
    private var _currentLineIndex: Int?
        
    // yank関連
    private var _yankSelection: Range<Int>?
    private var _isApplyingYank: Bool = false
    
    // Delete Buffer関連
    private var _selectionBuffer: Range<Int>? // Action control only.
    
    // Edit mode.
    private var _editMode: KEditMode = .normal
    
    // completion.
    private lazy var _completion: KCompletionController = .init(textView: self)
    
    // 簡易マーク
    private var _markedCaretIndex: Int?
    
    // スクロール関連
    private var _isSmoothScrollEnabled = true
    
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
    private var _showInvisibleCharacters: Bool = true
    private var _autoIndent: Bool = true
    private var _wordWrap: Bool = true
    private var _useStandardKeyAssign: Bool = false
    
    // live resize 時に大きな文書のレイアウト更新を止めるためのプロパティ
    private var _prevContentViewWidthForLayout: CGFloat = 0.0
    private let _liveResizeFreezeThreshold: Int = 100_000

    private var _isFrozenDuringLiveResize: Bool {
        // _liveResizeFreezeThreshold文字以上のときだけ live resize 中のレイアウト更新を止める
        inLiveResize && (_textStorageRef.count >= _liveResizeFreezeThreshold)
    }

    
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
    private var _selectedRangeInMarkedText = NSRange(location: 0, length: 0)
    var replacementRange: Range<Int>? { get { _replacementRange } }
    
    
    // MARK: - Computed variables
    
    
    var selectionRange: Range<Int> {
        get { _selectionRange }
        set {
            _selectionRange = newValue
            
            endYankCycle()
            
            if completion.isInCompletionMode {
                completion.update()
            }
            
            _ = currentLineIndex

            updateCaretPosition()
            sendStatusBarUpdateAction()
            updateCaretActiveStatus()
            
            needsDisplay = true
        }
    }
    
    private var currentLineIndex: Int {
        let lines = layoutManager.lines
        
        // 現在の行が存在しており、その左端・右端にキャレットがある場合、現在の行のインデックスはそのままにする。
        if let currentLineIndex = _currentLineIndex,
            currentLineIndex < lines.count,
            let currentLine = lines[currentLineIndex],
            (currentLine.range.upperBound == caretIndex || currentLine.range.lowerBound == caretIndex) {
            return currentLineIndex
        }
        // そうでなければ新規に計算する。
        let newLineInfo = lines.lineInfo(at: caretIndex)
        let newLineIndex = newLineInfo.lineIndex < 0 ? 0 : newLineInfo.lineIndex
        _currentLineIndex = newLineIndex
                
        return newLineIndex
    }
    
    
    var caretIndex: Int {
        get { selectionRange.upperBound }
        set { selectionRange = newValue..<newValue }
    }
    
    
    // 読み取り専用として公開
    var textStorage: KTextStorageProtocol {//KTextStorageReadable {
        return _textStorageRef
    }
    
    var layoutManager: KLayoutManager {
        return _layoutManager
    }
    
    var editMode: KEditMode {
        get { _editMode }
        set {
            _editMode = newValue
            sendStatusBarUpdateAction()
        }
    }
    
    var completion: KCompletionController {
        _completion
    }
    
    var selectionBuffer: Range<Int>? { _selectionBuffer }
    
    var wordWrap: Bool {
        get { _wordWrap }
        set {
            _wordWrap = newValue
            applyWordWrapToEnclosingScrollView()
            
            _layoutManager.rebuildLayout()
            updateFrameSizeToFitContent()
            updateCaretPosition()
            centerSelectionInVisibleArea(self)
            needsDisplay = true
        }
    }
    
    var autoIndent: Bool {
        get { _autoIndent }
        set { _autoIndent = newValue }
    }
    
    var showLineNumbers: Bool {
        get { _showLineNumbers }
        set {
            _showLineNumbers = newValue
            _layoutManager.rebuildLayout()
            updateFrameSizeToFitContent()
            updateCaretPosition()
            needsDisplay = true
        }
    }
    
    var showInvisibleCharacters: Bool {
        get { _showInvisibleCharacters }
        set {
            _showInvisibleCharacters = newValue
            _layoutManager.rebuildLayout()
            updateFrameSizeToFitContent()
            updateCaretPosition()
            needsDisplay = true
        }
    }
    
    var markedCaretIndex:Int? {
        get { _markedCaretIndex }
        set { _markedCaretIndex = newValue }
    }
    
    
    var containerView: KTextViewContainerView? {
        get { _containerView }
        set { _containerView = newValue}
    }
    
    // 今回のセレクタが垂直方向にキャレット選択範囲を動かすものであるか返す。
    private var isVerticalAction: Bool {
        guard let sel = _currentActionSelector else { return false }
        return sel.isVerticalAction
    }
    
    // 前回のセレクタが垂直方向にキャレット・選択範囲を動かすものだったか返す。
    private var wasVerticalAction: Bool {
        guard let sel = _lastActionSelector else { return false }
        return sel.isVerticalAction
    }
    
    // 前回のセレクタが垂直方向の選択範囲を動かすものだったか返す。
    private var wasVerticalActionWithModifySelection: Bool {
        guard let sel = _lastActionSelector else { return false }
        return sel.isVerticalActionWithModifierSelection
    }
    
    // 前回のセレクタが水平方向に選択範囲を動かすものだったか返す。
    private var wasHorizontalActionWithModifySelection: Bool {
        guard let sel = _lastActionSelector else { log("#01"); return false }
        return sel.isHorizontalActionWithModifierSelection
    }
    
    // 今回のセレクタがYankに属するものか返す。
    private var isYankFamilyAction: Bool {
        guard let sel = _currentActionSelector else { return false }
        return sel.isYankFamilyAction
    }
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { return true } // for IME testing. then remove.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    
    
    // MARK: - Initialization (KTextView methods)
    
    // Designated Initializer #1（既定: 新規生成）
    override init(frame: NSRect) {
        let storage:KTextStorageProtocol = KTextStorage()
        _caretIndex = 0
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
        _caretIndex = 0
        super.init(frame: frame)
        
        //log("_textStorageRef.count: \(_textStorageRef.count)")
        
        commonInit()
    }
    
    // Designated Initializer #3（完全注入: 将来用）
    init(frame: NSRect, textStorageRef: KTextStorageProtocol, layoutManager: KLayoutManager) {
        self._textStorageRef = textStorageRef
        self._layoutManager = layoutManager
        _caretIndex = 0
        super.init(frame: frame)
        commonInit()
    }
    
    // Interface Builder用
    required init?(coder: NSCoder) {
        let storage = KTextStorage()
        self._textStorageRef = storage
        self._layoutManager = KLayoutManager(textStorageRef: storage)
        _caretIndex = 0
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        addSubview(_caretView)
        wantsLayer = true
        
        _layoutManager.textView = self
        
        registerForDraggedTypes([.string, .fileURL])
    }
    
    func loadPreferences() {
        let prefs = KPreference.shared
        let lang = textStorage.parser.type
        
        _wordWrap = prefs.bool(.parserWordWrap, lang: lang)
        _showInvisibleCharacters = prefs.bool(.parserShowInvisibles, lang: lang)
        
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        // scrollviewのscrollerの状態をセット
        DispatchQueue.main.async { [weak self] in
            self?.applyWordWrapToEnclosingScrollView()
        }
                
        window?.makeFirstResponder(self)
        
        // キャレットの位置を再計算して表示しておく。
        updateCaretPosition()
        startCaretBlinkTimer()
        
        
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
    
    private var _needsInitialReload = true
    
    override func viewWillDraw() {
        super.viewWillDraw()

        // 最初の読み込み時にlayoutを1回やりなおす。
        // 短かい文章だけのviewをsplitする際に行の横幅が極端に短かくなる問題を解決。
        if _needsInitialReload {
            layoutManager.rebuildLayout()
            
            // frameのサイズは正しいがhitTestに反応しない不具合を回避するため、frameのサイズを再設定する。
            frame.size = NSSize(width: frame.size.width,height: frame.size.height)

            // 初回の比較基準をここで確定させる。
            if let contentBounds = enclosingScrollView?.contentView.bounds {
                
                _prevContentViewBounds = contentBounds
                _prevContentViewWidthForLayout = contentBounds.width
            }

            _needsInitialReload = false
        }

        // ソフトラップの場合、visibleRectに合わせて行の横幅を変更する必要があるが、
        // scrollview.clipViewでの変更がないため通知含めvisibleRectの変更を知るすべがない。
        // このため、viewWillDraw()でdraw()される直前に毎回チェックを行なうことにした。
        guard let currentContentViewWidth = enclosingScrollView?.contentView.bounds.width
        else { log("enclosingScrollVie: nil", from: self); return }

        // 10万文字以上のときは live resize 中のレイアウト更新を完全に止める。
        // 旧レイアウトのまま描画を継続し、終了時にまとめて1回更新する。
        if _isFrozenDuringLiveResize {
            return
        }

        if currentContentViewWidth != _prevContentViewWidthForLayout {
            _prevContentViewWidthForLayout = currentContentViewWidth
            _layoutManager.textViewFrameInvalidated()
            updateFrameSizeToFitContent()
            updateCaretPosition()
        }
    }

    
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()

        // large document のときだけ、終了時にまとめて1回だけ更新する
        guard _textStorageRef.count >= _liveResizeFreezeThreshold else { return }
        guard let contentBounds = enclosingScrollView?.contentView.bounds else { return }

        _prevContentViewWidthForLayout = contentBounds.width
        _layoutManager.textViewFrameInvalidated()
        updateFrameSizeToFitContent()
        updateCaretPosition()
        needsDisplay = true
    }

    
    
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        containerView?.setActiveEditor(true)
        
        _haskeyBoardFocus = true
        sendStatusBarUpdateAction()
        updateCaretActiveStatus()
        return accepted
    }
    
    override func resignFirstResponder() -> Bool {
        //print("\(#function)")
        let accepted = super.resignFirstResponder()
        endYankCycle()
        containerView?.setActiveEditor(false)
        
        _haskeyBoardFocus = false
        updateCaretActiveStatus()
        return accepted
    }
    
    //test.
    // window?.firstResopnder === self はresignFirstResponder()の関数内ではtrueのため、
    // 同関数がfalseを返す可能性は無視して同関数が呼ばれた時点でfocusが外れたとみなす。
    private var _haskeyBoardFocus :Bool = false
    
    func updateCaretActiveStatus() {
        let shouldShow = (window?.isKeyWindow == true) &&
                //window?.firstResponder === self &&
                _haskeyBoardFocus &&
                selectionRange.isEmpty

        if shouldShow {
            _caretView.isHidden = false
            _caretView.alphaValue = 1.0
            restartCaretBlinkTimer()
        } else {
            _caretView.isHidden = true
        }
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        // 意味不明のため一度comment out.
        //let width = frame.size.width
        //frame.size = NSSize(width: width+10, height: frame.size.height)
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
        guard let layoutRects = layoutManager.makeLayoutRects() else { log("layoutRects is nil.", from:self); return }
        let caretPosition:CGPoint = layoutRects.characterPosition(lineIndex: currentLineIndex, characterIndex: caretIndex)
        
        _caretView.updateFrame(x: caretPosition.x, y: caretPosition.y, height: layoutManager.fontHeight)
        
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
    
    func scrollCaretToVisible() {
        scrollSelectionToVisible()
    }
    
    func scrollSelectionToVisible() {
        guard let scrollView = self.enclosingScrollView else { return }
        guard let layoutRects = layoutManager.makeLayoutRects() else { return }
        
        let startPosition = characterPosition(at: selectionRange.lowerBound)
        let endPosition = characterPosition(at: selectionRange.upperBound)
        // 選択範囲の上下1行分・左右に10ptだけ表示領域を増やす。
        // 行番号表示の横幅分だけ左のinsetを増やしておく。
        let rect = CGRect(
            x: min(startPosition.x, endPosition.x) - 10.0 - layoutRects.horizontalInsets,
            y: min(startPosition.y, endPosition.y) - layoutManager.lineHeight,
            width: abs(endPosition.x - startPosition.x) + 30.0 + layoutRects.horizontalInsets,
            height: abs(endPosition.y - startPosition.y) + 3 * layoutManager.lineHeight
        )
        DispatchQueue.main.async {
            scrollView.contentView.scrollToVisible(rect)
        }
        
    }
    
    // MARK: - Drawing (NSView methods)
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        let lines = _layoutManager.lines
        let lineHeight = _layoutManager.lineHeight
        let textRect = layoutRects.textRegion.rect
        
        // 行が見える範囲にあるかどうか確認するためのRange。
        // if verticalRange.contains(textPoint.y) のようにして使う。
        let verticalRange = (visibleRect.minY - lineHeight)..<visibleRect.maxY
        
        /*
        // 見える範囲だけを走査するようにしてみたが、10万行で1msの差も出ないため外した。
        let visibleLowerBound = max(0, Int((verticalRange.lowerBound - layoutRects.textEdgeInsets.top) / lineHeight))
        let visibleUpperBound = min(lines.count, Int((verticalRange.upperBound - layoutRects.textEdgeInsets.top) / lineHeight))
        let visibleLineRange = visibleLowerBound..<visibleUpperBound
        //log("visibleLineRange: \(visibleLineRange)")
        */
        
        let textBackgroundColor = textStorage.parser.backgroundColor
        
        // 背景塗り潰し
        textBackgroundColor.setFill()
        bounds.fill()
        
        let selectedTextBGColor = window?.isKeyWindow == true
        ? NSColor.selectedTextBackgroundColor
        : NSColor.unemphasizedSelectedTextBackgroundColor
        
        
        for i in 0..<lines.count {
        //for i in visibleLineRange {
            guard let line = lines[i] else { log("line[i] is nil.", from:self); continue }
            let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
            
            if !verticalRange.contains(y) {
                continue
            }
            
            // 選択範囲の描画
            let lineRange = line.range
            let selection = selectionRange.clamped(to: lineRange)
            if selection.isEmpty && !lineRange.isEmpty && !selectionRange.contains(lineRange.upperBound){ continue }
            
            
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
                height: ceil(layoutManager.lineHeight)
            )
            selectedTextBGColor.setFill()
            selectionRect.fill()
            
            
        }
        
        // テキストを描画
        // IMの変換中文字列あれば、それをKLinesにFakeLineとして追加する。
        if hasMarkedText(), let repRange = _replacementRange{
            lines.addIMFakeLine(replacementRange: repRange, attrString: _markedText, selectedRangeInMarkedText: _selectedRangeInMarkedText)
        
        // 単語補完中であれば、それをKLinesにFakeLineとして追加する。
        } else if completion.isInCompletionMode, let attrString = completion.currentWordTail {
            lines.addCompletionFakeLine(replacementRange: caretIndex..<caretIndex, attrString: attrString)
        }

        for i in 0..<lines.count {
            let y = CGFloat(i) * lineHeight + layoutRects.textEdgeInsets.top
            
            let textPoint = CGPoint(x: textRect.origin.x + layoutRects.horizontalInsets ,
                                    y: textRect.origin.y + y)
            
            guard let line = lines[i] else { continue }
            
            if verticalRange.contains(textPoint.y) {
                line.draw(at: textPoint, in: bounds)
            }
        }
        
        lines.removeFakeLines()
        
        // 行番号部分を描画。
        if _showLineNumbers, let lnRect = layoutRects.lineNumberRegion?.rect {
            
            textBackgroundColor.setFill()
            
            let fadeWidth: CGFloat = 12.0
            
            // draw opaque area.
            let opaqueRect = NSRect(origin: lnRect.origin, size: NSSize(width: lnRect.width - fadeWidth, height: lnRect.height))
            opaqueRect.fill()
            
            // draw tranceparent area.
            let fadeRectOrigin = NSPoint(x: lnRect.origin.x + lnRect.width - fadeWidth, y: lnRect.origin.y)
            let fadeRectSize = NSSize(width: fadeWidth + layoutRects.textEdgeInsets.right, height: lnRect.height)
            let fadeRect =  NSRect(origin: fadeRectOrigin, size: fadeRectSize)
            let transparent = textBackgroundColor.withAlphaComponent(0.0)
            let gradient = NSGradient(colors: [textBackgroundColor, transparent])
            gradient?.draw(in: fadeRect, angle: 0)
            
            
            // 非選択行の文字のattribute
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textStorage.lineNumberFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            // 選択行の文字のattribute
            let attrs_emphasized: [NSAttributedString.Key: Any] = [
                .font: textStorage.lineNumberFontEmph,
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
                
                let numberPointX = lnRect.maxX - size.width - KLayoutRects.KLineNumberEdgeInsets.default.right
                // 上下がずれないよう、base lineを合わせる。
                let numberPointY = lnRect.origin.y + y - visibleRect.origin.y + textStorage.baseFont.ascender - textStorage.lineNumberFont.ascender
                let numberPoint = CGPoint(x: numberPointX, y: numberPointY)
                
                if !verticalRange.contains(numberPoint.y) { continue }
                
                let lineRange = textStorage.lineRange(at: line.range.lowerBound) ?? line.range
                let isActive =
                selectionRange.overlaps(lineRange)
                || (selectionRange.isEmpty && (
                    lineRange.contains(selectionRange.lowerBound)
                    || selectionRange.lowerBound == lineRange.upperBound
                ))
                || (!selectionRange.isEmpty &&
                    selectionRange.lowerBound <= lineRange.lowerBound &&
                    selectionRange.upperBound >= lineRange.upperBound)
                if  isActive {
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
        // 標準キーアサインを使用する場合
        if _useStandardKeyAssign {
            if inputContext?.handleEvent(event) == true { return }
            interpretKeyEvents([event])
            return
        }
        
        // Application専用キーアサインを使用する場合
        // IM変換中はそちらを優先
        if hasMarkedText() {
            completion.isInCompletionMode = false
            _ = inputContext?.handleEvent(event)
            return
        }
        
        // 補完機能に渡してキーが消費されるか確認。
        if completion.estimate(event: event) {
            needsDisplay = true
            return
        }
        
        // キーアサインに適合するかチェック。適合しなければinputContextに投げて、そちらでも使われなければkeyDown()へ。
        guard let keyStroke = KKeyStroke(event: event) else { log("#01"); return }
        let status = KKeyAssign.shared.estimateKeyStroke(keyStroke, requester: self, mode: _editMode)
        if status == .passthrough {
            if inputContext?.handleEvent(event) == true { return }
            nextResponder?.keyDown(with: event)
        }
        
        
    }
    
    
    // 前回のアクションのセレクタを保存するために実装
    override func doCommand(by selector: Selector) {
        _currentActionSelector = selector
        
        if !isYankFamilyAction {
            KClipBoardBuffer.shared.endCycle()
            _yankSelection = nil
        }
        
        if responds(to: selector){
            perform(selector, with: nil)
            return
        }
        
        // doCommandは親viewまでしかactionが届かない。
        // TextView内で消費しない場合、sendActionで投げ直してwindow/document/application delegateまで通す。
        NSApp.sendAction(selector, to: nil, from: self)
    }
    
    override func cancelOperation(_ sender:Any?) {
        // ctrl+.をpass throughするための空メソッド。
    }
    
    // MARK: - Mouse Interaction (NSView methods)
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        
        endYankCycle()
        
        //キャレット移動のセレクタ記録に残すためのダミーセレクタ。
        doCommand(by: #selector(clearCaretContext(_:)))
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            print("\(#function): layoutRects is nil")
            return
        }
        
        // 日本語入力中の場合はクリックに対応して変換を確定する。
        if hasMarkedText() {
            textStorage.replaceString(in: selectionRange, with: markedText.string)
            inputContext?.discardMarkedText()
            unmarkText()
            return
        }
        
        let location = convert(event.locationInWindow, from: nil)
        
        switch layoutRects.regionType(for: location){
        case .text(let index, let lineIndex):
            _latestClickedCharacterIndex = index
            _singleClickPending = false
            
            switch event.clickCount {
            case 1: // シングルクリック - クリック位置にキャレットを移動。
                //_horizontalSelectionBase = selectionRange.lowerBound
                _horizontalSelectionBase = index
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
                
                _currentLineIndex = lineIndex
                caretIndex = index
                
            case 2: // ダブルクリック - クリックした部分を単語選択。
                if let wordRange = textStorage.wordRange(at: index) {
                    selectionRange = wordRange
                } else {
                    caretIndex = index
                }
                _horizontalSelectionBase = selectionRange.lowerBound
                _mouseSelectionMode = .word
                
            case 3: // トリプルクリック - クリックした部分の行全体を選択。
                guard let hardLineRange = textStorage.lineRange(at: index) else { log("lineRange is nil", from:self); return }
                let isLastLine = hardLineRange.upperBound == textStorage.count
                selectionRange = hardLineRange.lowerBound..<hardLineRange.upperBound + (isLastLine ? 0 : 1)
                
                _horizontalSelectionBase = selectionRange.lowerBound
                _mouseSelectionMode = .line
                
            default:
                break
            }
        case .lineNumber(let line):
            
            guard let line = _layoutManager.lines[line] else { log("line is nil", from:self); return }
            //selectionRange = lineInfo.range
            guard let hardLineRange = textStorage.lineRange(at: line.range.lowerBound) else { log("lineRange is nil", from:self); return }
            let isLastLine = hardLineRange.upperBound == textStorage.count
            selectionRange = hardLineRange.lowerBound..<hardLineRange.upperBound + (isLastLine ? 0 : 1)
            _horizontalSelectionBase = hardLineRange.lowerBound
            log("hardLineRange:\(hardLineRange), isLastLine: \(isLastLine)",from:self)
            log("  selectionRange: \(selectionRange)",from:self)
            
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
                switch layoutRect.regionType(for: location) {
                case .text(let index, _):
                    caretIndex = index
                    updateCaretPosition()
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
        endYankCycle()
        
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
                let str = String(textStorage.characterSlice[selectionRange])
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(str, forType: .string)
                
                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
                let dragImage = dragImage()
                let imageSize = dragImage.size
                let isDraggingDownward = location.y - dragStartPoint.y > 0
                
                // 上にドラッグした場合は下に、下にドラッグした場合は上にイメージを表示する。
                let originX = location.x - imageSize.width / 2
                let originY = location.y - imageSize.height / 2  +  (isDraggingDownward ? -imageSize.height : imageSize.height)
                let imageOrigin = CGPoint(x: originX, y: originY)
                
                draggingItem.setDraggingFrame(NSRect(origin: imageOrigin, size: dragImage.size), contents: dragImage)
                beginDraggingSession(with: [draggingItem], event: event, source: self)
                _singleClickPending = false
            }
            return
        }
        
        switch layoutRects.regionType(for: location){
        case .text(let index, _):
            guard let anchor = _latestClickedCharacterIndex else { log("_latestClickedCharacterIndex is nil", from:self); return }
            
            switch _mouseSelectionMode {
            case .character:
                selectionRange = min(anchor, index)..<max(anchor, index)
            case .word:
                if let wordRange1 = textStorage.wordRange(at: index),
                   let wordRange2 = textStorage.wordRange(at: anchor) {
                    selectionRange = min(wordRange1.lowerBound, wordRange2.lowerBound)..<max(wordRange1.upperBound, wordRange2.upperBound)
                }
            case .line:
                if let lineRangeForIndex = textStorage.lineRange(at: index),
                   let lineRangeForAnchor = textStorage.lineRange(at: anchor) {
                    let lower = min(lineRangeForIndex.lowerBound, lineRangeForAnchor.lowerBound)
                    let upper = max(lineRangeForIndex.upperBound, lineRangeForAnchor.upperBound)
                    let isLastLine = (textStorage.count == upper)
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
                let endsWithLF:Bool = lineRange.upperBound < textStorage.count
                        && textStorage.skeletonString[lineRange.upperBound] == FC.lf
                selectionRange = base..<lineRange.upperBound + (endsWithLF ? 1 : 0) // if the line ends with LF, include it.
            } else {
                selectionRange = lineRange.lowerBound..<base
            }
            
        case .outside:
            // textRegionより上なら文頭まで、下なら文末まで選択する。
            let textRect = layoutRects.textRegion.rect
            
            //log(".outside", from:self)
            
            if location.y < textRect.minY {
                //selectionRange = 0..<(_horizontalSelectionBase ?? caretIndex)
                selectionRange = 0..<selectionRange.upperBound
            } else if location.y > (_layoutManager.lineHeight * CGFloat(_layoutManager.lineCount) + layoutRects.textEdgeInsets.top)  {
                selectionRange = (_horizontalSelectionBase ?? caretIndex)..<textStorage.count
            }
            return
        }
        
        _ = self.autoscroll(with: event)
        
        updateCaretPosition()
    }

    // ドラッグ&ドロップ時に使用するアイコンを生成する。
    // 色々試したけどこれが一番見やすい。
    private func dragImage() -> NSImage {
        let cardSize = NSSize(width: 48, height: 48)
        let extraMargin: CGFloat = 36  // 周囲の透明枠
        let fullSize = NSSize(width: cardSize.width + extraMargin,
                              height: cardSize.height + extraMargin)
        
        let image = NSImage(size: fullSize)
        image.lockFocus()
        
        // 背景を完全透明
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: fullSize).fill()
        
        // 中央に白いカード
        let cardRect = NSRect(
            x: (fullSize.width - cardSize.width) / 2,
            y: (fullSize.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 0.97, alpha: 1.0).setFill()
        path.fill()
        
        // 枠線を明瞭に
        NSColor(calibratedWhite: 0.55, alpha: 1.0).setStroke()
        path.lineWidth = 1
        path.stroke()
        
        // アイコンを中央に描画
        if let symbol = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) {
            let inset: CGFloat = 12
            let symbolRect = NSRect(
                x: cardRect.minX + inset,
                y: cardRect.minY + inset,
                width: cardRect.width - inset * 2,
                height: cardRect.height - inset * 2
            )
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 0.85)
        }
        
        image.unlockFocus()
        return image
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
        let pb = sender.draggingPasteboard

        // Finder 等からのファイルURL
        if pb.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) {
            return .copy
        }

        // 文字列
        if pb.canReadObject(forClasses: [NSString.self], options: nil) {
            return .copy
        }

        return []
    }

    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let layoutRects = _layoutManager.makeLayoutRects() else { log("layoutRects is nil", from: self); return false }

        // ドロップ先インデックスを確定（テキスト領域以外は拒否）
        let dropIndex: Int
        switch layoutRects.regionType(for: locationInView) {
        case .text(let index, _):
            dropIndex = index
        default:
            return false
        }

        // ---- 1) Finder等からのファイルURLドロップ（優先） ----
        if let urls = readDroppedFileURLs(from: pasteboard), !urls.isEmpty {
            return insertDroppedFileURLs(urls, at: dropIndex, modifiers: NSEvent.modifierFlags)
        }
        
        // ---- 2) ブラウザ等からのWeb URLドロップ ----
        if let urls = readDroppedWebURLs(from: pasteboard), !urls.isEmpty {
            return insertDroppedWebURLs(urls, at: dropIndex, modifiers: NSEvent.modifierFlags)
        }

        // ---- 3) 既存：文字列ドロップ ----
        guard let items = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String],
              let rawDroppedString = items.first else {
            log("items is nil", from: self)
            return false
        }

        let droppedString = rawDroppedString.normalizedString

        let isSenderMyself = sender.draggingSource as AnyObject? === self
        let isOptionKeyPressed = NSEvent.modifierFlags.contains(.option)

        // 自身のdrag and dropで現在の選択範囲内部をポイントした場合は無効。
        if isSenderMyself && selectionRange.contains(dropIndex) { return false }

        if isOptionKeyPressed || !isSenderMyself { // .copy
            textStorage.replaceCharacters(in: dropIndex..<dropIndex, with: Array(droppedString))
            selectionRange = dropIndex..<dropIndex + droppedString.count
        } else { // .move
            if isSenderMyself {
                if dropIndex < selectionRange.lowerBound {
                    textStorage.replaceCharacters(in: selectionRange, with: Array(""))
                    textStorage.replaceCharacters(in: dropIndex..<dropIndex, with: Array(droppedString))
                } else {
                    let selectionLengh = selectionRange.upperBound - selectionRange.lowerBound
                    textStorage.replaceCharacters(in: selectionRange, with: Array(""))
                    textStorage.replaceCharacters(in: dropIndex - selectionLengh..<dropIndex - selectionLengh, with: Array(droppedString))
                    selectionRange = dropIndex - selectionLengh..<dropIndex - selectionLengh + droppedString.count
                }
            }
        }
        return true
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
        switch layoutRects.regionType(for: locationInView) {
        case .text(let index, _):
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
    
    // Finder 等からドロップされた fileURL を読む
    private func readDroppedFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let objs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return objs
    }
    
    // ブラウザ等からドロップされたURLを読む（file:// は除外）
    private func readDroppedWebURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let objs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }

        let webURLs = objs.filter { url in
            guard !url.isFileURL else { return false }
            guard let scheme = url.scheme?.lowercased() else { return false }
            
            let permittedSchemes = ["http", "https", "ftp", "mailto", "tel"]
            
            //return scheme == "http" || scheme == "https"
            return permittedSchemes.contains(scheme)
        }

        return webURLs.isEmpty ? nil : webURLs
    }

    // 現在ドキュメントの基準ディレクトリ（相対パス用）を取得
    private func documentBaseDirectoryURL() -> URL? {
        guard let doc = window?.windowController?.document else { return nil }
        guard let fileURL = doc.fileURL ?? nil else { return nil }
        return fileURL.deletingLastPathComponent()
    }


    // baseDir から見た相対パスを可能な限り生成する。
    // - 同一ボリューム上なら ../ を使って相対化する
    // - ルート（例: /Volumes/XXX）が異なる等で相対化が破綻する場合のみ absolute を返す
    private func makeRelativePathIfPossible(fileURL: URL, baseDir: URL) -> String {
        let basePath = baseDir.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path

        let baseComps = (basePath as NSString).pathComponents
        let fileComps = (filePath as NSString).pathComponents

        if baseComps.isEmpty || fileComps.isEmpty {
            return filePath
        }

        // 共通プレフィックス長を求める
        var commonCount = 0
        while commonCount < baseComps.count && commonCount < fileComps.count {
            if baseComps[commonCount] != fileComps[commonCount] { break }
            commonCount += 1
        }

        // ルートが一致しない（例: /Volumes/A と /Volumes/B）場合は相対化が破綻するので absolute
        // 目安として先頭（"/"）に続くトップレベルまで一致しない場合は諦める
        if commonCount < 2 {
            return filePath
        }

        // baseDir から共通部まで戻る分の ".."
        let upCount = max(0, baseComps.count - commonCount)
        var relComps: [String] = []
        relComps.reserveCapacity(upCount + (fileComps.count - commonCount))

        for _ in 0..<upCount {
            relComps.append("..")
        }

        // 目的地側の残り
        relComps.append(contentsOf: fileComps.dropFirst(commonCount))

        // 同一ディレクトリなどで空になった場合は "." にする（ここでは起きにくいが保険）
        if relComps.isEmpty {
            return "."
        }

        return relComps.joined(separator: "/")
    }

    // file drop の挿入本体
    private func insertDroppedFileURLs(_ urls: [URL], at index: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        // モード判定：
        //  - cmd+opt : 内容挿入
        //  - opt     : 絶対パス
        //  - none    : 相対パス（可能なら）/ できなければ絶対パス
        //  - shift   : パスについて.htmlの場合のみaタグ挿入とする。
        let isInsertContents = modifiers.contains(.command) && modifiers.contains(.option)
        let isAbsolutePath = modifiers.contains(.option) && !isInsertContents
        let isInHtmlMode = modifiers.contains(.shift)

        if isInsertContents {
            return insertDroppedFileContents(urls, at: index)
        } else {
            return insertDroppedFilePaths(urls, at: index, absolute: isAbsolutePath, tagMode: isInHtmlMode)
        }
    }
    
    private func insertDroppedWebURLs(_ urls: [URL], at index: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        // モード判定：
        //  - shift   : パスについて.htmlの場合のみaタグ挿入とする。
        
        let webURLString = urls[0].absoluteString
        
        if textStorage.parser.type == .html, modifiers.contains(.shift) {
            let selection = selectionRange
            
            let selectedString = selection.count == 0 ? webURLString : textStorage.string(in: selection)
            let tagString = "<a href=\"\(webURLString)\">\(selectedString)</a>"
            textStorage.replaceString(in: selection, with: tagString)
            selectionRange = selection.lowerBound..<selection.lowerBound + tagString.count
            return true
        }
        
        textStorage.insertString(webURLString, at: index)
        selectionRange = index..<index + webURLString.count
        
        return true
        
    }

    private func insertDroppedFilePaths(_ urls: [URL], at index: Int, absolute: Bool, tagMode: Bool) -> Bool {
        let baseDir = documentBaseDirectoryURL()

        // 複数は改行区切り（実用性優先）
        let paths: [String] = urls.map { url in
            //if !absolute, let baseDir, let rel = makeRelativePathIfPossible(fileURL: url, baseDir: baseDir) {
            if !absolute, let baseDir {
                return makeRelativePathIfPossible(fileURL: url, baseDir: baseDir)
            }
            return url.path
        }
        
        // HTMLモードで、pathが1つでかつshift keyが押下されている場合はaタグを挿入する。
        // 絶対パスの冒頭はfile:になるのが本来だが、今のところ実装していない。
        if paths.count == 1, tagMode, textStorage.parser.type == .html {
            let selection = selectionRange
            let fileName = urls[0].lastPathComponent
            let selectedString = selection.count == 0 ? fileName : textStorage.string(in: selection)
            let tagString = "<a href=\"\(paths[0])\">\(selectedString)</a>"
            textStorage.replaceString(in: selection, with: tagString)
            return true
        }
        
        // 複数ある場合は改行(lf)区切りとする。
        let joined = paths.joined(separator: "\n")

        textStorage.replaceString(in: index..<index, with: joined)

        // パスは全体選択
        selectionRange = index..<index + joined.count

        return true
    }

    private func insertDroppedFileContents(_ urls: [URL], at index: Int) -> Bool {
        // 複数の連結規則（現時点は「区切りなし」固定。後でpref化するならここだけ差し替え）
        let separator = ""

        var inserted = ""
        var detectedLogs: [(path: String, enc: KTextEncoding, ret: String.ReturnCharacter)] = []

        for (i, url) in urls.enumerated() {
            do {
                let data = try Data(contentsOf: url)
                let info = try Document.normalizeRawData(from: data)

                if i > 0 { inserted += separator }
                inserted += info.normalizedString

                detectedLogs.append((url.path, info.detectedEncoding, info.detectedReturnCharacter))
            } catch {
                log("File drop read failed: \(url.path), error: \(error)", from: self)
                NSSound.beep()
                return false
            }
        }

        textStorage.replaceString(in: index..<index, with: inserted)

        // 内容は後端にキャレット
        let end = index + inserted.count
        selectionRange = end..<end

        // 検出結果をユーザログに出す（KLogがある前提。なければ log() に寄せてください）
        for item in detectedLogs {
            KLog.shared.log(
                id: "TextView:Drop",
                message: "Dropped file decoded: \(item.path) (encoding: \(item.enc), newline: \(item.ret))"
            )
        }

        return true
    }

    
    
    // MARK: - Search Functions
    
    @discardableResult
    func search(for direction:KDirection = .forward) -> Bool {
        let searchString = KSearchPanel.shared.searchString
        let isCaseInsensitive = UserDefaults.standard.bool(forKey: KDefaultSearchKey.ignoreCase)
        let usesRegularExpression = UserDefaults.standard.bool(forKey: KDefaultSearchKey.useRegex)
        let wholeString = textStorage.string
        
        var regexPattern:Regex<Substring>
        
        do {
            if usesRegularExpression {
                regexPattern = try Regex(searchString).anchorsMatchLineEndings(true)
            } else {
                regexPattern = try Regex(NSRegularExpression.escapedPattern(for: searchString))
            }
        } catch {
            log("searchString is invalid.",from:self)
            NSSound.beep()
            return false
        }
        
        if isCaseInsensitive {
            regexPattern = regexPattern.ignoresCase()
        }
        
        if direction == .forward {
            let searchIndex = selectionRange.upperBound
            let targetString = wholeString[searchIndex..<wholeString.count]
            
            if let match = targetString.firstMatch(of: regexPattern),
               let range = targetString.integerRange(from:match.range) {
                
                selectionRange = searchIndex + range.lowerBound..<searchIndex + range.upperBound
            }
        } else {
            let targetString = wholeString[0..<selectionRange.lowerBound]
            let matches = targetString.matches(of: regexPattern)
            if let range = matches.last?.range,
               let intrange = targetString.integerRange(from: range){
                selectionRange = intrange
            }
        }
        
        updateCaretPosition()
        centerSelectionInVisibleArea(nil)
        
        return true
    }
    
    @discardableResult
    func replace() -> Bool {
        if selectionRange.isEmpty { NSSound.beep(); return false }
        
        let (count, _) = replaceAll(for: selectionRange)
        if count == 0 { return false }
        
        updateCaretPosition()
        scrollCaretToVisible()
        
        return true
    }
    
    @discardableResult
    func replaceAll() -> Bool {
        if textStorage.count == 0 { NSSound.beep(); return false }
        
        let targetRanage:Range<Int>
        let postSelectionLowerBound:Int
        
        let selectionOnly = UserDefaults.standard.bool(forKey: KDefaultSearchKey.selectionOnly)
        
        if selectionOnly {
            targetRanage = selectionRange
            postSelectionLowerBound = selectionRange.lowerBound
        } else {
            targetRanage = 0..<textStorage.count
            postSelectionLowerBound = 0
        }
        let (count, length) = replaceAll(for: targetRanage)
        var postSelection = postSelectionLowerBound..<postSelectionLowerBound + length
        if postSelection == 0..<textStorage.count {
            postSelection = 0..<0
        }
        selectionRange = postSelection
        
        updateCaretPosition()
        scrollCaretToVisible()
        
        KLog.shared.log(id: "TextView:replaceAll", message: "Replace All: \(count) replacement done.")
        
        return true
    }
    
    @discardableResult
    private func replaceAll(for range: Range<Int>) -> (count: Int, length: Int) {
        if range.isEmpty { NSSound.beep(); return (0, range.count) }
        guard range.lowerBound >= 0, range.upperBound <= textStorage.count else {
            log("range is out of bounds.",from:self)
            return (0, range.count)
        }

        let searchString = KSearchPanel.shared.searchString
        let replaceString = KSearchPanel.shared.replaceString
        let isCaseInsensitive = UserDefaults.standard.bool(forKey: KDefaultSearchKey.ignoreCase)
        let usesRegularExpression = UserDefaults.standard.bool(forKey: KDefaultSearchKey.useRegex)
        
        guard !searchString.isEmpty else { log("searchString is empty.",from:self); return (0, range.count) }

        let wholeString  = textStorage.string
        let targetString = wholeString[range]


        // Regex 準備（OFF のときは検索パターンをリテラル化、テンプレはエスケープ）
        let pattern  = usesRegularExpression
            ? searchString
            : NSRegularExpression.escapedPattern(for: searchString)
        let template = usesRegularExpression
            ? replaceString
            : NSRegularExpression.escapedTemplate(for: replaceString)

        var options: NSRegularExpression.Options =  [.anchorsMatchLines]
        if isCaseInsensitive {
            options.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            log("regex is nil.",from:self)
            NSSound.beep(); return (0, range.count)
        }

        // 部分文字列を可変化して置換＋件数取得
        let mutableString = NSMutableString(string: String(targetString))
        let mutableRange = NSRange(location: 0, length: mutableString.length)
        let count = regex.replaceMatches(in: mutableString, options: [], range: mutableRange, withTemplate: template)

        guard count > 0 else { NSSound.beep(); return (0, range.count) }

        // 置換結果で選択範囲全体を差し替え（nsRange内のみ変更されている）
        let replacedSub = String(mutableString)
        textStorage.replaceString(in: range, with: replacedSub)

        return (count, replacedSub.count)
    }
    
    
    // MARK: - Notifications

    @objc private func windowBecameKey(_ notification: Notification) {
        updateCaretActiveStatus()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        updateCaretActiveStatus()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let contentBounds = enclosingScrollView?.contentView.bounds
        else { log("cvBounds==nil", from: self); return }

        // 10万文字以上のときは live resize 中の「サイズ変化」による余計な再描画要求を抑止する。
        // ただし横スクロール（origin.xの変化）は caret の表示制御があるので最低限追従する。
        if _isFrozenDuringLiveResize {
            if contentBounds.origin.x != _prevContentViewBounds.origin.x {
                if let layoutRects = _layoutManager.makeLayoutRects(),
                   let contentView = enclosingScrollView?.contentView {
                    let pos = characterPosition(at: caretIndex)
                    let currentX = pos.x - layoutRects.horizontalInsets - contentView.bounds.minX

                    // 選択が空のときだけ表示可。行番号領域に隠れたら消す。
                    _caretView.isHidden = !selectionRange.isEmpty || (currentX < 0)
                }

                _prevContentViewBounds = contentBounds
                needsDisplay = true
            } else {
                _prevContentViewBounds = contentBounds
            }
            return
        }

        if contentBounds.origin.x != _prevContentViewBounds.origin.x {
            if let layoutRects = _layoutManager.makeLayoutRects(),
               let contentView = enclosingScrollView?.contentView {
                let pos = characterPosition(at: caretIndex)
                let currentX = pos.x - layoutRects.horizontalInsets - contentView.bounds.minX

                // 選択が空のときだけ表示可。行番号領域に隠れたら消す。
                _caretView.isHidden = !selectionRange.isEmpty || (currentX < 0)
            }

        }
        _prevContentViewBounds = contentBounds
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
        if hasMarkedText(), let marked = _markedTextRange {
            // markedText内（相対）の選択を文書座標へ変換
            let markedLen = marked.upperBound - marked.lowerBound
            let locInMarked = max(0, min(_selectedRangeInMarkedText.location, markedLen))
            let lenInMarked = max(0, min(_selectedRangeInMarkedText.length, markedLen - locInMarked))
            return NSRange(location: marked.lowerBound + locInMarked, length: lenInMarked)
        }
        return NSRange(selectionRange)
    }
    
    func insertText(_ string: Any, replacementRange: NSRange) {
        endYankCycle()

        let rawString: String
        if let str = string as? String {
            rawString = str
        } else if let attrStr = string as? NSAttributedString {
            rawString = attrStr.string
        } else {
            return
        }

        // IMEのreplacementRangeがNSNotFoundのことが多いので、
        // composing中はGanpi側で維持している_replacementRangeを優先して確定置換する
        let incoming = Range(replacementRange)
        let range: Range<Int>
        if let r = incoming {
            range = r
        } else if hasMarkedText(), let rep = _replacementRange {
            range = rep
        } else {
            range = selectionRange
        }

        let string = rawString.normalizedString
        textStorage.replaceCharacters(in: range, with: Array(string))

        _markedTextRange = nil
        _markedText = NSAttributedString()
        _replacementRange = nil
        _selectedRangeInMarkedText = NSRange(location: 0, length: 0)
    }
    
    //log("_replacementRange:\(_replacementRange), _markedTextRange:\(_markedTextRange), selectionRange:\(selectionRange), _selectedRangeInMarkedText:\(_selectedRangeInMarkedText)",from:self)
    
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {

        let attrString: NSAttributedString

        // 送られてきたstringはNSStringとNSAttributedStringの両方の可能性がある。
        // いずれにしてもNSAttributedStringとして整形しておく。
        if let str = string as? String {
            attrString = NSAttributedString(string: str)
        } else if let aStr = string as? NSAttributedString {
            attrString = aStr
        } else {
            return
        }

        // selectedRangeは「挿入される文字列のどこが選択されているか」、replacementRangeは「どこに挿入するか」を示す。

        // 選択範囲がある場合は、その部分を削除しておく。
        if selectionRange.count > 0 {
            textStorage.replaceCharacters(in: selectionRange, with: [])
            selectionRange = selectionRange.lowerBound..<selectionRange.lowerBound
        }

        // もし文字列が空の場合は変換が終了したとみなしてunmarkText()を呼び出す。
        // OS標準のIMとAquaSKKを試したがいずれも変換終了時にunmarkedText()を呼び出さないことを確認。2025-07-10
        if attrString.string.count == 0 {
            unmarkText()
            return
        }

        // Ganpi側の表示フォントに正規化（IME由来の underline 等は保持）
        let baseFont = textStorage.baseFont

        let fixedAttrString: NSAttributedString
        if attrString.length > 0,
           let f = attrString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
           f == baseFont {
            fixedAttrString = attrString
        } else {
            let mu = NSMutableAttributedString(attributedString: attrString)
            mu.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: mu.length))
            fixedAttrString = mu
        }

        // IMEはreplacementRangeをNSNotFoundで送ってくることが多い。
        // その場合に毎回selectionRangeへ退避すると、左へ拡張したreplacementRangeが次のsetMarkedTextで戻ってしまい、
        // FakeLine合成（prefix + marked + suffix）で重複が発生しやすい。
        //
        // 方針:
        // 1) replacementRangeが来たらそれを採用
        // 2) NSNotFoundなら、前回の_replacementRangeがあればそれを維持
        // 3) 前回が無ければ（= composing開始）selectionRangeを採用
        let incoming = Range(replacementRange)
        let range: Range<Int>
        if let r = incoming {
            range = r
        } else if let prev = _replacementRange {
            range = prev
        } else {
            range = selectionRange
        }

        // markedText内の選択（相対）を保持（既にプロパティ追加済み前提）
        _selectedRangeInMarkedText = selectedRange

        let plain = fixedAttrString.string

        _markedTextRange = range.lowerBound..<(range.lowerBound + plain.count)
        _markedText = fixedAttrString
        _replacementRange = range

        _caretView.isHidden = true

        needsDisplay = true
    }

    
    func unmarkText() {
        _markedTextRange = nil
        _markedText = NSAttributedString()
        _selectedRangeInMarkedText = NSRange(location: 0, length: 0)
        
        _caretView.isHidden = false
        
        needsDisplay = true
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [
            .underlineStyle,
            .underlineColor
        ]
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let swiftRange = Range(range),
              swiftRange.upperBound <= textStorage.count,
              let chars = textStorage[swiftRange] else {
            return nil
        }

        actualRange?.pointee = range
        return NSAttributedString(string: String(chars))
    }

    func characterIndex(for point: NSPoint) -> Int {
        // NSTextInputClient: point は screen 座標
        guard let window else { return NSNotFound }

        // screen -> window -> view
        let windowPoint = window.convertPoint(fromScreen: point)
        let viewPoint = convert(windowPoint, from: nil)

        guard let layoutRects = layoutManager.makeLayoutRects() else { return NSNotFound }

        switch layoutRects.regionType(for: viewPoint) {
        case let .text(index, _):
            // 念のためクランプ
            if index < 0 { return 0 }
            let n = textStorage.count
            if index > n { return n }
            return index

        case .lineNumber, .outside:
            return NSNotFound
        }
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        
        if let replacementRange = _replacementRange {
            //log("replacementRange: \(replacementRange), range: \(range)")
            guard var point = _layoutManager.lines.pointForFirstRect(for: replacementRange.lowerBound) else { log("pointForFirstRect(for:) failed.",from:self); return .zero }

            
            if let window = self.window {
                point = convert(point, to: nil)
                point = window.convertPoint(toScreen: point)
            }
            
            return NSRect(x: point.x, y: point.y, width: 1, height: _layoutManager.lineHeight)
        }
        
        return .zero
    }

    func baselineDelta(for characterIndex: Int) -> CGFloat {
        0
    }

    func windowLevel() -> Int {
        0
    }


    // MARK: - KTextView methods (helpers)
    
    func textStorageDidModify(_ modification: KStorageModified) {
        switch modification {
        case let .textChanged(info):
            let delta = info.insertedCount - info.range.count
            
            if info.range.lowerBound == selectionRange.lowerBound /*(削除+)追記*/ ||
                info.range.upperBound == selectionRange.lowerBound /*1文字削除*/ {
                // このtextviewによる編集。
                caretIndex = info.range.lowerBound + info.insertedCount
                scrollSelectionToVisible()
                
            } else {
                // 他のtextviewやAppleScriptなどによる編集。
                //log("the text was edited by another object.",from:self)
                //現在の選択範囲が挿入された範囲に対して、
                //1. 前方にある場合: 選択範囲は不変
                //2. 後方にある場合: 選択範囲は挿入された文字列の増減の分だけシフト
                //3. 挿入部分を完全に包含する場合: 選択部分の終端を文字列の増減分だけシフト
                //4. 前後に重なっている場合: 挿入部分の末尾にcaretを移動
                
                if selectionRange.upperBound < info.range.lowerBound {
                    // no arrangement of selection
                } else if selectionRange.lowerBound > info.range.upperBound {
                    selectionRange = selectionRange.lowerBound + delta..<selectionRange.upperBound + delta
                } else if selectionRange.lowerBound <= info.range.lowerBound && selectionRange.upperBound >= info.range.upperBound {
                    selectionRange = selectionRange.lowerBound..<selectionRange.upperBound + delta
                } else {
                    caretIndex = selectionRange.upperBound + delta
                }
            }
            
            // 簡易マーク機能で設定したマーク部分のindexを編集内容に合わせて変更。
            if let markedIndex = _markedCaretIndex {
                if markedIndex < info.range.lowerBound {
                    // do nothing
                } else if markedIndex > info.range.upperBound {
                    _markedCaretIndex = markedIndex + delta
                } else {
                    _markedCaretIndex = info.range.lowerBound
                }
            }
            
            sendEditedToDocument()
            updateFrameSizeToFitContent()
            resetCaretControllProperties()
            needsDisplay = true
            
        case .colorChanged(_):
            //log("カラー変更: range = \(range)",from:self)
            updateFrameSizeToFitContent()
            updateCaretPosition()
            scrollCaretToVisible()
            needsDisplay = true
        case .parserChanged:
            log("parserChanged:",from:self)
        }
        
    }
    
    private func resetCaretControllProperties() {
        _verticalCaretX = nil
        _verticalSelectionBase = nil
        _horizontalSelectionBase = nil
        _currentLineIndex = nil
    }

    // 別のKTextViewインスタンスから下記の設定を複製する。
    func loadSettings(from textView:KTextView) {
        autoIndent = textView.autoIndent
        wordWrap = textView.wordWrap
        showInvisibleCharacters = textView.showInvisibleCharacters
        showLineNumbers = textView.showLineNumbers
        editMode = textView.editMode
        
        layoutManager.lineSpacing = textView.layoutManager.lineSpacing
        layoutManager.wrapLineOffsetType = textView.layoutManager.wrapLineOffsetType
    }
    
    // 現在選択されている文字列を扱う。
    var selectedString: String {
        get { textStorage.string(in: selectionRange) }
        set {
            let selection = selectionRange
            let repString = newValue
            textStorage.replaceString(in: selection, with: repString)
            selectionRange = selection.lowerBound..<selection.lowerBound + repString.count
        }
    }
    
    // 現在のところinternalとしているが、将来的に公開レベルを変更する可能性あり。
    func updateFrameSizeToFitContent() {
        
        guard let layoutRects = _layoutManager.makeLayoutRects() else {
            log("_layoutManger.makeLayoutRects() - nil.", from:self)
            return
        }
        
        let textRegionRect = layoutRects.textRegion.rect
        
        let frameSize = frame.size
        let newFrameSize = CGSize(width: textRegionRect.width, height: textRegionRect.height)
        //setFrameSize(CGSize(width: textRegionRect.width, height: textRegionRect.height))
        if frameSize != newFrameSize {
            setFrameSize(newFrameSize)
        }
        enclosingScrollView?.contentView.needsLayout = true
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
        enclosingScrollView?.tile()

    }
    
    
    // characterIndex文字目の文字が含まれる行の位置。textRegion左上原点。
    private func linePosition(at characterIndex:Int) -> CGPoint {
        guard let layoutRects = _layoutManager.makeLayoutRects() else { log("#0"); return .zero }
        guard let lineIndex = layoutManager.lines.lineIndex(at: characterIndex) else { log("#1"); return .zero }
        return layoutRects.linePosition(at: lineIndex)
        
    }
    
    // characterIndex文字目の文字の位置。textRegion左上原点。
    private func characterPosition(at characterIndex:Int) -> CGPoint {
        guard let layoutRects = layoutManager.makeLayoutRects() else { log("#0"); return .zero }
        guard let lineIndex = layoutManager.lines.lineIndex(at: characterIndex) else { log("#1"); return .zero }
        return layoutRects.characterPosition(lineIndex: lineIndex, characterIndex: characterIndex)
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
        updateCaretActiveStatus()
    }
    
    private func sendStatusBarUpdateAction() {
        NSApp.sendAction(#selector(KStatusBarUpdateAction.statusBarNeedsUpdate(_:)),
                                         to: nil, from: self)
    }
    
    private func sendEditedToDocument() {
        NSApp.sendAction(#selector(KTextStorageAction.textStorageDidEdit(_:)),
                                         to: nil, from: self)
    }
    
    
    // 行番号ジャンプのためのメソッド
    // 対象を1つないし2つの指定子で指定する。
    // 指定子は「行:文字」で表される文字列で、それぞれ1から始まる行番号・行頭からの文字番号を示す。
    // 番号は省略が可能で、省略した場合は1と見做される。
    // L:C はL行目のC番目の文字、L: はL行目の1番目の文字、:Cは1行目のC番目の文字、:は1行目の1番目の文字を表す。
    // 単独の数値LはL行目全体(行末の改行含む)を表す。
    // 文字番号CはL行目の文字数を越えても問題ない。単にL行目の1文字目から数えてC文字目を表す。
    // 2つの指定子を並べた場合、1つ目と2つ目の示す領域全体を表す。
    // L1:C1 L2:C2 は、L1:C1 から L2:C2までを表す。L1 L2はL1行目からL2行目まで。L1:C1 L2 はL1のC1文字目から行L2の行末まで。
    // 3つ目以降の指定子、数値(0-9)・コロンを除く文字は全てスペーサーと見做される。
    func selectString(with spec: String) -> Range<Int>? {
        let skeleton = textStorage.skeletonString
        let newlines = skeleton.newlineIndices
        let docLen = textStorage.count

        func startOfLine(_ line: Int) -> Int? {
            guard line >= 1 else { return nil }
            if line == 1 { return 0 }
            let idx = line - 2
            guard idx < newlines.count else { return nil }
            return newlines[idx] + 1
        }

        func lineEndExclusive(from start: Int) -> Int {
            newlines.first(where: { $0 >= start }) ?? docLen
        }

        let tokens = spec
            .split(whereSeparator: { !$0.isNumber && $0 != ":" })
            .map(String.init)
            .prefix(2)

        guard !tokens.isEmpty else { return nil }

        func parseToken(_ t: String, isRightEdge: Bool) -> (start: Int, end: Int)? {
            // 純粋な行番号
            if let line = Int(t), !t.contains(":") {
                guard let start = startOfLine(line) else { return nil }
                let endEx = lineEndExclusive(from: start)
                guard endEx < docLen else { return nil }
                let end = endEx + 1
                return isRightEdge ? (end, end) : (start, end)
            }

            // L:C / L: / :C / :
            let parts = t.split(separator: ":", omittingEmptySubsequences: false)
            let line = Int(parts.first ?? "1") ?? 1
            let col  = Int(parts.count > 1 ? parts[1] : "1") ?? 1
            guard line >= 1, col >= 1 else { return nil }
            guard let lineStart = startOfLine(line) else { return nil }

            let pos = lineStart + (col - 1)
            return (pos, pos)
        }

        let parsed = tokens.enumerated().compactMap {
            parseToken($0.element, isRightEdge: $0.offset == 1)
        }

        guard parsed.count == tokens.count else { return nil }

        if parsed.count == 1 {
            let p = parsed[0]
            return p.start..<p.end
        }

        let a = parsed[0]
        let b = parsed[1]

        guard a.start <= b.start else { return nil }
        return a.start < b.end ? a.start..<b.end : nil

    }




    
    
    
    // mouseDown()などのセレクター履歴を残すためのダミー。
    @objc func clearCaretContext(_ sender: Any?) { }
    
    
    // キーボードショートカットやメニューから機能を実行するためのメソッド。
    @objc func performUserActions(_ sender: Any?) {
        let actions: [KUserAction]?

        if let menuItem = sender as? NSMenuItem {
            actions = menuItem.representedObject as? [KUserAction]
        } else if let actionsArg = sender as? [KUserAction] {
            actions = actionsArg
        } else {
            actions = nil
        }

        guard let actions else { log("#01"); return }

        for action in actions {
            switch action {
            case .selector(let name):
                //log("SELECTOR: \(name)")
                doCommand(by: Selector(name + ":"))
            case .command(let cmd):
                guard let result = cmd.execute(for: textStorage, in: selectionRange) else { log("#02"); return }
                let string = result.string
                let stringCount = string.count
                let targetRange = result.options.target == .selection ? selectionRange : 0..<textStorage.count
                textStorage.replaceString(in: targetRange, with: string)
                switch result.options.caret {
                case .left: caretIndex = targetRange.lowerBound
                case .right: caretIndex = targetRange.lowerBound + stringCount
                case .select: selectionRange = targetRange.lowerBound..<targetRange.lowerBound + stringCount
                    
                }
            }
        }
    }


    
    // scrollviewの水平スクローラーのオンオフを設定に追従させる。
    private func applyWordWrapToEnclosingScrollView() {
        guard let scrollView = self.enclosingScrollView else { return }

        if _wordWrap {
            if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
        } else {
            if !scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = true }
        }

        scrollView.tile()
    }
    
    // textviewの周囲にフォーカスリングを表示する必要があるか返す。
    private func shouldShowFocusBorder() -> Bool {
        guard window?.isKeyWindow == true else { return false }
        guard window?.firstResponder === self else { return false }
        // 祖先にある NSSplitView を探す
        var aView: NSView? = self
        while let s = aView, !(s is NSSplitView) { aView = s.superview }
        if let sv = aView as? NSSplitView { return sv.subviews.count > 1 }
        // SplitView不在（=1枚表示）は描かない
        return false
    }
    
    // textviewの周囲にフォーカスリングを表示する。
    @inline(__always)
    private func drawFocusBorderIfNeeded() {
        guard shouldShowFocusBorder() else { return }
        
        let vRect = self.visibleRect                    // ← スクロール中の可視領域（自座標系）
        guard !vRect.isEmpty else { return }
        
        let inset: CGFloat = 0.5
        let innerRect = vRect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: innerRect, xRadius: 2, yRadius: 2)
        let accent = NSColor.controlAccentColor
        
        // --- ソフトグロー（外側ふわっと） ---
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = 3              // 2〜4で好み調整
        glow.shadowColor = accent.withAlphaComponent(0.45)
        glow.set()
        
        accent.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1.0
        
        // 可視領域の内側に収める（グローが外へはみ出さない）
        NSBezierPath(rect: vRect).addClip()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        
        // --- 芯のヘアライン ---
        NSGraphicsContext.saveGraphicsState()
        accent.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 1.0
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    
    private func scrollClipView(to point: CGPoint) {
        guard let clipView = enclosingScrollView?.contentView else { return }

        if _isSmoothScrollEnabled {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(point)
            }
        } else {
            clipView.setBoundsOrigin(point)
        }

        enclosingScrollView?.reflectScrolledClipView(clipView)
    }


    
    
    
    
    //MARK: - Caret Movement
    
    private func moveCaretVertically(to direction: KDirection, extendSelection: Bool) {
        /*
         private var isVerticalAction: 今回のセレクタが垂直方向にキャレット・選択範囲を動かすか否か。
         private var wasVerticalAction: 前回のセレクタが垂直方向にキャレット・選択範囲を動かしたか否か。
         private var wasVerticalActionWithModifySelection: 前回のセレクタが垂直方向の選択範囲を動かしたか否か。
         private var wasHorizontalActionWithModifySelection: 全体のセレクタが水平方向に選択範囲を動かしたか否か。
         private var verticalCaretX: CGFloat?        // 縦方向にキャレットを移動する際の基準X。
         private var verticalSelectionBase: Int?     // 縦方向に選択範囲を拡縮する際の基準点。
         private var horizontalSelectionBase: Int?   // 横方向に選択範囲を拡縮する際の基準点。
         */
        
        if !wasVerticalActionWithModifySelection && extendSelection {
            _verticalSelectionBase = selectionRange.lowerBound
        }
        if _verticalSelectionBase == nil {
            _verticalSelectionBase = caretIndex
        }
        
        guard let currentLine = layoutManager.lines[currentLineIndex] else { log("currentLine is nil.",from:self); return }
        
        if _verticalCaretX == nil || !wasVerticalAction {
            let indexInLine = caretIndex - currentLine.range.lowerBound
            _verticalCaretX = currentLine.characterOffset(at: indexInLine)
        }
        
        guard let verticalCaretX = _verticalCaretX else { log("_verticalCaretX is nil.",from:self); return }
        guard let verticalSelectionBase = _verticalSelectionBase else { log("_verticalSelectionBase is nil.",from:self); return }
        var newCharacterIndex:Int = 0
        
        if selectionRange.lowerBound < verticalSelectionBase {
            guard let currentLowerBoundLineIndex = layoutManager.lines.lineIndex(at: selectionRange.lowerBound) else { log("currentLowerBoundLine is nil.",from:self); return }
            if currentLowerBoundLineIndex >= 0 {
                let newLineIndex = currentLowerBoundLineIndex + direction.rawValue
                if newLineIndex < 0 || newLineIndex > layoutManager.lines.count - 1 { log("<ok.newLineIndex is out of range.>",from:self); return }
                guard let newLine = layoutManager.lines[newLineIndex] else { log("newLine is nil.",from:self); return }
                let indexInLine = newLine.characterIndex(for: verticalCaretX)
                _currentLineIndex = newLineIndex
                newCharacterIndex = indexInLine + newLine.range.lowerBound
            } else {
                newCharacterIndex = 0
            }
        } else {
            let newLineIndex = currentLineIndex + direction.rawValue
            if newLineIndex < 0 || newLineIndex > layoutManager.lines.count - 1 { log("<ok.newLineIndex is out of range.>",from:self); return }
            guard let newLine = layoutManager.lines[newLineIndex] else { log("newLine is nil.",from:self); return }
            let indexInLine = newLine.characterIndex(for: verticalCaretX)
            _currentLineIndex = newLineIndex
            newCharacterIndex = indexInLine + newLine.range.lowerBound
        }
        
        
        if extendSelection {
            let lower = min(verticalSelectionBase, newCharacterIndex)
            let upper = max(verticalSelectionBase, newCharacterIndex)
            selectionRange = lower..<upper
        } else {
            caretIndex = newCharacterIndex
        }
        
        scrollCaretToVisible()
        
    }
    
    enum KCaretHorizontalMoveKind {
        case character
        case word
        case line
        case paragraph
        case document
    }
    
    // キーアサイン用のキャレット移動をサポートする関数
    // 水平方向の移動をサポート
    @discardableResult
    private func moveSelectionHorizontally(
            for kind: KCaretHorizontalMoveKind,
            to direction: KDirection,
            extendSelection: Bool,
            remove: Bool = false,
            ignoreLeadingSpaces: Bool = false) -> Bool {
        
        let selection = selectionRange
        let count = textStorage.count
        var newRange = selectionRange
        
        if kind == .document {
            if direction == .forward {
                if extendSelection { newRange = selection.lowerBound..<count }
                else { newRange = count..<count }
            } else {
                if extendSelection { newRange = 0..<selection.upperBound }
                else { newRange = 0..<0 }
            }
        }
        
        if kind == .paragraph {
            if ignoreLeadingSpaces { // ignoring direction.
                guard let range = textStorage.lineRange(at: selection.lowerBound) else {
                    log("lineRange is nil.",from:self); return false }
                var index = range.lowerBound
                let parag = KTextParagraph(storage: textStorage, range: range)
                let leadingSpacesRange = parag.leadingWhitespaceRange
                if range.count >= leadingSpacesRange.count {
                    index += leadingSpacesRange.count
                }
                let lower = min(index, selection.lowerBound)
                let upper = max(index, selection.upperBound)
                if extendSelection { newRange = lower..<upper }
                else { newRange = index..<index }
    
            }else if direction == .forward {
                guard let range = textStorage.lineRange(at: selection.upperBound) else {
                    log("lineRange is nil.",from:self); return false }
                let upper = range.upperBound
                if extendSelection { newRange = selection.lowerBound..<upper }
                else { newRange = upper..<upper }
            } else {
                guard let range = textStorage.lineRange(at: selection.lowerBound) else {
                    log("lineRange is nil.",from:self); return false }
                
                let lower = range.lowerBound
                if extendSelection { newRange = lower..<selection.upperBound }
                else { newRange = lower..<lower }
            }
        }
        
        if kind == .line {
            // ignoreLeadingSpacesは未実装。
            
            if direction == .forward {
                guard let line = layoutManager.lines[currentLineIndex] else { log("line is nil.",from:self); return false }
                let upper = line.range.upperBound
                if extendSelection { newRange = selection.lowerBound..<upper }
                else { newRange = upper..<upper }
            } else {
                guard let line = layoutManager.lines[currentLineIndex] else { log("line is nil.",from:self); return false }
                let lower = line.range.lowerBound
                if extendSelection { newRange =  lower..<selection.upperBound }
                else { newRange = lower..<lower }
            }
        }
        
        if kind == .word {
            
            if direction == .forward {
                var upper:Int
                if selection.upperBound != count,
                        let upperRange = textStorage.wordRange(at: selection.upperBound),
                        upperRange.upperBound != selection.upperBound {
                    upper = upperRange.upperBound
                } else {
                    upper = min(count, selection.upperBound + 1)
                }
                if extendSelection { newRange = selection.lowerBound..<upper }
                else { newRange = upper..<upper }
            } else {
                var lower:Int
                let min = max(selection.lowerBound - 1, 0)
                if selection.lowerBound != 0, let lowerRange = textStorage.wordRange(at: min){
                    lower = lowerRange.lowerBound
                } else {
                    lower = min
                }
                if extendSelection { newRange = lower..<selection.upperBound }
                else { newRange = lower..<lower }
            }
        }
        
        // 文字単位の場合のみ、選択範囲は起点を中心に拡縮する。他は両端から延長する方向。
        if kind == .character {
            if !wasHorizontalActionWithModifySelection && extendSelection {
                _horizontalSelectionBase = selection.lowerBound
            }
            
            if extendSelection, let base = _horizontalSelectionBase {
                let newBound = direction.rawValue + (base == selection.lowerBound ? selection.upperBound : selection.lowerBound)
                guard newBound <= count && newBound >= 0 else { log("character: out of range",from:self); return false }
                newRange = min(newBound, base)..<max(newBound, base)
            } else {
                if !selection.isEmpty {
                    if remove {
                        // do nothing. if selection is not empty and remove==true, simply remove selection.
                    } else {
                        newRange = direction == .forward ? selection.upperBound..<selection.upperBound : selection.lowerBound..<selection.lowerBound
                    }
                } else {
                    let newBound = selection.lowerBound + direction.rawValue
                    if newBound >= 0 && newBound <= count {
                        if remove { // if remove==true, remove characters in the range extended.
                            newRange = min(newBound, selection.lowerBound)..<max(newBound, selection.lowerBound)
                        } else {
                            newRange = newBound..<newBound
                        }
                    }
                }
            }
        }
        
        if remove {
            textStorage.deleteCharacters(in: newRange)
            selectionRange = newRange.lowerBound..<newRange.lowerBound
            
        } else {
            selectionRange = newRange
        }
        _verticalCaretX = nil
        scrollCaretToVisible()
        
        return true
    }
    
    /*
    enum KPageVerticalMoveKind {
        case page
        case line
    }*/
    enum KPageVerticalMoveKind {
        case fullPage
        case halfPage
    }
    
    
    // 縦方向のキャレット移動のうちページ単位で動作するもの。移動を半分にもできる。
    // キャレットはNSTextViewの挙動のようにキャレットのページ内での位置を再現しない。
    // .forwardの場合には左端最上段、.backwardの場合は左端最下段に表示される。
    private func moveSelectionVertically(for kind: KPageVerticalMoveKind, to direction: KDirection) {
        guard let scrollView = enclosingScrollView else {
            log("enclosingScrollView is nil", from: self)
            return
        }
        let clipView = scrollView.contentView
        guard let layoutRects = layoutManager.makeLayoutRects() else {
            log("layoutRects is nil", from: self)
            return
        }

        let topInset = layoutRects.textEdgeInsets.top
        let lineHeight = layoutManager.lineHeight
        let pageHeight = clipView.bounds.height
        let clipOrigin = clipView.bounds.origin

        // 現在の先頭行インデックスを整数で取得（誤差排除）
        let firstVisibleLineIndex = Int(floor((clipOrigin.y - topInset) / lineHeight))
        let visibleLineCount = Int(floor(pageHeight / lineHeight))

        // ---- 移動量（行数）を算出 ----
        let moveLines: Int
        switch kind {
        case .fullPage:
            moveLines = visibleLineCount
        case .halfPage:
            moveLines = visibleLineCount / 2
        }

        let offsetLines = direction == .forward ? moveLines : -moveLines
        var newFirstVisibleLineIndex = firstVisibleLineIndex + offsetLines
        newFirstVisibleLineIndex = max(0, min(layoutManager.lines.count - 1, newFirstVisibleLineIndex))

        // ---- スクロール位置を整数行単位で決定 ----
        let newY = CGFloat(newFirstVisibleLineIndex) * lineHeight + topInset
        //clipView.scroll(to: CGPoint(x: clipOrigin.x, y: newY))
        scrollClipView(to: CGPoint(x: clipOrigin.x, y: newY))
        scrollView.reflectScrolledClipView(clipView)

        // ---- キャレット位置の決定 ----
        let targetLineIndex: Int
        switch direction {
        case .forward:
            targetLineIndex = newFirstVisibleLineIndex
        case .backward:
            targetLineIndex = min(layoutManager.lines.count - 1,
                                  newFirstVisibleLineIndex + visibleLineCount - 1)
        }

        guard let line = layoutManager.lines[targetLineIndex] else {
            log("target line out of range", from: self)
            return
        }

        // キャレットを左端に固定
        caretIndex = line.range.lowerBound

    }




    
    // ページスクロール専用のメソッド。キャレット移動なし。
    // line毎のスクロールを廃止。代りにハーフページ移動を導入。テスト未。
    private func scrollVertically(for kind:KPageVerticalMoveKind, to direction:KDirection) {
        guard let scrollView = enclosingScrollView else { log("enclosingScrollView is nil",from: self); return }
        guard let documentBounds = scrollView.documentView?.bounds else { log("documentView is nil",from: self); return }
        let clipView = scrollView.contentView
        let lineHeight = layoutManager.lineHeight
        let pageHeight = clipView.bounds.height
        let clipViewOrigin = clipView.bounds.origin
        
        let overlapLineCount = 1.0
        let overLapHeight = overlapLineCount * lineHeight
                
        var y = 0.0
        switch direction {
        case .forward:
            switch kind {
                /*
            case .page: y = min(documentBounds.height - clipView.bounds.height, clipViewOrigin.y + pageHeight - overLapHeight)
            case .line: y = min(documentBounds.height - clipView.bounds.height, clipViewOrigin.y + lineHeight)*/
            case .fullPage: y = min(documentBounds.height - clipView.bounds.height, clipViewOrigin.y + pageHeight - overLapHeight)
            case .halfPage: y = min(documentBounds.height - clipView.bounds.height, clipViewOrigin.y + pageHeight / 2 - overLapHeight)
            }
        case .backward:
            switch kind {
                /*
            case .page: y = max(0, clipViewOrigin.y - pageHeight + overLapHeight)
            case .line: y = max(0, clipViewOrigin.y - lineHeight)*/
            case .fullPage: y = max(0, clipViewOrigin.y - pageHeight + overLapHeight)
            case .halfPage: y = max(0, clipViewOrigin.y - pageHeight / 2 + overLapHeight)
            }
        }
        // サブピクセル丸め
        y = y.rounded(.toNearestOrAwayFromZero)
        
        let point = CGPoint(x: clipViewOrigin.x, y: y)
        //clipView.scroll(to: point)
        scrollClipView(to: point)
        scrollView.reflectScrolledClipView(clipView)
    }
    

    
    // MARK: - Vertical Movement
    
    @IBAction override func moveUp(_ sender: Any?) {
        if completion.isInCompletionMode, completion.nowCompleting {
            completion.selectPrevious()
            needsDisplay = true
            return
        }
        moveCaretVertically(to: .backward, extendSelection: false)
    }
    
    @IBAction override func moveDown(_ sender: Any?) {
        if completion.isInCompletionMode, completion.nowCompleting {
            completion.selectNext()
            needsDisplay = true
            return
        }
        moveCaretVertically(to: .forward, extendSelection: false)
    }
    
    @IBAction override func moveUpAndModifySelection(_ sender: Any?) {
        moveCaretVertically(to: .backward, extendSelection: true)
    }
    
    @IBAction override func moveDownAndModifySelection(_ sender: Any?) {
        moveCaretVertically(to: .forward, extendSelection: true)
    }
    
    // Page.
    @IBAction override func pageUp(_ sender: Any?) {
        //moveSelectionVertically(for: .page, to: .backward, extendSelection: false)
        moveSelectionVertically(for: .fullPage, to: .backward)
    }
    
    @IBAction override func pageDown(_ sender: Any?) {
        //moveSelectionVertically(for: .page, to: .forward, extendSelection: false)
        moveSelectionVertically(for: .fullPage, to: .forward)
    }
    
    @IBAction func pageUpHalf(_ sender: Any?) {
        moveSelectionVertically(for: .halfPage, to: .backward)
    }
    
    @IBAction func pageDownHalf(_ sender: Any?) {
        moveSelectionVertically(for: .halfPage, to: .forward)
    }
    
    /*
    @IBAction override func pageUpAndModifySelection(_ sender: Any?) {
        moveSelectionVertically(for: .page, to: .backward, extendSelection: true)
    }
    
    @IBAction override func pageDownAndModifySelection(_ sender: Any?) {
        moveSelectionVertically(for: .page, to: .forward, extendSelection: true)
    }
    */
    
    // MARK: - Horizontal Movement
    
    // Character.
    @IBAction override func moveLeft(_ sender: Any?) {
        moveSelectionHorizontally(for: .character, to: .backward, extendSelection: false)
    }
    
    @IBAction override func moveRight(_ sender: Any?) {
        moveSelectionHorizontally(for: .character, to: .forward, extendSelection: false)
    }
    
    @IBAction override func moveLeftAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .character, to: .backward, extendSelection: true)
    }
    
    @IBAction override func moveRightAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .character, to: .forward, extendSelection: true)
    }
    
    
    // Word.
    @IBAction override func moveWordLeft(_ sender: Any?) {
        moveSelectionHorizontally(for: .word, to: .backward, extendSelection: false)
    }
    
    @IBAction override func moveWordRight(_ sender: Any?) {
        moveSelectionHorizontally(for: .word, to: .forward, extendSelection: false)
    }
    
    @IBAction override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .word, to: .backward, extendSelection: true)
    }
    
    @IBAction override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .word, to: .forward, extendSelection: true)
    }
    
    
    // Line.
    @IBAction override func moveToBeginningOfLine(_ sender: Any?) {
        moveSelectionHorizontally(for: .line, to: .backward, extendSelection: false)
    }
    
    @IBAction override func moveToEndOfLine(_ sender: Any?) {
        moveSelectionHorizontally(for: .line, to: .forward, extendSelection: false)
    }
    
    @IBAction override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .line, to: .backward, extendSelection: true)
    }
    
    @IBAction override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .line, to: .forward, extendSelection: true)
    }
    
    
    // Paragraph.
    @IBAction override func moveToBeginningOfParagraph(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .backward, extendSelection: false)
    }
    
    @IBAction override func moveToEndOfParagraph(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .forward, extendSelection: false)
    }
    
    @IBAction override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .backward, extendSelection: true)
    }
    
    @IBAction override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .forward, extendSelection: true)
    }
    
    // Document.
    @IBAction override func moveToBeginningOfDocument(_ sender: Any?) {
        moveSelectionHorizontally(for: .document, to: .backward, extendSelection: false)
    }
    
    @IBAction override func moveToEndOfDocument(_ sender: Any?) {
        moveSelectionHorizontally(for: .document, to: .forward, extendSelection: false)
    }
    
    @IBAction override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .document, to: .backward, extendSelection: true)
    }
    
    @IBAction override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .document, to: .forward, extendSelection: true)
    }
    
    // Paragraph without leading white spaces.
    @IBAction func moveToFirstPrintableCharacterInParagraph(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .backward, extendSelection: false, remove: false, ignoreLeadingSpaces: true)
    }
    
    @IBAction func moveToFirstPrintableCharacterInParagraphAndModifySelection(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .backward, extendSelection: true, remove: false, ignoreLeadingSpaces: true)
    }
    
    
    
    // Selection.
    @IBAction func moveToBeginningOfSelection(_ sender: Any?) {
        caretIndex = selectionRange.lowerBound
        scrollCaretToVisible()
    }
    
    @IBAction func moveToEndOfSelection(_ sender: Any?) {
        caretIndex = selectionRange.upperBound
        updateCaretPosition()
    }
    
    
    //MARK: - Select.
    
    @IBAction override func selectWord(_ sender: Any?) {
        let upper = max(selectionRange.upperBound - 1, selectionRange.lowerBound)
        guard let lowerRange = textStorage.wordRange(at: selectionRange.lowerBound) else { log("no lower.",from:self); return }
        guard let upperRange = textStorage.wordRange(at: upper) else { log("no upper.",from:self); return }
        selectionRange = lowerRange.lowerBound..<upperRange.upperBound
    }
    
    @IBAction override func selectLine(_ sender: Any?) {
        let lowerInfo = layoutManager.lines.lineInfo(at: selectionRange.lowerBound)
        let upperInfo = layoutManager.lines.lineInfo(at: selectionRange.upperBound)
        guard let lowerLine = lowerInfo.line else { log("no lower.",from:self); return }
        guard let upperLine = upperInfo.line else { log("no upper.",from:self); return }
        selectionRange = lowerLine.range.lowerBound..<upperLine.range.upperBound
    }
    
    @IBAction override func selectParagraph(_ sender: Any?) {
        guard let lowerRange = textStorage.lineRange(at: selectionRange.lowerBound) else { log("no lower.",from:self); return }
        guard let upperRange = textStorage.lineRange(at: selectionRange.upperBound) else { log("no upper.",from:self); return }
        selectionRange = lowerRange.lowerBound..<upperRange.upperBound
    }
    
    @IBAction func selectRange(_ sender: Any?) {
        
        guard let item = sender as? NSMenuItem, let range = item.representedObject as? Range<Int> else { return }
        selectionRange = range
        centerSelectionInVisibleArea(self)
    }
    
    //MARK: - Delete.
    
    @IBAction override func deleteBackward(_ sender: Any?) {
        moveSelectionHorizontally(for: .character, to: .backward, extendSelection: false, remove: true)
    }
    
    @IBAction override func deleteForward(_ sender: Any?) {
        moveSelectionHorizontally(for: .character, to: .forward, extendSelection: false, remove: true)
    }
    
    @IBAction override func deleteWordBackward(_ sender: Any?) {
        moveSelectionHorizontally(for: .word, to: .backward, extendSelection: true, remove: true)
    }
    
    @IBAction override func deleteWordForward(_ sender: Any?) {
        moveSelectionHorizontally(for: .word, to: .forward, extendSelection: true, remove: true)
    }
    
    @IBAction override func deleteToBeginningOfLine(_ sender: Any?) {
        moveSelectionHorizontally(for: .line, to: .backward, extendSelection: true, remove: true)
    }
    
    @IBAction override func deleteToEndOfLine(_ sender: Any?) {
        moveSelectionHorizontally(for: .line, to: .forward, extendSelection: true, remove: true)
    }
    
    @IBAction override func deleteToBeginningOfParagraph(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .backward, extendSelection: true, remove: true)
    }
    
    @IBAction override func deleteToEndOfParagraph(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .forward, extendSelection: true, remove: true)
    }
    
    @IBAction func deleteToBeginningOfParagraphWithoutLeadingSpaces(_ sender: Any?) {
        moveSelectionHorizontally(for: .paragraph, to: .forward, extendSelection: true, remove: true, ignoreLeadingSpaces: true)
    }
    
    

    //MARK: - Scrolling.

    @IBAction override func scrollPageUp(_ sender: Any?) {
        //scrollVertically(for: .page, to: .backward)
        scrollVertically(for: .fullPage, to: .backward)
    }
    
    @IBAction override func scrollPageDown(_ sender: Any?) {
        //scrollVertically(for: .page, to: .forward)
        scrollVertically(for: .fullPage, to: .forward)
    }
    
    @IBAction override func scrollLineUp(_ sender: Any?) {
        //scrollVertically(for: .line, to: .backward)
    }
    
    @IBAction override func scrollLineDown(_ sender: Any?) {
        //scrollVertically(for: .line, to: .forward)
    }
    
    @IBAction override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView

        let caretPosition = characterPosition(at: caretIndex)
        let lineHeight = layoutManager.lineHeight
        let caretRect = NSRect(x: caretPosition.x,
                               y: caretPosition.y - lineHeight * 0.7,
                               width: 2,
                               height: lineHeight)

        let visibleSize = clipView.bounds.size
        let documentBounds = bounds

        // wrap=false のときだけ横スクロールを考慮
        let targetX: CGFloat = {
            guard !wordWrap else { return clipView.bounds.origin.x }
            let rawX = caretRect.midX - visibleSize.width / 2
            let maxX = max(0, documentBounds.width - visibleSize.width)
            return max(0, min(rawX, maxX))
        }()

        // 縦方向
        let rawY = caretRect.midY - visibleSize.height / 2
        let maxY = max(0, documentBounds.height - visibleSize.height)
        let targetY = max(0, min(rawY, maxY))

        //clipView.scroll(to: NSPoint(x: targetX, y: targetY))
        scrollClipView(to: NSPoint(x: targetX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }
    
    
    
    // MARK: - Insert Functional Characters
    
    @IBAction override func insertNewline(_ sender: Any?) {
        let newlineChar:Character = "\n"
        
        var spaces:[Character] = [newlineChar]
        
        if _autoIndent && selectionRange.lowerBound != 0 && textStorage[selectionRange.lowerBound - 1] != newlineChar {
            var range = 0..<0
            for i in (0..<selectionRange.lowerBound - 1).reversed() {
                if i == 0 {
                    range = 0..<selectionRange.lowerBound
                } else if textStorage[i] == newlineChar {
                    range = (i + 1)..<selectionRange.lowerBound
                    break
                }
            }
            
            for i in range {
                if let c = textStorage[i] {
                    if !" \t".contains(c) { break }
                    spaces.append(c)
                }
            }
        }
        
        textStorage.replaceString(in: selectionRange, with: String(spaces))
    }
    

    // 複数行を選択している場合はshiftRight:を実行する。
    // 単行の場合は選択範囲を削除した上で、行頭の空白(space|tab混合)内ならtab stop相当までspaceを入力、
    // そうでなければ1文字のspaceを入力する。
    @IBAction override func insertTab(_ sender: Any?) {
        let parags = textStorage.paragraphs
        
        if let indexRange = parags.paragraphIndexRange(containing: selectionRange),
                indexRange.count > 1 {
            shiftRight(self)
            return
        }
        
        var selection = selectionRange
        
        if !selection.isEmpty {
            textStorage.deleteCharacters(in: selection)
            selectionRange = selection.lowerBound..<selection.lowerBound
            selection = selectionRange
        }
        
        let tabWidth = layoutManager.tabWidth
        
        guard let pIndex = parags.paragraphIndex(containing: selection.lowerBound) else { log("0"); return }
        let width = parags[pIndex].tabStopDeltaInIndent(at: selection.lowerBound, tabWidth: tabWidth, direction: .forward)
        textStorage.replaceString(in: selection, with: String(repeating: " ", count: max(1, width)))
    }
    
    // insertTab()が標準でspaceを入力する仕様のため、代わりに\tを入力するためのアクション。
    @IBAction func insertLiteralTabCharacter(_ sender: Any?) {
        textStorage.replaceString(in: selectionRange, with: "\t")
    }
    
    // 複数行を選択している場合はshiftLeft:を実行する。
    // 単行の場合は選択範囲を削除した上で、行頭の空白(space|tab混合)内ならtab stop相当までspace|tabを削除、
    // そうでなければ直前の1文字のspaceを削除するか、なにもしない。
    @IBAction override func insertBacktab(_ sender: Any?) {
        let tabWidth = layoutManager.tabWidth
        let parags = textStorage.paragraphs

        if let idxRange = parags.paragraphIndexRange(containing: selectionRange),
           idxRange.count > 1 {
            shiftLeft(self)
            return
        }

        // 選択があれば消去（caret は自動で末尾へ）
        if !selectionRange.isEmpty {
            textStorage.replaceString(in: selectionRange, with: "")
        }

        let caret = selectionRange.lowerBound
        guard let pIndex = parags.paragraphIndex(containing: caret) else { log("paragraphIndex: nil", from: self); return }
        let paragraph = parags[pIndex]

        let head = paragraph.leadingWhitespaceRange
        let isInIndent = head.contains(caret) || caret == head.upperBound

        // インデント外：直前がスペースなら1つ削除
        guard isInIndent else {
            if caret > paragraph.range.lowerBound {
                let skel = textStorage.skeletonString
                let prev = caret - 1
                if skel[prev] == FC.space {
                    textStorage.replaceString(in: prev..<caret, with: "")
                }
            }
            return
        }

        // ★ まずタブを優先的に食う
        let skel = textStorage.skeletonString
        if caret > head.lowerBound, skel[caret - 1] == FC.tab {
            textStorage.replaceString(in: (caret - 1)..<caret, with: "")
            return
        }

        // タブでなければ、前ストップまでのスペースを削除
        let delta = paragraph.tabStopDeltaInIndent(at: caret, tabWidth: tabWidth, direction: .backward)

        var to = caret
        var remain = delta
        while remain > 0, to > head.lowerBound, skel[to - 1] == FC.space {
            to -= 1
            remain -= 1
        }
        if to < caret {
            textStorage.replaceString(in: to..<caret, with: "")
        }
    }
    
    
    // MARK: - Edit Characters.
    
    @IBAction override func transpose(_ sender: Any?) {
        let caret = caretIndex
        if textStorage.count < 2 || caret == 0 { return }
        var replace:Range<Int>
        if caret == textStorage.count || textStorage.skeletonString[caret] == FC.lf {
            replace = caret - 2..<caret // if the caret stays end of the text, last 2 characters will transpose.
        } else {
            replace = caret - 1..<caret + 1
        }
        guard let left = textStorage[replace.lowerBound], let right = textStorage[replace.lowerBound + 1] else { log("left or right char is nil.",from:self); return }
        // if target characters contain LF, no transpose.
        if (textStorage.skeletonString[replace.lowerBound] == FC.lf || textStorage.skeletonString[replace.lowerBound + 1] == FC.lf) { return }
        textStorage.replaceCharacters(in: replace, with: [right, left])
        caretIndex = replace.lowerBound + 1
    }
    
    @IBAction override func capitalizeWord(_ sender: Any?) {
        convertCaseOfWord(for: .capitalized)
    }
    
    @IBAction override func lowercaseWord(_ sender: Any?) {
        convertCaseOfWord(for: .lowercased)
    }
    
    @IBAction override func uppercaseWord(_ sender: Any?) {
        convertCaseOfWord(for: .uppercased)
    }
    
    enum KCaseCoversionType {
        case lowercased
        case uppercased
        case capitalized
    }
    
    private func convertCaseOfWord(for type:KCaseCoversionType) {
        let upper = max(selectionRange.upperBound - 1, selectionRange.lowerBound)
        guard let lowerRange = textStorage.wordRange(at: selectionRange.lowerBound) else { log("no lower.",from:self); return }
        guard let upperRange = textStorage.wordRange(at: upper) else { log("no upper.",from:self); return }
        
        let newSelection = lowerRange.lowerBound..<upperRange.upperBound
        if newSelection.isEmpty { return }
        
        let string = textStorage.string[newSelection]
        var newString:String
        
        switch type {
        case .lowercased: newString = string.lowercased()
        case .uppercased: newString = string.uppercased()
        case .capitalized: newString = string.capitalized
        }
        textStorage.replaceString(in: newSelection, with: newString)
        selectionRange = newSelection
        
    }
    
    @IBAction override func yank(_ sender: Any?) {
        paste(sender)
    }
    
    @IBAction func yankPop(_ sender: Any?) {
        let buffer = KClipBoardBuffer.shared
        guard buffer.isInCycle, let selection = _yankSelection else { NSSound.beep(); return }
        _isApplyingYank = true
        defer { _isApplyingYank = false }
        textStorage.undo()
        buffer.pop()
        textStorage.replaceString(in: selection, with: buffer.currentBuffer)
    }
    
    @IBAction func yankPopReverse(_ sender: Any?) {
        let buffer = KClipBoardBuffer.shared
        guard buffer.isInCycle, let selection = _yankSelection else { NSSound.beep(); return }
        _isApplyingYank = true
        defer { _isApplyingYank = false }
        textStorage.undo()
        buffer.popReverse()
        textStorage.replaceString(in: selection, with: buffer.currentBuffer)
    }
    
    // Yankの動作を終了させるためのメソッド。一時的にここに置く。
    private func endYankCycle() {
        if !_isApplyingYank {
            KClipBoardBuffer.shared.endCycle()
            _yankSelection = nil
        }
    }
    
    
    
    // MARK: - Completion
    @IBAction func setCompletionModeOn(_ sender: Any?) {
        completion.isInCompletionMode = true
    }
    
    @IBAction func setCompletionModeOff(_ sender: Any?) {
        completion.isInCompletionMode = false
    }
    
    @IBAction func toggleCompletionMode(_ sender: Any?) {
        completion.isInCompletionMode = !completion.isInCompletionMode
    }
    
    // MARK: - COPY and Paste (NSResponder method)
    
    @IBAction func cut(_ sender: Any?) {
        copy(sender)
        
        textStorage.replaceCharacters(in: selectionRange, with: [])
    }
    
    @IBAction func copy(_ sender: Any?) {
        if selectionRange.isEmpty { return }
        
        guard let slicedCharacters = textStorage[selectionRange] else { return }
        let selectedText = String(slicedCharacters)
        
        let buffer = KClipBoardBuffer.shared
        buffer.append()
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }
    
    @IBAction func paste(_ sender: Any?) {
        _isApplyingYank = true
        defer { _isApplyingYank = false }
        
        let buffer = KClipBoardBuffer.shared
        
        _yankSelection = selectionRange
        buffer.beginCycle()
        let string = buffer.currentBuffer
        textStorage.replaceCharacters(in: selectionRange, with: Array(string))
        
    }
    
    @IBAction override func selectAll(_ sender: Any?) {
        selectionRange = 0..<textStorage.count
        
    }
    
    // クリップボードの文字列をペーストする際、選択範囲の文字列をクリップボードにコピーする。
    // 次のペーストは前回のペーストで削除された文字列に入れ替わる。
    @IBAction func exchangePaste(_ sender: Any?) {
        _isApplyingYank = true
        defer { _isApplyingYank = false }
        
        let buffer = KClipBoardBuffer.shared
        
        _yankSelection = selectionRange
        buffer.beginCycle()
        let pasteString = buffer.currentBuffer
        let removedString = textStorage.string(in: selectionRange)
        textStorage.replaceCharacters(in: selectionRange, with: Array(pasteString))
        
        if removedString.count == 0 { return }
        
        buffer.append()
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(removedString, forType: .string)
    }
    
    // MARK: - Others.
    
    @IBAction func insertDeleteBuffer(_ sender: Any?) {
        if let deleteBuffer = (NSApp.delegate as? AppDelegate)?.deleteBuffer {
            textStorage.replaceString(in: selectionRange, with: deleteBuffer)
        } else {
            log("no delete buffer.", from:self)
        }
        
    }

    @IBAction func storeSelectionRange(_ sender: Any?) {
        _selectionBuffer = selectionRange
    }
    
    @IBAction func restoreSelectionRange(_ sender: Any?) {
        if let buffer = selectionBuffer {
            //log("buffer:\(buffer)",from:self)
            let selection = selectionRange
            let lower = max(selection.lowerBound, buffer.lowerBound)
            let upper = min(selection.upperBound, buffer.upperBound)
            selectionRange = lower..<upper
        } else {
            log("no selection buffer.", from:self)
        }
    }
    
    
    @IBAction func showMiniSearchPanel(_ sender: Any?) {
        var point = characterPosition(at: caretIndex)
        point.y = point.y + layoutManager.lineHeight
        if let window = self.window {
            point = convert(point, to: nil)
            point = window.convertPoint(toScreen: point)
        }
        KMiniSearchPanel.shared.show(at: point)
        
    }
    
}

