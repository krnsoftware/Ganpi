//
//  KTextContainerView.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KTextViewContainerView: NSView {

    // MARK: - Subviews

    private let _textView: KTextView
    private let _lineNumberView: KLineNumberView
    private let _scrollView: NSScrollView
    
    // MARK: - Accessor

    var textView: KTextView {
        _textView
    }

    // MARK: - Init

    init(frame: CGRect, textView: KTextView, lineNumberView: KLineNumberView) {
        _textView = textView
        _lineNumberView = lineNumberView
        _scrollView = NSScrollView()
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()

        let clipWidth = _scrollView.contentView.bounds.width
        if _textView.frame.width != clipWidth {
            _textView.frame.size.width = clipWidth
        }
        print("layout()")
    }

    private func adjustTextViewWidthToClipView() {
        let clipWidth = _scrollView.contentView.bounds.width
        _textView.frame.size.width = clipWidth
    }

    // MARK: - Setup

    private func setup() {
        //let scrollView = NSScrollView()
        _scrollView.hasVerticalScroller = true
        _scrollView.hasHorizontalScroller = true
        _scrollView.documentView = _textView
        _scrollView.translatesAutoresizingMaskIntoConstraints = false

        _lineNumberView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(_lineNumberView)
        addSubview(_scrollView)

        NSLayoutConstraint.activate([
            _lineNumberView.leadingAnchor.constraint(equalTo: leadingAnchor),
            _lineNumberView.topAnchor.constraint(equalTo: topAnchor),
            _lineNumberView.bottomAnchor.constraint(equalTo: bottomAnchor),
            _lineNumberView.widthAnchor.constraint(equalToConstant: 40),

            _scrollView.leadingAnchor.constraint(equalTo: _lineNumberView.trailingAnchor),
            _scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            _scrollView.topAnchor.constraint(equalTo: topAnchor),
            _scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }


}
