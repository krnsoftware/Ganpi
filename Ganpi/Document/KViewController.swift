//
//  KViewController.swift
//  Ganpi
//
//  Created by KARINO Masatugu
//

import Cocoa

final class KViewController: NSViewController, NSUserInterfaceValidations, NSSplitViewDelegate {

    // MARK: - Private properties

    private weak var _document: Document?
    private var _splitView: KSplitView?
    private var _panes: [KTextViewContainerView] = []
    private var _needsConstruct: Bool = false
    private var _syncOptions: Bool = true

    private let _dividerHitWidth: CGFloat = 5.0
    private let _statusBarHeight: CGFloat = 20
    private let _statusBarFont: NSFont = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    // 行間の粗調整ステップ
    private let _lineSpacingStep: CGFloat = 1.0

    // コンテナはコードで用意（XIBなし前提）
    private let _contentContainer = NSView()
    private let _statusBarView    = NSView()

    // Status Bar（全面ボタン化）
    private let _encButton    = NSButton(title: "", target: nil, action: nil)
    private let _eolButton    = NSButton(title: "", target: nil, action: nil)
    private let _syntaxButton = NSButton(title: "", target: nil, action: nil)
    private let _caretButton  = NSButton(title: "", target: nil, action: nil)
    private let _fontSizeButton   = NSButton(title: "", target: nil, action: nil)   // "FS: <val>"
    private let _lineSpacingButton = NSButton(title: "", target: nil, action: nil)  // "LS: <val>"

    // Popovers
    private var _jumpPopover: NSPopover?
    private var _typographyPopover: NSPopover?

    // MARK: - Menu actions and others.

    @IBAction func splitVertically(_ sender: Any?)   { ensureSecondPane(orientation: .vertical) }
    @IBAction func splitHorizontally(_ sender: Any?) { ensureSecondPane(orientation: .horizontal) }
    @IBAction func removeSplit(_ sender: Any?)       { removeSecondPaneIfExists() }

    @IBAction func toggleAutoIndent(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        activeTextView.autoIndent.toggle()
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.autoIndent = activeTextView.autoIndent } }
    }

    @IBAction func toggleWordWrap(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        activeTextView.wordWrap.toggle()
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.wordWrap = activeTextView.wordWrap } }
    }

    @IBAction func toggleShowLineNumbers(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        activeTextView.showLineNumbers.toggle()
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.showLineNumbers = activeTextView.showLineNumbers } }
    }

    @IBAction func toggleShowInvisibleCharacters(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        activeTextView.showInvisibleCharacters.toggle()
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.showInvisibleCharacters = activeTextView.showInvisibleCharacters } }
    }

    @IBAction func toggleSyncOptions(_ sender: Any?) { syncOptions.toggle() }

    @IBAction func increaseLineSpacing(_ sender: Any?) {
        guard let tv = activeTextView() else { log("activeTextView is nil.", from: self); return }
        tv.layoutManager.lineSpacing += _lineSpacingStep
        if syncOptions {
            textViews.forEach { if $0 !== tv { $0.layoutManager.lineSpacing = tv.layoutManager.lineSpacing } }
        }
        updateStatusBar()
    }

    @IBAction func decreaseLineSpacing(_ sender: Any?) {
        guard let tv = activeTextView() else { log("activeTextView is nil.", from: self); return }
        tv.layoutManager.lineSpacing = max(0, tv.layoutManager.lineSpacing - _lineSpacingStep)
        if syncOptions {
            textViews.forEach { if $0 !== tv { $0.layoutManager.lineSpacing = tv.layoutManager.lineSpacing } }
        }
        updateStatusBar()
    }
/*
    @IBAction func showLineSpacingSheet(_ sender: Any?) {
        // 旧KPromptシートは廃止。Popoverで置換するためビープのみに。
        NSSound.beep()
    }*/
    
    @IBAction func showLineSpacingPopoverFromMenu(_ sender: Any?) {
        _lineSpacingButton.performClick(nil)
    }

    // フォントサイズ（VCで集約）
    @IBAction func increaseFontSize(_ sender: Any?) {
        guard let storage = _document?.textStorage else { return }
        storage.fontSize = storage.fontSize + 1
        if syncOptions {
            // すべての textView が同じ textStorage を参照していれば自動反映、
            // 別インスタンスならここで伝播する（現状は共有参照想定）
            textViews.forEach { _ = $0 } // no-op
        }
        updateStatusBar()
    }

    @IBAction func decreaseFontSize(_ sender: Any?) {
        guard let storage = _document?.textStorage else { return }
        if storage.fontSize <= 5 { return }
        storage.fontSize = storage.fontSize - 1
        if syncOptions {
            textViews.forEach { _ = $0 }
        }
        updateStatusBar()
    }
    
    @IBAction func showFontSizePopoverFromMenu(_ sender: Any?) {
        // 既存の _fontSizeButton の action がそのまま使われる
        _fontSizeButton.performClick(nil)
    }
    
    @IBAction func showCaretJumpPopoverFromMenu(_ sender: Any?) {
        _caretButton.performClick(nil)
    }

    /*
    private func setFontSize(_ value: Double) {
        guard let storage = _document?.textStorage else { return }
        storage.fontSize = max(5, value)
        if syncOptions {
            textViews.forEach { _ = $0 }
        }
        updateStatusBar()
    }*/

    // MARK: - UI validation

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let textView = activeTextView() else { return true }

        switch item.action {
        case #selector(toggleShowLineNumbers(_:)):
            (item as? NSMenuItem)?.state = textView.showLineNumbers ? .on : .off
            return true
        case #selector(toggleWordWrap(_:)):
            (item as? NSMenuItem)?.state = textView.wordWrap ? .on : .off
            return true
        case #selector(toggleShowInvisibleCharacters(_:)):
            (item as? NSMenuItem)?.state = textView.showInvisibleCharacters ? .on : .off
            return true
        case #selector(toggleAutoIndent(_:)):
            (item as? NSMenuItem)?.state = textView.autoIndent ? .on : .off
            return true
        case #selector(toggleSyncOptions(_:)):
            (item as? NSMenuItem)?.state = syncOptions ? .on : .off
            return true

        case #selector(splitVertically), #selector(splitHorizontally):
            return _panes.count == 1 && _splitView != nil
        case #selector(removeSplit):
            return _panes.count == 2
        default:
            return true
        }
    }

    // MARK: - Document hook

    var document: Document? {
        get { _document }
        set {
            guard _document == nil, let doc = newValue else { return }
            _document = doc
            _needsConstruct = true
            updateStatusBar()
            if isViewLoaded, _contentContainer.superview != nil { constructViews() }
        }
    }

    var syncOptions: Bool {
        get { _syncOptions }
        set {
            _syncOptions = newValue
            if !_syncOptions { return }
            guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
            textViews.forEach { if $0 !== activeTextView { $0.loadSettings(from: activeTextView) } }
        }
    }

    private var textViews: [KTextView] {
        var views:[KTextView] = []
        if let splitView = _splitView {
            for view in splitView.arrangedSubviews {
                if let container = view as? KTextViewContainerView  {
                    views.append(container.textView)
                }
            }
        }
        return views
    }

    // MARK: - Lifecycle

    override func loadView() { view = NSView() }

    override func viewDidAppear() {
        super.viewDidAppear()
        installContainersOnce()
        constructViews()
    }

    // MARK: - One-time scaffolding (upper content / lower status bar)

    private func installContainersOnce() {
        guard _contentContainer.superview == nil else { return }

        _contentContainer.translatesAutoresizingMaskIntoConstraints = false
        _statusBarView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(_contentContainer)
        view.addSubview(_statusBarView)

        NSLayoutConstraint.activate([
            _statusBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            _statusBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            _statusBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            _statusBarView.heightAnchor.constraint(equalToConstant: _statusBarHeight),

            _contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            _contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            _contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            _contentContainer.bottomAnchor.constraint(equalTo: _statusBarView.topAnchor),
        ])

        // 見た目（薄いセパレータ）
        _statusBarView.wantsLayer = true
        _statusBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        _statusBarView.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: _statusBarView.topAnchor),
            separator.leadingAnchor.constraint(equalTo: _statusBarView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: _statusBarView.trailingAnchor)
        ])

        buildStatusBarUI()
        updateStatusBar()
    }

    // MARK: - Build split view + first pane

    private func constructViews() {
        guard _needsConstruct, _splitView == nil, let textStorage = _document?.textStorage else { return }

        let sv = KSplitView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.dividerStyle = .thin
        sv.isVertical = true
        sv.delegate = self

        _contentContainer.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.leadingAnchor.constraint(equalTo: _contentContainer.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: _contentContainer.trailingAnchor),
            sv.topAnchor.constraint(equalTo: _contentContainer.topAnchor),
            sv.bottomAnchor.constraint(equalTo: _contentContainer.bottomAnchor),
        ])
        _splitView = sv

        let first = KTextViewContainerView(frame: .zero, textStorageRef: textStorage)
        first.translatesAutoresizingMaskIntoConstraints = true
        first.autoresizingMask = [.width, .height]
        _panes = [first]

        sv.addSubview(first)
        sv.adjustSubviews()

        _needsConstruct = false
        updateStatusBar()
    }

    // MARK: - Status Bar

    private func buildStatusBarUI() {
        // ボタン外観
        let buttons = [_encButton, _eolButton, _syntaxButton, _caretButton, _fontSizeButton, _lineSpacingButton]
        buttons.forEach {
            $0.font = _statusBarFont
            $0.isBordered = false
            $0.bezelStyle = .inline
            $0.setButtonType(.momentaryPushIn)
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.lineBreakMode = .byTruncatingTail
            $0.contentTintColor = .labelColor
        }

        // 左：Encoding / EOL / Syntax（クリックでメニュー）
        _encButton.target = self;    _encButton.action = #selector(openEncodingMenuFromButton(_:))
        _eolButton.target = self;    _eolButton.action = #selector(openEOLMenuFromButton(_:))
        _syntaxButton.target = self; _syntaxButton.action = #selector(openSyntaxMenuFromButton(_:))

        // 右：Caret（行ジャンプ）/ FS / LS（ポップオーバ）
        _caretButton.target = self;        _caretButton.action = #selector(showCaretPopover(_:))
        _fontSizeButton.target = self;     _fontSizeButton.action = #selector(showTypographyPopover_ForFontSize(_:))
        _lineSpacingButton.target = self;  _lineSpacingButton.action = #selector(showTypographyPopover_ForLineSpacing(_:))

        let leftStack = NSStackView(views: [_encButton, _eolButton, _syntaxButton])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [_caretButton, _fontSizeButton, _lineSpacingButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 12
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        _statusBarView.addSubview(leftStack)
        _statusBarView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: _statusBarView.leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: _statusBarView.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: _statusBarView.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: _statusBarView.centerYAnchor),
        ])
    }

 

    // MARK: - Encoding / EOL / Syntax（NSMenuをボタンから）

    private let _encodingCandidates: [String.Encoding] = [
        .utf8, .utf16, .utf32, .shiftJIS, .japaneseEUC, .iso2022JP
    ]

    @objc private func openEncodingMenuFromButton(_ sender: NSButton) {
        guard let doc = _document else { return }
        let menu = NSMenu()
        for enc in _encodingCandidates {
            let item = NSMenuItem(title: humanReadableEncoding(enc), action: #selector(didChooseEncoding(_:)), keyEquivalent: "")
            item.target = self
            item.state = (enc == doc.characterCode) ? .on : .off
            item.representedObject = enc.rawValue // あなたの方式に合わせる
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    @objc private func openEOLMenuFromButton(_ sender: NSButton) {
        guard let doc = _document else { return }
        let menu = NSMenu()
        for eol in [String.ReturnCharacter.lf, .crlf, .cr] {
            let item = NSMenuItem(title: humanReadableEOL(eol), action: #selector(didChooseEOL(_:)), keyEquivalent: "")
            item.target = self
            item.state = (eol == doc.returnCode) ? .on : .off
            item.representedObject = eol.rawValue // あなたの方式に合わせる（String）
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    @objc private func openSyntaxMenuFromButton(_ sender: NSButton) {
        guard let doc = _document else { return }
        let menu = NSMenu()
        for ty in KSyntaxType.allCases {
            let item = NSMenuItem(title: humanReadableSyntax(ty), action: #selector(didChooseSyntax(_:)), keyEquivalent: "")
            item.target = self
            item.state = (ty == doc.syntaxType) ? .on : .off
            item.representedObject = ty // そのまま
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    private func popUp(_ menu: NSMenu, from anchor: NSView) {
        let pt = NSPoint(x: 0, y: anchor.bounds.height - 2)
        menu.popUp(positioning: nil, at: pt, in: anchor)
    }

    @objc private func didChooseEncoding(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? UInt, let doc = _document else { return }
        let enc = String.Encoding(rawValue: raw)
        if doc.characterCode != enc {
            doc.characterCode = enc
            updateStatusBar()
            doc.updateChangeCount(.changeDone)
        }
    }

    @objc private func didChooseEOL(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let eol = String.ReturnCharacter(rawValue: raw),
              let doc = _document else { return }
        if doc.returnCode != eol {
            doc.returnCode = eol
            updateStatusBar()
            doc.updateChangeCount(.changeDone)
        }
    }

    @objc private func didChooseSyntax(_ item: NSMenuItem) {
        guard let ty = item.representedObject as? KSyntaxType, let doc = _document else { return }
        if doc.syntaxType != ty {
            doc.syntaxType = ty
            let textStorage = doc.textStorage
            textStorage.replaceParser(for: ty)
            updateStatusBar()
        }
    }

    // MARK: - 右側 Popover（Caret / FS / LS）

    @objc private func showCaretPopover(_ sender: NSButton) {
        if _jumpPopover == nil {
            let vc = KJumpPopoverViewController()
            vc.onConfirm = { [weak self] spec in
                guard let self = self else { return }
                guard let activeTextView = activeTextView() else { NSSound.beep(); return }

                // spec を KTextView のパーサへ
                guard let selection = activeTextView.selectString(with: spec) else {
                    NSSound.beep()
                    return
                }

                // 選択を反映（NSRange に変換）
                // let nsRange = NSRange(location: selection.lowerBound, length: selection.count)
                //activeTextView.setSelectedRange(nsRange)// KTextView が NSTextView 互換ならこれでOK
                activeTextView.selectionRange = selection
                activeTextView.scrollSelectionToVisible()

                // ステータス更新 & フォーカス復帰
                self.updateStatusBar()
                self.view.window?.makeFirstResponder(activeTextView)

                // ジャンプは一発で閉じる方が自然（連続調整したいUIではないため）
                self.dismissPopovers()
            }
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentViewController = vc
            _jumpPopover = pop
        }
        _jumpPopover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func showTypographyPopover_ForFontSize(_ sender: NSButton) {
        showTypographyPopover(from: sender, mode: .fontSize)
    }

    @objc private func showTypographyPopover_ForLineSpacing(_ sender: NSButton) {
        showTypographyPopover(from: sender, mode: .lineSpacing)
    }

    private enum TypographyMode { case fontSize, lineSpacing }

    private func showTypographyPopover(from anchor: NSButton, mode: TypographyMode) {
        let vc = KTypographyPopoverViewController(mode: mode == .fontSize ? .fontSize : .lineSpacing)
        vc.onChange = { [weak self] value in
            guard let self else { return }
            switch mode {
            case .lineSpacing:
                guard let tv = self.activeTextView() else { return }
                tv.layoutManager.lineSpacing = CGFloat(value)
                if self.syncOptions, let master = self.activeTextView() {
                    self.textViews.forEach { if $0 !== master { $0.layoutManager.lineSpacing = master.layoutManager.lineSpacing } }
                }
                self.updateStatusBar()
            case .fontSize:
                self.updateStatusBar()
                //self.setFontSize(value)
                //guard let storage = _document?.textStorage else { return }
                if let storage = _document?.textStorage {
                    storage.fontSize = max(5, value)
                    updateStatusBar()
                }
            }
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        _typographyPopover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func dismissPopovers() {
        _jumpPopover?.performClose(nil)
        _typographyPopover?.performClose(nil)
    }

    // MARK: - Split / Merge

    private enum Orientation { case vertical, horizontal }

    private func ensureSecondPane(orientation: Orientation) {
        guard let sv = _splitView, _panes.count == 1, let ts = _document?.textStorage else { return }
        guard let firstContainer = _splitView?.arrangedSubviews.first else { return }
        guard let firstTextView = (firstContainer as? KTextViewContainerView)?.textView else { return }

        sv.isVertical = (orientation == .vertical)

        let second = KTextViewContainerView(frame: sv.bounds, textStorageRef: ts)
        second.translatesAutoresizingMaskIntoConstraints = true
        second.autoresizingMask = [.width, .height]

        _panes.append(second)
        sv.addSubview(second)
        sv.adjustSubviews()

        // 設定同期
        second.textView.loadSettings(from: firstTextView)

        // 半分位置へ
        let mid: CGFloat = sv.isVertical ? sv.bounds.width / 2 : sv.bounds.height / 2
        sv.setPosition(mid, ofDividerAt: 0)

        view.window?.makeFirstResponder(second.textView)
        updateStatusBar()
    }

    private func removeSecondPaneIfExists() {
        guard let sv = _splitView, _panes.count == 2 else { return }
        _panes.removeLast()
        sv.subviews.last?.removeFromSuperview()
        sv.adjustSubviews()
        if let first = _panes.first { view.window?.makeFirstResponder(first.textView) }
        updateStatusBar()
    }

    // MARK: - Wider hit area for divider

    func splitView(_ splitView: NSSplitView,
                   effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        let thick = splitView.dividerThickness
        if splitView.isVertical {
            let pad = max(0, (_dividerHitWidth - thick) * 0.5)
            return drawnRect.insetBy(dx: -pad, dy: 0)
        } else {
            let pad = max(0, (_dividerHitWidth - thick) * 0.5)
            return drawnRect.insetBy(dx: 0, dy: -pad)
        }
    }

    // MARK: - Status helpers

    func updateStatusBar() {
        if let doc = _document {
            _encButton.title    = humanReadableEncoding(doc.characterCode)
            _eolButton.title    = humanReadableEOL(doc.returnCode)
            _syntaxButton.title = humanReadableSyntax(doc.syntaxType)
        } else {
            _encButton.title = ""; _eolButton.title = ""; _syntaxButton.title = ""
        }

        if let textView = activeTextView() {
            let ts = textView.textStorage
            let caret = textView.caretIndex
            let m = ts.lineAndColumNumber(at: caret)

            let totalLineCount = ts.hardLineCount.formatted(.number.locale(.init(identifier: "en_US")))
            let totalCharacterCount = ts.count.formatted(.number.locale(.init(identifier: "en_US")))
            let currentLineNumber = m.line.formatted(.number.locale(.init(identifier: "en_US")))
            let currentLineColumn = m.column.formatted(.number.locale(.init(identifier: "en_US")))
            _caretButton.title = "Line: \(currentLineNumber):\(currentLineColumn)  [ch: \(totalCharacterCount)  ln: \(totalLineCount)]"
        } else {
            _caretButton.title = ""
        }

        if let fs = _document?.textStorage.fontSize {
            _fontSizeButton.title = "FS: " + String(format: "%.1f", fs)
        } else {
            _fontSizeButton.title = "FS: —"
        }

        if let tv = activeTextView() {
            let ls = Double(tv.layoutManager.lineSpacing)
            _lineSpacingButton.title = "LS: " + String(format: "%.2f", ls)
        } else {
            _lineSpacingButton.title = "LS: —"
        }
    }

    private func activeTextView() -> KTextView? {
        guard let window = view.window else { return nil }
        for view in textViews {
            if window.firstResponder === view { return view }
        }
        return _panes.first?.textView
    }

    private func humanReadableEncoding(_ enc: String.Encoding) -> String {
        switch enc {
        case .utf8: return "UTF-8"
        case .utf16, .utf16BigEndian, .utf16LittleEndian: return "UTF-16"
        case .utf32, .utf32BigEndian, .utf32LittleEndian: return "UTF-32"
        case .shiftJIS: return "SJIS"
        case .japaneseEUC: return "EUC"
        case .iso2022JP: return "JIS"
        default: return enc.description
        }
    }
    private func humanReadableEOL(_ rc: String.ReturnCharacter) -> String {
        switch rc {
        case .lf: return "LF"
        case .cr: return "CR"
        case .crlf: return "CRLF"
        }
    }
    private func humanReadableSyntax(_ t: KSyntaxType) -> String {
        switch t {
        case .plain: return "Plain"
        case .ruby:  return "Ruby"
        case .html:  return "HTML"
        default:     return "\(t)"
        }
    }
}

// MARK: - Popover ViewControllers

final class KJumpPopoverViewController: NSViewController {
    var onConfirm: ((String) -> Void)?

    private let _textField = NSTextField(string: "")
    private let _button = NSButton(title: "Go", target: nil, action: nil)

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        _textField.placeholderString = "Line number"
        _textField.translatesAutoresizingMaskIntoConstraints = false
        _textField.action = #selector(didPressEnter(_:))
        _textField.target = self

        _button.target = self
        _button.action = #selector(didTapGo(_:))
        _button.bezelStyle = .rounded
        _button.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(_textField)
        v.addSubview(_button)

        NSLayoutConstraint.activate([
            _textField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            _textField.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            _textField.widthAnchor.constraint(equalToConstant: 120),

            _button.leadingAnchor.constraint(equalTo: _textField.trailingAnchor, constant: 8),
            _button.centerYAnchor.constraint(equalTo: _textField.centerYAnchor),
            _button.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            _textField.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12)
        ])

        view = v
    }

    @objc private func didPressEnter(_ sender: Any?) { confirm() }
    @objc private func didTapGo(_ sender: Any?) { confirm() }

    private func confirm() {
        let spec = _textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { NSSound.beep(); return }
        onConfirm?(spec)
    }
}

final class KTypographyPopoverViewController: NSViewController {
    enum Mode { case fontSize, lineSpacing }
    var onChange: ((Double) -> Void)?

    private let _mode: Mode
    private let _field = NSTextField(string: "")

    init(mode: Mode) {
        _mode = mode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        _field.placeholderString = (_mode == .fontSize) ? "Font Size" : "Line Spacing"
        _field.alignment = .right
        _field.translatesAutoresizingMaskIntoConstraints = false
        _field.target = self
        _field.action = #selector(commit(_:))

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.allowsFloats = true
        _field.formatter = formatter

        v.addSubview(_field)
        NSLayoutConstraint.activate([
            _field.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            _field.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            _field.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            _field.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            _field.widthAnchor.constraint(equalToConstant: 100)
        ])
        view = v
    }

    @objc private func commit(_ sender: Any?) {
        let s = _field.stringValue.trimmingCharacters(in: .whitespaces)
        if let fmt = _field.formatter as? NumberFormatter, let num = fmt.number(from: s) {
            onChange?(num.doubleValue)
        } else if let v = Double(s) {
            onChange?(v)
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - StatusBar Update Hook

@objc protocol KStatusBarUpdateAction {
    @objc func statusBarNeedsUpdate(_ sender: Any?)
}

extension KViewController: KStatusBarUpdateAction {
    @IBAction func statusBarNeedsUpdate(_ sender: Any?) {
        updateStatusBar()
    }
}


