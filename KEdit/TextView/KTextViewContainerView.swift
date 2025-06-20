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

    private let _scrollView = NSScrollView()
    public private(set) var _textView: KTextView
    private let _lineNumberView: KLineNumberView

    // MARK: - Dependencies

    private let _textStorageRef: KTextStorageProtocol
    private let _layoutManager: KLayoutManager
    
    // MARK: - Accessor

    var textView: KTextView {
        _textView
    }

    // MARK: - Init
    /*
    init(frame: CGRect, textView: KTextView, lineNumberView: KLineNumberView) {
        _textView = textView
        _lineNumberView = lineNumberView
        _scrollView = NSScrollView()
        super.init(frame: frame)
        setup()
    }*/
    override init(frame: NSRect) {
        self._textStorageRef = KTextStorage()
        self._layoutManager = KLayoutManager(textStorageRef: _textStorageRef)
        self._textView = KTextView(
            frame: .zero,
            textStorageRef: _textStorageRef,
            layoutManager: _layoutManager
        )
        self._lineNumberView = KLineNumberView(
            frame: .zero,
            textStorageRef: _textStorageRef,
            layoutManagerRef: _layoutManager
        )
        super.init(frame: frame)
        setup()
        print("✅ lineNumberView instance: \(_lineNumberView)")
    }

    required init?(coder: NSCoder) {
        self._textStorageRef = KTextStorage()
        self._layoutManager = KLayoutManager(textStorageRef: _textStorageRef)
        self._textView = KTextView(
            frame: .zero,
            textStorageRef: _textStorageRef,
            layoutManager: _layoutManager
        )
        self._lineNumberView = KLineNumberView(
            frame: .zero,
            textStorageRef: _textStorageRef,
            layoutManagerRef: _layoutManager
        )
        super.init(coder: coder)
        setup()
    }

    
    
    override func layout() {
        super.layout()

        // スクロール位置に追従して lineNumberView を移動
        let contentBounds = _scrollView.contentView.bounds
        let yOffset = contentBounds.origin.y

        // lineNumberView の位置を調整
        var frame = _lineNumberView.frame
        frame.origin.y = yOffset
        frame.size.height = _textView.frame.height
        _lineNumberView.frame = frame
    }

    /*
    private func adjustTextViewWidthToClipView() {
        let clipWidth = _scrollView.contentView.bounds.width
        _textView.frame.size.width = clipWidth
        print("ktextviewcontainview \(#function)")
    }*/

    // MARK: - Setup

    private func setup() {
        /*
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
         
         
         //test
         textView.translatesAutoresizingMaskIntoConstraints = false
         NSLayoutConstraint.activate([
         textView.leadingAnchor.constraint(equalTo: _scrollView.contentView.leadingAnchor),
         textView.topAnchor.constraint(equalTo: _scrollView.contentView.topAnchor),
         textView.widthAnchor.constraint(greaterThanOrEqualToConstant: 800), // 仮幅
         textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 2000) // 仮高
         ])
         
         }*/
        // スクロールビューの設定
            _scrollView.hasVerticalScroller = true
            _scrollView.hasHorizontalScroller = true
            _scrollView.translatesAutoresizingMaskIntoConstraints = false

            // テキストビューの設定
            _textView.translatesAutoresizingMaskIntoConstraints = false
            _scrollView.documentView = _textView

            // 行番号ビューの設定（最初の位置）
            _lineNumberView.frame = CGRect(x: 0, y: 0, width: 40, height: 1000) // 仮サイズ
            _lineNumberView.autoresizingMask = [.height]  // 高さだけ自動調整
            _scrollView.contentView.addSubview(_lineNumberView)

            // 各ビューを addSubview
            addSubview(_scrollView)

            // Auto Layout 制約（scrollView全体）
            NSLayoutConstraint.activate([
                _scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                _scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                _scrollView.topAnchor.constraint(equalTo: topAnchor),
                _scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])

            // テキストビューの制約（contentViewに対して）
            NSLayoutConstraint.activate([
                _textView.leadingAnchor.constraint(equalTo: _scrollView.contentView.leadingAnchor, constant: 40), // 行番号分ずらす
                _textView.topAnchor.constraint(equalTo: _scrollView.contentView.topAnchor),
                _textView.bottomAnchor.constraint(greaterThanOrEqualTo: _scrollView.contentView.bottomAnchor),
                _textView.trailingAnchor.constraint(greaterThanOrEqualTo: _scrollView.contentView.trailingAnchor)
            ])
    }

}
