//
//  KAction.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/03,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

// キーアサイン・ユーザ定義メニュー・アクションレコーディングなどに使用される「アクション」の定義。

// 保存されるアクション。セレクタ(IBAction)とコマンドに分けられる。
enum KAction {
    case selector(String)        // e.g. "moveRight" (no trailing ":")
    case command(KCommand)       // e.g. .execute("/usr/bin/sort")
}

// コマンドの種類。それぞれ内容はテキストとして渡される。内容は実行の時点で解釈される。
enum KCommand {
    case insert(String)         // insert[String]
    case load(String)            // load[PATH] or [PATH]
    case execute(String)         // execute[PATH]
    
    func execute() {
        switch self {
        case .insert(let command):
        case .load(let command):
        case .execute(let command):
        }
    }
}
