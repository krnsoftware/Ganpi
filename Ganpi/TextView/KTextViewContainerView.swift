//
//  KTextViewContainerView.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KTextViewContainerView: NSView {

    // MARK: - Subviews

    private let _scrollView = NSScrollView()
    private let _textView: KTextView

    private var _overlay: KFocusOverlayView?

    // MARK: - Accessor

    var textView: KTextView {
        _textView
    }
    
    var scrollView: NSScrollView {
        _scrollView
    }

    // MARK: - Init

    override init(frame: NSRect) {
        
        let textStorageRef = KTextStorage()
        let layoutManager = KLayoutManager(textStorageRef: textStorageRef)
        _textView = KTextView(
            frame: .zero,
            textStorageRef: textStorageRef,
            layoutManager: layoutManager
        )
        
        super.init(frame: frame)
                
        setup()
        
    }
    
    init(frame: NSRect, textStorageRef: KTextStorageProtocol) {
        //let layoutManager = KLayoutManager(textStorageRef: textStorageRef)
        
        _textView = KTextView(frame: .zero, textStorageRef: textStorageRef)
        
        super.init(frame: frame)
        
        setup()
    }

    required init?(coder: NSCoder) {
        let textStorageRef = KTextStorage()
        let layoutManager = KLayoutManager(textStorageRef: textStorageRef)
        _textView = KTextView(
            frame: .zero,
            textStorageRef: textStorageRef,
            layoutManager: layoutManager
        )
        
        super.init(coder: coder)
        setup()
    }
    
    private func _installOverlayIfNeeded() {
        guard _overlay == nil else { return }
        let clip = _scrollView.contentView

        let ov = KFocusOverlayView()
        ov.translatesAutoresizingMaskIntoConstraints = false
        ov.isHidden = true

        // ★ コンテナ（self）に追加し、ScrollView の“上”に重ねる
        addSubview(ov, positioned: .above, relativeTo: _scrollView)

        // ★ オーバーレイの四辺を「clip の枠」にぴったり合わせる
        NSLayoutConstraint.activate([
            ov.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            ov.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ov.topAnchor.constraint(equalTo: clip.topAnchor),
            ov.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])

        _overlay = ov
    }

    // どこか確実に通るフックで一度だけインストール（同期）
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _installOverlayIfNeeded()
        syncFocusOverlayNow()
    }
    
    override func layout() {
        super.layout()
        _installOverlayIfNeeded()
        syncFocusOverlayNow()
    }

    // TextView からの通知で表示だけ切替（分割時のみ）
    func setActiveEditor(_ active: Bool) {
        let multiple = ((superview as? NSSplitView)?.subviews.count ?? 1) > 1
        _overlay?.showsFocus = active && multiple
    }
    
    func syncFocusOverlayNow() {
        _installOverlayIfNeeded()  // 念のため（多重追加しない実装のはず）
        let multiple = ((superview as? NSSplitView)?.subviews.count ?? 1) > 1
        let isActive = (window?.firstResponder === _textView)
        _overlay?.showsFocus = multiple && isActive
        _overlay?.needsDisplay = true
    }
    
    

    // MARK: - Setup

    private func setup() {
        _scrollView.hasVerticalScroller = true
        _scrollView.hasHorizontalScroller = true
        _scrollView.documentView = _textView
        _scrollView.translatesAutoresizingMaskIntoConstraints = false
        _textView.updateFrameSizeToFitContent()
        _textView.containerView = self
        
        // test
       
        // KTextViewContainerView のスクロール設定内
/*
        if #available(macOS 11.0, *) {
            _scrollView.automaticallyAdjustsContentInsets = false
        }

        // ← ここを .zero ではなく明示初期化に
        if _scrollView.responds(to: #selector(setter: NSScrollView.contentInsets)) {
            _scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        if _scrollView.responds(to: #selector(setter: NSScrollView.scrollerInsets)) {
            _scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        // end
*/
        addSubview(_scrollView)

        NSLayoutConstraint.activate([
            _scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            _scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            _scrollView.topAnchor.constraint(equalTo: topAnchor),
            _scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
