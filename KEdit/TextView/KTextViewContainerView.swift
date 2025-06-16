//
//  KTextContainerView.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KTextContainerView: NSView {

    // MARK: - Subviews

    private let _textView: KTextView
    private let _lineNumberView: KLineNumberView
    
    // MARK: - Accessor

    var textView: KTextView {
        _textView
    }

    // MARK: - Init

    init(frame: CGRect, textView: KTextView, lineNumberView: KLineNumberView) {
        _textView = textView
        _lineNumberView = lineNumberView
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = _textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        _lineNumberView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(_lineNumberView)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            _lineNumberView.leadingAnchor.constraint(equalTo: leadingAnchor),
            _lineNumberView.topAnchor.constraint(equalTo: topAnchor),
            _lineNumberView.bottomAnchor.constraint(equalTo: bottomAnchor),
            _lineNumberView.widthAnchor.constraint(equalToConstant: 40),

            scrollView.leadingAnchor.constraint(equalTo: _lineNumberView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }


}
