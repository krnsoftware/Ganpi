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
    
    private var _completionMenuView: KCompletionMenuView?

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
    
    private func installOverlayIfNeeded() {
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
        installOverlayIfNeeded()
        syncFocusOverlayNow()
    }
    
    override func layout() {
        super.layout()
        installOverlayIfNeeded()
        syncFocusOverlayNow()
    }

    // TextView からの通知で表示だけ切替（分割時のみ）
    func setActiveEditor(_ active: Bool) {
        let multiple = ((superview as? NSSplitView)?.subviews.count ?? 1) > 1
        _overlay?.showsFocus = active && multiple
    }
    
    func syncFocusOverlayNow() {
        installOverlayIfNeeded()  // 念のため（多重追加しない実装のはず）
        let multiple = ((superview as? NSSplitView)?.subviews.count ?? 1) > 1
        let isActive = (window?.firstResponder === _textView)
        _overlay?.showsFocus = multiple && isActive
        _overlay?.needsDisplay = true
    }
    
    private func installCompletionMenuIfNeeded() {
        if _completionMenuView != nil { return }

        let completionMenuView = KCompletionMenuView(frame: .zero)
        completionMenuView.isHidden = true

        let clipView = _scrollView.contentView
        clipView.addSubview(completionMenuView, positioned: .above, relativeTo: _textView)

        _completionMenuView = completionMenuView
    }

    func hideCompletionMenu() {
        _completionMenuView?.isHidden = true
    }

    func updateCompletionMenu() {
        guard KPreference.shared.bool(.editorShowCompletionMenu) else {
            hideCompletionMenu()
            return
        }

        let completion = _textView.completion
        guard completion.isInCompletionMode, completion.nowCompleting else {
            hideCompletionMenu()
            return
        }

        let currentEntryIndex = completion.currentEntryIndex
        let menuEntries = completion.menuEntries(after: currentEntryIndex, maxCount: 5)

        guard !menuEntries.isEmpty else {
            hideCompletionMenu()
            return
        }

        installCompletionMenuIfNeeded()

        guard let completionMenuView = _completionMenuView else { return }

        let showsLowerFade = completion.entriesCount > currentEntryIndex + 6
        let lineHeight = _textView.layoutManager.lineHeight

        completionMenuView.update(
            entries: menuEntries,
            showsLowerFade: showsLowerFade,
            font: _textView.textStorage.baseFont,
            lineHeight: lineHeight,
            textColor: _textView.textStorage.parser.baseTextColor,
            backgroundColor: _textView.textStorage.parser.backgroundColor
        )

        let preferredSize = completionMenuView.preferredSize()
        let caretOrigin = _textView.characterPosition(at: _textView.caretIndex)

        var origin = NSPoint(
            x: caretOrigin.x - 1.0,
            y: caretOrigin.y + lineHeight
        )

        let clipBounds = _scrollView.contentView.bounds

        if origin.x < clipBounds.minX {
            origin.x = clipBounds.minX
        }

        if origin.x + preferredSize.width > clipBounds.maxX {
            origin.x = max(clipBounds.minX, clipBounds.maxX - preferredSize.width)
        }

        if origin.y + preferredSize.height > clipBounds.maxY {
            origin.y = max(clipBounds.minY, origin.y - preferredSize.height - lineHeight - 2.0)
        }

        completionMenuView.frame = NSRect(origin: origin, size: preferredSize)
        completionMenuView.isHidden = false
    }
    
    

    // MARK: - Setup

    private func setup() {
        _scrollView.hasVerticalScroller = true
        _scrollView.hasHorizontalScroller = true
        
        _scrollView.documentView = _textView
        
        _scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        
        _textView.updateFrameSizeToFitContent()
        _textView.containerView = self
        
        
        addSubview(_scrollView)

        NSLayoutConstraint.activate([
            _scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            _scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            _scrollView.topAnchor.constraint(equalTo: topAnchor),
            _scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}


