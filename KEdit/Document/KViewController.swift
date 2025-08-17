//
//  KViewController.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
import AppKit

final class KViewController: NSViewController, NSUserInterfaceValidations, NSSplitViewDelegate {

    private let _dividerHitWidth: CGFloat = 5.0
    private weak var _document: Document?
    private var _splitView: KSplitView!
    private var _panes: [KTextViewContainerView] = []
    private var _needConstruct:Bool = false

    @IBAction func splitVertically(_ sender: Any?)   { _ensureSecondPane(orientation: .vertical) }
    @IBAction func splitHorizontally(_ sender: Any?) { _ensureSecondPane(orientation: .horizontal) }
    @IBAction func removeSplit(_ sender: Any?)       { _removeSecondPaneIfExists() }
    
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
}*/
