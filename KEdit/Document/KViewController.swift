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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("KViewController.viewDidLoad()")
        // scrollView を生成
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
    

    override func viewWillAppear() {
        super.viewWillAppear()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.needsDisplay = true
    }
    
    /*
    override func viewDidAppear() {
        super.viewDidAppear()
        
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()

        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }*/
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.display()
    }
   
}
