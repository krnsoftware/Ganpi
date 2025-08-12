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

        addSubview(_scrollView)

        NSLayoutConstraint.activate([
            _scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            _scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            _scrollView.topAnchor.constraint(equalTo: topAnchor),
            _scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
