//
//  KViewController.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KViewController: NSViewController, NSUserInterfaceValidations, NSSplitViewDelegate {

    // MARK: - Private properties
    
    private weak var _document: Document?
    private var _splitView: KSplitView?
    private var _panes: [KTextViewContainerView] = []
    private var _needsConstruct: Bool = false
    
    private let _dividerHitWidth: CGFloat = 5.0
    private let _statusBarHeight: CGFloat = 20//26
    private let _statusBarFont: NSFont = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    
    // KViewController 内
    private let _encLabel   = NSTextField(labelWithString: "")
    private let _eolLabel   = NSTextField(labelWithString: "")
    private let _syntaxLabel = NSTextField(labelWithString: "")
    private let _caretLabel = NSTextField(labelWithString: "")

    // コンテナはコードで用意（XIBを使わない前提）
    private let _contentContainer = NSView()
    private let _statusBarView    = NSView()

    // MARK: - Menu actions
    @IBAction func splitVertically(_ sender: Any?)   { ensureSecondPane(orientation: .vertical) }
    @IBAction func splitHorizontally(_ sender: Any?) { ensureSecondPane(orientation: .horizontal) }
    @IBAction func removeSplit(_ sender: Any?)       { removeSecondPaneIfExists() }

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
    
    private func buildStatusBarUI() {
        // 小さめのシステムフォント
        [_encLabel, _eolLabel, _syntaxLabel, _caretLabel].forEach {
            $0.font = _statusBarFont
            $0.lineBreakMode = .byTruncatingTail
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let leftStack = NSStackView(views: [_encLabel, _eolLabel, _syntaxLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [_caretLabel])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        _statusBarView.addSubview(leftStack)
        _statusBarView.addSubview(rightStack)
        
        
        addClick(_encLabel,  #selector(openEncodingMenu(_:)))
        addClick(_eolLabel,  #selector(openEOLMenu(_:)))
        addClick(_syntaxLabel, #selector(openSyntaxMenu(_:)))
        

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: _statusBarView.leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: _statusBarView.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: _statusBarView.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: _statusBarView.centerYAnchor),
        ])
    }
    
    private func addClick(_ view: NSView, _ action: Selector) {
        let gr = NSClickGestureRecognizer(target: self, action: action)
        view.addGestureRecognizer(gr)
        view.toolTip = "Click to change"
    }
    
    // 候補（必要なら Document から差し替え可）
    private let _encodingCandidates: [String.Encoding] = [
        .utf8, .utf16, .utf32, .shiftJIS, .japaneseEUC, .iso2022JP
    ]

    @objc private func openEncodingMenu(_ sender: NSGestureRecognizer) {
        guard let label = sender.view, let doc = _document else { return }
        let menu = NSMenu()
        for enc in _encodingCandidates {
            let item = NSMenuItem(
                title: humanReadableEncoding(enc),
                action: #selector(didChooseEncoding(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = (enc == doc.characterCode) ? .on : .off
            // representedObject に rawValue を入れておくと安全
            item.representedObject = enc.rawValue
            menu.addItem(item)
        }
        popUp(menu, from: label)
    }

    @objc private func openEOLMenu(_ sender: NSGestureRecognizer) {
        guard let label = sender.view, let doc = _document else { return }
        let menu = NSMenu()
        for eol in [String.ReturnCharacter.lf, .crlf, .cr] {
            let title = humanReadableEOL(eol)
            let item = NSMenuItem(title: title, action: #selector(didChooseEOL(_:)), keyEquivalent: "")
            item.target = self
            item.state = (eol == doc.returnCode) ? .on : .off
            item.representedObject = eol.rawValue
            menu.addItem(item)
        }
        popUp(menu, from: label)
    }

    @objc private func openSyntaxMenu(_ sender: NSGestureRecognizer) {
        guard let label = sender.view, let doc = _document else { return }
        let menu = NSMenu()
        for ty in KSyntaxType.allCases {
            let title = humanReadableSyntax(ty)
            let item = NSMenuItem(title: title, action: #selector(didChooseSyntax(_:)), keyEquivalent: "")
            item.target = self
            item.state = (ty == doc.syntaxType) ? .on : .off
            item.representedObject = ty // そのまま持てる
            menu.addItem(item)
        }
        popUp(menu, from: label)
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
        }
    }

    @objc private func didChooseEOL(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let eol = String.ReturnCharacter(rawValue: raw),
              let doc = _document else { return }
        if doc.returnCode != eol {
            doc.returnCode = eol
            updateStatusBar()
        }
    }

    @objc private func didChooseSyntax(_ item: NSMenuItem) {
        guard let ty = item.representedObject as? KSyntaxType,
              let doc = _document else { return }
        if doc.syntaxType != ty {
            doc.syntaxType = ty
            let textStorage = doc.textStorage
            //textStorage.parser = ty.makeParser(storage: textStorage)
            textStorage.replaceParser(for: ty)
            
            updateStatusBar()
        }
    }

    // MARK: - Split / Merge
    private enum Orientation { case vertical, horizontal }

    private func ensureSecondPane(orientation: Orientation) {
        guard let sv = _splitView, _panes.count == 1, let ts = _document?.textStorage else { return }

        sv.isVertical = (orientation == .vertical)

        let second = KTextViewContainerView(frame: sv.bounds, textStorageRef: ts)
        second.translatesAutoresizingMaskIntoConstraints = true
        second.autoresizingMask = [.width, .height]

        _panes.append(second)
        sv.addSubview(second)
        sv.adjustSubviews()

        // 半分位置へ（任意）
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

    // MARK: - Menu validation
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(splitVertically), #selector(splitHorizontally):
            return _panes.count == 1 && _splitView != nil
        case #selector(removeSplit):
            return _panes.count == 2
        default:
            return true
        }
    }
    
    
    
    func updateStatusBar() {
        // Document の状態
        if let doc = _document {
            _encLabel.stringValue   = humanReadableEncoding(doc.characterCode)
            _eolLabel.stringValue   = humanReadableEOL(doc.returnCode)
            _syntaxLabel.stringValue = humanReadableSyntax(doc.syntaxType)
        } else {
            _encLabel.stringValue = ""; _eolLabel.stringValue = ""; _syntaxLabel.stringValue = ""
        }

        // カーソル位置（アクティブペイン）
        if let textView = activeTextView() {
            let textStorage = textView.textStorage
            
            let caret = textView.caretIndex
            let matrix = textStorage.lineAndColumNumber(at: caret)
            
            let totalLineCount = textStorage.hardLineCount.formatted(.number.locale(.init(identifier: "en_US")))
            let totalCharacterCount = textStorage.count.formatted(.number.locale(.init(identifier: "en_US")))
            let currentLineNumber = matrix.line.formatted(.number.locale(.init(identifier: "en_US")))
            let currentLineColumn = matrix.column.formatted(.number.locale(.init(identifier: "en_US")))
            
            //_caretLabel.stringValue = "Ln \(line), Col \(col)"
            _caretLabel.stringValue = "Line: \(currentLineNumber):\(currentLineColumn)  [ch: \(totalCharacterCount)  ln: \(totalLineCount)]"
        } else {
            _caretLabel.stringValue = ""
        }
    }

    private func activeTextView() -> KTextView? {
        if let tv = view.window?.firstResponder as? KTextView { return tv }
        return _panes.first?.textView
    }

    private func humanReadableEncoding(_ enc: String.Encoding) -> String {
        switch enc {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf32: return "UTF-32"
        case .shiftJIS: return "Shift_JIS"
        case .japaneseEUC: return "EUC-JP"
        case .iso2022JP: return "ISO-2022-JP"
        default: return enc.description // 最低限のフォールバック
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
        // お使いの定義に合わせて適宜
        switch t {
        case .plain: return "Plain"
        case .ruby:  return "Ruby"
        // 他の種類も必要に応じて
        default:     return "\(t)"
        }
    }

    
}

@objc protocol KStatusBarUpdateAction {
    @objc func statusBarNeedsUpdate(_ sender: Any?)
}

extension KViewController: KStatusBarUpdateAction {
    @IBAction func statusBarNeedsUpdate(_ sender: Any?) {
        updateStatusBar()
    }
}

/*import AppKit

final class KViewController: NSViewController, NSUserInterfaceValidations, NSSplitViewDelegate {

    private let _dividerHitWidth: CGFloat = 5.0
    private weak var _document: Document?
    private var _splitView: KSplitView!
    private var _panes: [KTextViewContainerView] = []
    private var _needConstruct:Bool = false

    @IBAction func splitVertically(_ sender: Any?)   { _ensureSecondPane(orientation: .vertical) }
    @IBAction func splitHorizontally(_ sender: Any?) { _ensureSecondPane(orientation: .horizontal) }
    @IBAction func removeSplit(_ sender: Any?)       { _removeSecondPaneIfExists() }
    
    private var _contentContainer = NSView()
    private var _statusBarView = NSView()
    
    var document: Document? {
        get { _document }
        set {
            guard _document == nil, let doc = newValue else { log("newValue is not Document",from:self); return }
            _document = doc
            //constructViews()
            _needConstruct = true
        }
    }
    

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        if _needConstruct, document != nil {
            constructViews()
            _needConstruct = false
        }
    }

    // メニューの有効/無効
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(splitVertically(_:)), #selector(splitHorizontally(_:)):
            return _panes.count == 1
        case #selector(removeSplit(_:)):
            return _panes.count > 1
        default:
            return true
        }
    }
    /*
    private func constructViews() {
        let sv = KSplitView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.dividerStyle = .thin
        sv.isVertical = true
        view.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sv.topAnchor.constraint(equalTo: view.topAnchor),
            sv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        _splitView = sv
        
        guard let textStorage = document?.textStorage else { log("document is nil.",from:self); return }

        // 1枚目（共有 textStorage）
        let first = KTextViewContainerView(frame: _splitView.bounds, textStorageRef: textStorage)
        first.translatesAutoresizingMaskIntoConstraints = true     // ★ Auto Layout を切る
        first.autoresizingMask = [.width, .height]                 // ★ フレーム追従
        _panes = [first]
        _splitView.addSubview(first)
        _splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        _splitView.delegate = self
        _splitView.adjustSubviews()
    }*/
    // 下にステータスバー、上にコンテンツ
        private func buildContainers() {
            contentContainer.translatesAutoresizingMaskIntoConstraints = false
            statusBarView.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(contentContainer)
            view.addSubview(statusBarView)

            let barHeight: CGFloat = 26

            NSLayoutConstraint.activate([
                statusBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                statusBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                statusBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                statusBarView.heightAnchor.constraint(equalToConstant: barHeight),

                contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
                contentContainer.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
            ])

            // 見た目（薄い区切り線と背景）
            statusBarView.wantsLayer = true
            statusBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

            let sep = NSBox()
            sep.boxType = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            statusBarView.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.topAnchor.constraint(equalTo: statusBarView.topAnchor),
                sep.leadingAnchor.constraint(equalTo: statusBarView.leadingAnchor),
                sep.trailingAnchor.constraint(equalTo: statusBarView.trailingAnchor)
            ])

            // ラベルの土台（必要に応じて置き換え/追加）
            let encodingLabel = NSTextField(labelWithString: "UTF-8")
            let eolLabel      = NSTextField(labelWithString: "LF")
            let lineLabel     = NSTextField(labelWithString: "line: 1")

            [encodingLabel, eolLabel, lineLabel].forEach {
                $0.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }

            let leftStack = NSStackView(views: [encodingLabel, eolLabel])
            leftStack.orientation = .horizontal
            leftStack.spacing = 12
            leftStack.translatesAutoresizingMaskIntoConstraints = false

            let rightStack = NSStackView(views: [lineLabel])
            rightStack.orientation = .horizontal
            rightStack.translatesAutoresizingMaskIntoConstraints = false

            statusBarView.addSubview(leftStack)
            statusBarView.addSubview(rightStack)

            NSLayoutConstraint.activate([
                leftStack.leadingAnchor.constraint(equalTo: statusBarView.leadingAnchor, constant: 8),
                leftStack.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

                rightStack.trailingAnchor.constraint(equalTo: statusBarView.trailingAnchor, constant: -8),
                rightStack.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),
            ])

            // ← 後で Document の値に合わせて文言を更新すれば完成
        }

        // ここは contentContainer に貼るだけに変更
        private func constructViews() {
            guard _splitView == nil else { return }
            guard let textStorage = document?.textStorage else { return }

            let sv = KSplitView()
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.dividerStyle = .thin
            sv.isVertical = true

            contentContainer.addSubview(sv)
            NSLayoutConstraint.activate([
                sv.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                sv.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                sv.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
            _splitView = sv

            let first = KTextViewContainerView(frame: .zero, textStorageRef: textStorage)
            first.translatesAutoresizingMaskIntoConstraints = true
            first.autoresizingMask = [.width, .height]
            _panes = [first]
            _splitView.addSubview(first)
            _splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            _splitView.delegate = self
            _splitView.adjustSubviews()
        }

    // MARK: - 分割操作
    private func _ensureSecondPane(orientation: NSUserInterfaceLayoutOrientation) {
        _splitView.isVertical = (orientation == .vertical)

        if _panes.count > 1 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self._splitView.isVertical {
                    self._splitView.setPosition(self._splitView.bounds.width / 2, ofDividerAt: 0)
                } else {
                    self._splitView.setPosition(self._splitView.bounds.height / 2, ofDividerAt: 0)
                }
            }
            return
        }
        
        guard let textStorage = document?.textStorage else { log("document is nil.",from:self); return }


        let second = KTextViewContainerView(frame: _splitView.bounds, textStorageRef: textStorage)
        second.translatesAutoresizingMaskIntoConstraints = true    // ★ ここも同様
        second.autoresizingMask = [.width, .height]
        _panes.append(second)
        _splitView.addSubview(second)
        _splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        _splitView.adjustSubviews()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self._splitView.isVertical {
                self._splitView.setPosition(self._splitView.bounds.width / 2, ofDividerAt: 0)
            } else {
                self._splitView.setPosition(self._splitView.bounds.height / 2, ofDividerAt: 0)
            }
        }
        _panes.forEach { $0.syncFocusOverlayNow() }
    }

    private func _removeSecondPaneIfExists() {
        guard _panes.count > 1 else { return }
        let second = _panes.removeLast()
        second.removeFromSuperview()
        _splitView.adjustSubviews()
        
        view.window?.makeFirstResponder(_panes[0].textView)
    }

    private func _setHalfSplit() {
        if _splitView.isVertical {
            _splitView.setPosition(_splitView.bounds.width / 2, ofDividerAt: 0)
        } else {
            _splitView.setPosition(_splitView.bounds.height / 2, ofDividerAt: 0)
        }
    }

    // MARK: - NSSplitViewDelegate（見た目1ptのまま、当たり判定だけ _dividerHitWidth）
    func splitView(_ splitView: NSSplitView,
                   effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        let hit = _dividerHitWidth
        if splitView.isVertical {
            let midX = drawnRect.midX
            return NSRect(x: midX - hit/2, y: 0, width: hit, height: splitView.bounds.height)
        } else {
            let midY = drawnRect.midY
            return NSRect(x: 0, y: midY - hit/2, width: splitView.bounds.width, height: hit)
        }
    }

    // “追加分”だけ返す方も実装しておく（個体差対策）
    func splitView(_ splitView: NSSplitView,
                   additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        let base: CGFloat = 1.0                      // サブクラスで1pt固定
        let extra = max(0, _dividerHitWidth - base)  // 追加ぶんのみ
        guard dividerIndex < splitView.subviews.count - 1 else { return .zero }
        let a = splitView.subviews[dividerIndex]
        if splitView.isVertical {
            let x = a.frame.maxX - extra/2
            return NSRect(x: x, y: 0, width: extra, height: splitView.bounds.height)
        } else {
            let y = a.frame.maxY - extra/2
            return NSRect(x: 0, y: y, width: splitView.bounds.width, height: extra)
        }
    }
}

/*
import Cocoa

final class KViewController: NSViewController {

    private var textViewContainerView: KTextViewContainerView!

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        //print("現在の関数名：\(#function)")
        // KTextViewContainerView の作成
        textViewContainerView = KTextViewContainerView()
        
        // 起動直後に生成されるウインドウのタイトルバーが白く塗り潰される問題を解決。
        // view.window?.titlebarAppearsTransparent = false

        // Auto Layout を使用
        textViewContainerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textViewContainerView)

        NSLayoutConstraint.activate([
            textViewContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textViewContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textViewContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            textViewContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        Swift.print("KViewController.viewDidLoad")
        
        
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        Swift.print("KViewController.viewDidAppear") 
    }
}*/*/
