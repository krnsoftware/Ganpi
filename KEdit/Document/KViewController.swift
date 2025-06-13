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

    /*override func viewDidLoad() {
        super.viewDidLoad()

        // ScrollView を生成
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = true//false

        // TextView を生成（高さ固定、幅は後で決定）
        textView = KTextView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 2000)))
        //textView.autoresizingMask = []
        textView.autoresizingMask = [.width, .height]
        textView.postsFrameChangedNotifications = true
        textView.wantsLayer = true
        textView.layer?.backgroundColor = NSColor.white.cgColor

        // ScrollView に TextView を貼り付け
        scrollView.documentView = textView

        // 自身の view に ScrollView を追加
        view.addSubview(scrollView)
        
        
        
        // Auto Layout 制約を適用
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
         

        // スクロール初期位置
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }*/
    
    override func viewDidLoad() {
            super.viewDidLoad()
            
            // scrollView を生成
            scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.frame = self.view.bounds
            scrollView.autoresizingMask = [.width, .height] // ← これで親ビューに追従
            
            // textView を生成
            let initialWidth = scrollView.contentSize.width
            let initialHeight: CGFloat = 2000
            textView = KTextView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight))
            textView.autoresizingMask = [] // 自動サイズ調整は不要
            textView.translatesAutoresizingMaskIntoConstraints = true // ← Auto Layout 無効

            scrollView.documentView = textView
            
            // scrollView を親ビューに追加
            view.addSubview(scrollView)
        }

    override func viewDidLayout() {
        super.viewDidLayout()

        // scrollView の表示領域にあわせて textView の幅を調整
        let width = scrollView.contentView.bounds.width
        if textView.frame.size.width != width {
            textView.frame.size.width = width
            print("🛠 textView.frame.width updated to \(width)")
        }
        
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        // textViewのwidth更新もここで（これをしないとウインドウのタイトルバーが白く表示される)
        scrollView.frame = self.view.bounds
        textView.frame.size.width = scrollView.contentSize.width
    }
   
}
