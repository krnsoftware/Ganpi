//
//  KViewController.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/12.
//

import Cocoa

class KViewController: NSViewController {
    
    private var scrollView: NSScrollView!
    private var textView: KTextView!
    
    override func loadView() {
        // ルートビューを生成
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        self.view = contentView
        print("loadview()")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("viewdidload()")
        // ScrollViewを生成
        scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        // KTextViewを生成
        let contentSize = NSSize(width: scrollView.contentSize.width, height: 2000)
        textView = KTextView(frame: NSRect(origin: .zero, size: contentSize))
        //textView.autoresizingMask = [.width, .height]
        textView.autoresizingMask = []
        textView.postsFrameChangedNotifications = true
        
        // ScrollViewに KTextView をセット
        scrollView.documentView = textView
        
        // contentView に ScrollView を追加
        view.addSubview(scrollView)
        
        // Auto Layout 制約（ScrollViewが全体にフィット）
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
