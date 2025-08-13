//
//  KViewController.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Cocoa

final class KViewController: NSViewController {

    private var textViewContainerView: KTextViewContainerView!

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        //print("現在の関数名：\(#function)")
        // KTextViewContainerView の作成
        textViewContainerView = KTextViewContainerView()
        
        // 起動直後に生成されるウインドウのタイトルバーが白く塗り潰される問題を解決。
        // view.window?.titlebarAppearsTransparent = false

        // Auto Layout を使用
        textViewContainerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textViewContainerView)

        NSLayoutConstraint.activate([
            textViewContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textViewContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textViewContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            textViewContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        Swift.print("KViewController.viewDidLoad")
        
        
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        Swift.print("KViewController.viewDidAppear") 
    }
}
