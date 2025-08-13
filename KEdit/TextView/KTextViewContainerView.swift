//
//  KTextViewContainerView.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KTextViewContainerView: NSView {

    // MARK: - Subviews

    private let _scrollView = NSScrollView()
    private let _textView: KTextView

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
        
        _textView = KTextView(
            frame: .zero,
            textStorageRef: textStorageRef//,
            //layoutManager: layoutManager
        )
        
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
    
    

    // MARK: - Setup

    private func setup() {
        _scrollView.hasVerticalScroller = true
        _scrollView.hasHorizontalScroller = true
        _scrollView.documentView = _textView
        _scrollView.translatesAutoresizingMaskIntoConstraints = false
        _textView.updateFrameSizeToFitContent()
        
        // test
        // KTextViewContainerView のスクロール設定内

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

        addSubview(_scrollView)

        NSLayoutConstraint.activate([
            _scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            _scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            _scrollView.topAnchor.constraint(equalTo: topAnchor),
            _scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
