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

        // Auto Layout を使用
        textViewContainerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textViewContainerView)

        NSLayoutConstraint.activate([
            textViewContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textViewContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textViewContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            textViewContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
