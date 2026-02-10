//
//  KViewController.swift
//  Ganpi
//
//  Created by KARINO Masatugu
//

import Cocoa
import Carbon

final class KViewController: NSViewController, NSUserInterfaceValidations, NSSplitViewDelegate {
    
    // MARK: - Structures
    
    private final class OutlineNode {
        let title: String
        let image: NSImage?
        let range: Range<Int>?
        var children: [OutlineNode] = []

        init(title: String, image: NSImage?, range: Range<Int>?) {
            self.title = title
            self.image = image
            self.range = range
        }
    }

    // MARK: - Private properties

    private weak var _document: Document?
    private var _splitView: KSplitView?
    private var _panes: [KTextViewContainerView] = []
    private var _needsConstruct: Bool = false
    private var _syncOptions: Bool = true

    private let _dividerHitWidth: CGFloat = 5.0
    private let _statusBarHeight: CGFloat = 20.0
    private let _statusBarFont: NSFont = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private let _statusBarFontBold: NSFont = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)

    // 行間の粗調整ステップ
    private let _lineSpacingStep: CGFloat = 1.0

    // コンテナ
    private let _contentContainer = NSView()
    private let _statusBarView    = NSView()

    // Status Bar（全面ボタン化）
    private let _encButton    = NSButton(title: "", target: nil, action: nil)
    private let _eolButton    = NSButton(title: "", target: nil, action: nil)
    private let _syntaxButton = NSButton(title: "", target: nil, action: nil)
    private let _funcMenuButton = NSButton(title: "", target: nil, action: nil)
    private let _editModeButton = NSButton(title: "", target: nil, action: nil)
    private let _caretButton  = NSButton(title: "", target: nil, action: nil)
    private let _fontSizeButton   = NSButton(title: "", target: nil, action: nil)   // "FS: <val>"
    private let _lineSpacingButton = NSButton(title: "", target: nil, action: nil)  // "LS: <val>"

    // Popovers
    private var _jumpPopover: NSPopover?
    private var _typographyPopover: NSPopover?

    // MARK: - Menu actions and others.

    // SplitView
    @IBAction func splitVertically(_ sender: Any?)   { ensureSecondPane(orientation: .vertical) }
    @IBAction func splitHorizontally(_ sender: Any?) { ensureSecondPane(orientation: .horizontal) }
    @IBAction func removeSplit(_ sender: Any?)       { removeSecondPaneIfExists() }
    
    // 現在アクティブなTextViewの次(右または下)のTextViewをフォーカスする。
    @IBAction func focusForwardTextView(_ sender: Any?) {
        focusAdjoiningTextView(for: .forward)
    }
    
    @IBAction func focusBackwardTextView(_ sender: Any?) {
        focusAdjoiningTextView(for: .backward)
    }
    
    @IBAction func setDividerCenter(_ sender: Any?) {
        guard let sv = _splitView else { log("#01",from:self); return }
        let mid = sv.isVertical ? sv.bounds.width / 2 : sv.bounds.height / 2
        sv.setPosition(mid, ofDividerAt: 0)
    }
    
    @IBAction func setDividerForward(_ sender: Any?) {
        guard let sv = _splitView else { log("#01",from:self); return }
        let current = sv.isVertical ? sv.subviews[0].frame.width : sv.subviews[0].frame.height
        let svMax = sv.isVertical ? sv.frame.width : sv.frame.height
        let newSplit = min(svMax - 5.0, current + 20.0)
        sv.setPosition(newSplit, ofDividerAt: 0)
    }
    
    @IBAction func setDividerBackward(_ sender: Any?) {
        guard let sv = _splitView else { log("#01",from:self); return }
        let current = sv.isVertical ? sv.subviews[0].frame.width : sv.subviews[0].frame.height
        let newSplit = max(5.0, current - 20.0)
        sv.setPosition(newSplit, ofDividerAt: 0)
    }

    
    // Settings
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
    
    // Edit mode
    @IBAction func setEditModeToNormal(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        activeTextView.editMode = .normal
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.editMode = .normal } }
    }
    
    @IBAction func setEditModeToEdit(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        activeTextView.editMode = .edit
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.editMode = .edit } }
    }
    
    @IBAction func lineWrapAlignment(_ sender: Any?) {
        guard let activeTextView = activeTextView() else { log("activeTextView is nil.",from:self); return }
        guard let menuItem = sender as? NSMenuItem else { log("1"); return }
        guard let menuTag  = KWrapLineOffsetType(rawValue: menuItem.tag) else { log("2"); return }
        activeTextView.layoutManager.wrapLineOffsetType = menuTag
        if !syncOptions { return }
        textViews.forEach { if $0 !== activeTextView { $0.layoutManager.wrapLineOffsetType = menuTag } }
    }

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
    
    @IBAction func showFontPanel(_ sender: Any?) {
        let panel = NSFontPanel.shared
        guard let font = document?.textStorage.baseFont else { log("document is nil.",from:self); return }
        panel.setPanelFont(font, isMultiple: false)
        panel.orderFront(self)
    }
    
    @IBAction func openFunctionMenu(_ sender: Any?) {
        openFunctionMenuFromButton(_funcMenuButton)
    }
    
    @IBAction func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { log("Font manager is nil.", from:self); return }
        guard let storage = document?.textStorage else { log("document is nil.", from:self); return }
        let panelFont = manager.convert(storage.baseFont)
        let isOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOption {
            guard let textView = activeTextView() else { log("activeTextView() is nil.", from:self); return }
            let selection = textView.selectionRange
            let string = "\(panelFont.fontName) \(panelFont.pointSize)"
            storage.replaceString(in: selection, with: string)
            textView.selectionRange = selection.lowerBound..<selection.lowerBound + string.count
        } else {
            storage.baseFont = panelFont
            updateStatusBar()
        }
    }
    
    @IBAction func setBaseFontToMonoSpaceSystemFont(_ sender: Any?) {
        guard let storage = document?.textStorage else { log("document is nil.", from:self); return }
        
        storage.baseFont = NSFont.monospacedSystemFont(ofSize: storage.fontSize, weight: .regular)
    }


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
        case #selector(lineWrapAlignment(_:)):
            guard let menuItem = item as? NSMenuItem else { log("#1"); return true }
            guard let menuTag = KWrapLineOffsetType(rawValue: menuItem.tag) else { log("#2"); return true }
            menuItem.state = menuTag == textView.layoutManager.wrapLineOffsetType ? .on : .off
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
        let buttons = [_encButton, _eolButton, _syntaxButton, _caretButton, _fontSizeButton, _lineSpacingButton, _editModeButton, _funcMenuButton]
        buttons.forEach {
            $0.font = _statusBarFont
            $0.isBordered = false
            $0.bezelStyle = .inline
            $0.setButtonType(.momentaryPushIn)
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.lineBreakMode = .byTruncatingTail
            $0.contentTintColor = .labelColor
        }
        
        // 潰れないように。
        [_encButton, _eolButton, _syntaxButton, _editModeButton].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        // よく縮むように。
        _funcMenuButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        _funcMenuButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        _funcMenuButton.contentTintColor = .secondaryLabelColor
        //_funcMenuButton.contentInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        
        // 左：Encoding / EOL / Syntax（クリックでメニュー）
        _encButton.target = self;    _encButton.action = #selector(openEncodingMenuFromButton(_:))
        _eolButton.target = self;    _eolButton.action = #selector(openEOLMenuFromButton(_:))
        _syntaxButton.target = self; _syntaxButton.action = #selector(openSyntaxMenuFromButton(_:))
        _editModeButton.target = self; _editModeButton.action = #selector(toggleEditModeFromButton(_:))
        _funcMenuButton.target = self; _funcMenuButton.action = #selector(openFunctionMenuFromButton(_:))
        
        // Function menu: right click / ctrl+click => sorted
        let rightClick = NSClickGestureRecognizer(target: self, action: #selector(openSortedFunctionMenuFromButton(_:)))
        rightClick.buttonMask = 0x2
        _funcMenuButton.addGestureRecognizer(rightClick)

        // 右：Caret（行ジャンプ）/ FS / LS（ポップオーバ）
        _caretButton.target = self;        _caretButton.action = #selector(showCaretPopover(_:))
        _fontSizeButton.target = self;     _fontSizeButton.action = #selector(showTypographyPopover_ForFontSize(_:))
        _lineSpacingButton.target = self;  _lineSpacingButton.action = #selector(showTypographyPopover_ForLineSpacing(_:))

        let leftStack = NSStackView(views: [_encButton, _eolButton, _syntaxButton, _editModeButton, _funcMenuButton])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 4
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [_caretButton, _fontSizeButton, _lineSpacingButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 4
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        _statusBarView.addSubview(leftStack)
        _statusBarView.addSubview(rightStack)
        
        // ---- レイアウト優先度（右を死守・左が縮む）----
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: _statusBarView.leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: _statusBarView.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: _statusBarView.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: _statusBarView.centerYAnchor),
            
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),
        ])
    }

 

    // MARK: - Encoding / EOL / Syntax（NSMenuをボタンから）
    
    @objc private func openEncodingMenuFromButton(_ sender: NSButton) {
        guard let doc = _document else { return }
        let menu = NSMenu()
        for enc in KTextEncoding.allCases {
            let item = NSMenuItem(title: enc.string, action: #selector(didChooseEncoding(_:)), keyEquivalent: "")
            item.target = self
            item.state = (enc == doc.characterCode) ? .on : .off
            item.representedObject = enc
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    @objc private func openEOLMenuFromButton(_ sender: NSButton) {
        guard let doc = _document else { return }
        let menu = NSMenu()
        for eol in String.ReturnCharacter.allCases {
            let item = NSMenuItem(title: eol.string, action: #selector(didChooseEOL(_:)), keyEquivalent: "")
            item.target = self
            item.state = (eol == doc.returnCode) ? .on : .off
            item.representedObject = eol
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    @objc private func openSyntaxMenuFromButton(_ sender: NSButton) {
        guard let doc = _document else { return }
        let menu = NSMenu()
        for ty in KSyntaxType.allCases {
            let item = NSMenuItem(title: ty.string, action: #selector(didChooseSyntax(_:)), keyEquivalent: "")
            item.target = self
            item.state = (ty == doc.syntaxType) ? .on : .off
            item.representedObject = ty
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }
    
    @IBAction func openSortedFunctionMenu(_ sender: Any?) {
        presentFunctionMenu(order: .sorted, from: _funcMenuButton)
    }

    @objc private func openSortedFunctionMenuFromButton(_ sender: Any?) {
        presentFunctionMenu(order: .sorted, from: _funcMenuButton)
    }

    @objc private func openFunctionMenuFromButton(_ sender: NSButton) {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown,
           event.modifierFlags.contains(.control) {
            presentFunctionMenu(order: .sorted, from: sender)
            return
        }
        presentFunctionMenu(order: .documentOrder, from: sender)
    }

    private enum KFunctionMenuOrder {
        case documentOrder
        case sorted
    }

    private func presentFunctionMenu(order: KFunctionMenuOrder, from anchor: NSView) {
        guard let doc = _document else { return }
        guard let textView = activeTextView() else { return }

        let menu = makeFunctionMenu(document: doc, textView: textView, order: order)
        popUp(menu, from: anchor)
    }

    private func makeFunctionMenu(document doc: Document, textView: KTextView, order: KFunctionMenuOrder) -> NSMenu {
        let parser = doc.textStorage.parser
        let outlineItems = parser.outline(in: nil)

        let menu = NSMenu()

        // 先頭に 1 行だけヒント（常設）
        let hint = NSMenuItem(title: "Option: Jump to group", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        func makeTitle(for item: KOutlineItem) -> String {
            // 表示からは # / . を外す（キーボード選択の邪魔になるため）
            return doc.textStorage.string(in: item.nameRange)
        }

        func makeImage(for item: KOutlineItem) -> NSImage? {
            switch item.kind {
            case .class:
                return KOutlineBadgeFactory.shared.classBadge()
            case .module:
                return KOutlineBadgeFactory.shared.moduleBadge()
            case .method:
                return KOutlineBadgeFactory.shared.methodBadge(isSingleton: item.isSingleton)
            case .heading:
                return KOutlineBadgeFactory.shared.headingBadge()
            }
        }

        // outline の level は言語によって意味が違い得るので、ここでメニュー用の深さに正規化する。
        func semanticLevel(for item: KOutlineItem) -> Int {
            if item.kind == .heading {
                return max(1, item.level)
            }
            return max(1, item.level + 1)
        }

        let root = OutlineNode(title: "", image: nil, range: nil)
        var stack: [(level: Int, node: OutlineNode)] = [(0, root)]

        for item in outlineItems {
            let title = makeTitle(for: item)
            let image = makeImage(for: item)
            var level = semanticLevel(for: item)
            if level < 1 { level = 1 }

            while let last = stack.last, last.level >= level {
                stack.removeLast()
            }

            let parentLevel = stack.last?.level ?? 0
            if level > parentLevel + 1 {
                if item.kind == .heading {
                    for missing in (parentLevel + 1)..<level {
                        let dummy = OutlineNode(title: "-", image: nil, range: nil)
                        stack.last!.node.children.append(dummy)
                        stack.append((missing, dummy))
                    }
                } else {
                    level = parentLevel + 1
                }
            }

            let node = OutlineNode(title: title, image: image, range: item.nameRange)
            stack.last!.node.children.append(node)
            stack.append((level, node))
        }

        if order == .sorted {
            var children = root.children
            sortOutlineNodesRecursively(&children)
            root.children = children
        }

        buildMenu(from: root.children, into: menu, textView: textView)
        return menu
    }

    private func sortOutlineNodesRecursively(_ nodes: inout [OutlineNode]) {
        nodes.sort {
            let aDummy = ($0.title == "-")
            let bDummy = ($1.title == "-")
            if aDummy != bDummy { return bDummy } // dummy は後ろ
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        for i in nodes.indices {
            if !nodes[i].children.isEmpty {
                var children = nodes[i].children
                sortOutlineNodesRecursively(&children)
                nodes[i].children = children
            }
        }
    }

    private func buildMenu(from nodes: [OutlineNode], into targetMenu: NSMenu, textView: KTextView) {
        for node in nodes {
            if node.children.isEmpty {
                let leaf = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                leaf.image = node.image
                if let range = node.range {
                    leaf.action = #selector(textView.selectRange(_:))
                    leaf.representedObject = range
                }
                targetMenu.addItem(leaf)
                continue
            }

            // container（通常はサブメニューを開く）
            let sub = NSMenu()
            let parent = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
            parent.image = node.image
            parent.submenu = sub
            targetMenu.addItem(parent)

            // 親を選択できるように：Jump to をサブに置かず、Alternate を同階層に追加
            if let range = node.range {
                let alt = NSMenuItem(title: node.title, action: #selector(textView.selectRange(_:)), keyEquivalent: "")
                alt.image = node.image
                alt.representedObject = range
                alt.isAlternate = true
                alt.keyEquivalentModifierMask = [.option]
                targetMenu.addItem(alt)
            }

            buildMenu(from: node.children, into: sub, textView: textView)
        }
    }


    
    @objc private func toggleEditModeFromButton(_ sender: NSButton) {
        guard let textView = activeTextView() else { log("activeTextView() is nil.", from: self); return }
        let mode = textView.editMode
        if textView.completion.isInCompletionMode { textView.completion.isInCompletionMode = false }
        textView.editMode = mode == .normal ? .edit : .normal
        updateStatusBar()
    }

    private func popUp(_ menu: NSMenu, from anchor: NSView) {
        let pt = NSPoint(x: 0, y: anchor.bounds.height - 2)
        menu.popUp(positioning: nil, at: pt, in: anchor)
    }

    @objc private func didChooseEncoding(_ item: NSMenuItem) {
        guard let enc = item.representedObject as? KTextEncoding, let doc = _document else { return }
        if doc.characterCode != enc {
            doc.characterCode = enc
            updateStatusBar()
            document?.updateChangeCount(.changeDone)
        }
        
    }

    @objc private func didChooseEOL(_ item: NSMenuItem) {
        //guard let raw = item.representedObject as? String,
        guard let eol = item.representedObject as? String.ReturnCharacter,
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
                guard let activeTextView = activeTextView() else { log("#01"); NSSound.beep(); return }

                // spec を KTextView のパーサへ
                guard let selection = activeTextView.selectString(with: spec) else {
                    log("#02"); NSSound.beep()
                    return
                }

                // 選択を反映（NSRange に変換）
                activeTextView.selectionRange = selection
                activeTextView.centerSelectionInVisibleArea(nil)

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
        
        switchToASCIIInputSource()
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
    
    
    // IMを欧文モードに変更する。
    private func switchToASCIIInputSource() {
        let properties = [
            kTISPropertyInputSourceID: "com.apple.keylayout.ABC" as CFString
        ] as CFDictionary
        
        guard let list = TISCreateInputSourceList(properties, false)?
            .takeRetainedValue() as? [TISInputSource],
              let source = list.first
        else { return }
        
        TISSelectInputSource(source)
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

        // 設定同期。adjustSubviews()の前でないとwrapLineOffsetTypeの設定が反映されない。
        second.textView.loadSettings(from: firstTextView)
        
        _panes.append(second)
        sv.addSubview(second)
        sv.adjustSubviews()

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
    
    private func focusAdjoiningTextView(for direction: KDirection) {
        if _panes.count <= 1 { return }
        for (i, textView) in textViews.enumerated() {
            if textView === view.window?.firstResponder {
                view.window?.makeFirstResponder( textViews[(i + direction.rawValue + textViews.count) % textViews.count])
                return
            }
        }
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
            _encButton.title = doc.characterCode.string
            _eolButton.title    = doc.returnCode.string
            _syntaxButton.title = doc.syntaxType.string
        } else {
            _encButton.title = ""; _eolButton.title = ""; _syntaxButton.title = ""
        }

        if let textView = activeTextView() {
            let ts = textView.textStorage
            let caret = textView.caretIndex

            let m = ts.lineAndColumnNumber(at: caret)

            let totalLineCount = ts.hardLineCount.formatted(.number.locale(.init(identifier: "en_US")))
            let totalCharacterCount = ts.count.formatted(.number.locale(.init(identifier: "en_US")))
            let currentLineNumber = m.line.formatted(.number.locale(.init(identifier: "en_US")))
            let currentLineColumn = m.column.formatted(.number.locale(.init(identifier: "en_US")))
            _caretButton.title = "Line: \(currentLineNumber):\(currentLineColumn)  [ch:\(totalCharacterCount) ln:\(totalLineCount)]"

            _editModeButton.wantsLayer = true
            _editModeButton.isBordered = false
            _editModeButton.layer?.masksToBounds = true
            let bgGray = NSColor.windowBackgroundColor.blended(withFraction: 0.5, of: .black) ?? .darkGray
            _editModeButton.layer?.backgroundColor = bgGray.cgColor
            updateEditModeButton(textView)
            _editModeButton.sizeToFit()
            _editModeButton.layoutSubtreeIfNeeded()
            let height = max(_editModeButton.bounds.height, 14)
            _editModeButton.layer?.cornerRadius = height / 4

            let parser = textView.textStorage.parser
            let ctx = parser.currentContext(at: caret)

            let title: String = {
                if let o = ctx.outer, let i = ctx.inner { return o + i }
                if let i = ctx.inner { return i }
                if let o = ctx.outer { return o }
                return "Out of range"
            }()

            _funcMenuButton.title = title
            _funcMenuButton.toolTip = title

        } else {
            _caretButton.title = ""
            _editModeButton.title = ""
            _funcMenuButton.title = ""
            _funcMenuButton.toolTip = nil
        }

        if let fs = _document?.textStorage.fontSize {
            _fontSizeButton.title = "FS:" + String(format: "%.1f", fs)
        } else {
            _fontSizeButton.title = "FS:—"
        }

        if let tv = activeTextView() {
            let ls = Double(tv.layoutManager.lineSpacing)
            _lineSpacingButton.title = "LS:" + String(format: "%.1f", ls)
        } else {
            _lineSpacingButton.title = "LS:—"
        }
    }

    
    private func updateEditModeButton(_ textView: KTextView) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        //let accent = NSColor.controlAccentColor
        let textColor:NSColor
        let char: String
        if textView.completion.isInCompletionMode {
            char = "C"
            textColor = NSColor(hexString: "#FFC786") ?? NSColor.orange
        } else if textView.editMode == .normal {
            char = "N"
            textColor = NSColor.white
        } else  {
            char = "E"
            textColor = NSColor(hexString: "#FFB7BB") ?? NSColor.red
        }
        //
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        _editModeButton.attributedTitle = NSAttributedString(string: char, attributes: attrs)
        _editModeButton.attributedAlternateTitle = _editModeButton.attributedTitle
        
    }

    private func activeTextView() -> KTextView? {
        guard let window = view.window else { return nil }
        for view in textViews {
            if window.firstResponder === view { return view }
        }
        return _panes.first?.textView
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
        guard !spec.isEmpty else { log("no text."); return }
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
            log("no number.")
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


