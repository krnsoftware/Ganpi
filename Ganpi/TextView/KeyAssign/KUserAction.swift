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

import Foundation

// 保存されるアクション。セレクタ(IBAction)とコマンドに分けられる。
enum KUserAction {
    case selector(String)        // e.g. "moveRight" (no trailing ":")
    case command(KUserCommand)       // e.g. .execute("/usr/bin/sort")
}

// テキスト入力処理後のキャレットの位置
enum KPostProcessingCaretPosition { case left; case right; case select }
// コマンドが対象にした文字列の範囲
enum KTextEditingTarget { case all; case selection }

// コマンドの結果
struct KCommandResult {
    let string: String
    let options: KCommandOptions
}

struct KCommandOptions {
    let caret: KPostProcessingCaretPosition
    let target: KTextEditingTarget
    
    init(caret: KPostProcessingCaretPosition = .right, target: KTextEditingTarget = .selection){
        self.caret = caret
        self.target = target
    }
}

// コマンドの種類。それぞれ内容はテキストとして渡される。内容は実行の時点で解釈される。
enum KUserCommand {
    case insert(String)         // insert[String] : insert String to the designated range.
    case load(String)            // load[PATH] or [PATH] : insert string from the designated filePATH.
    case execute(String)         // execute[PATH] : execute a file command represented with filePATH.
    
    // 与えられたstorageと、現在の選択範囲rangeについて処理。allであればrangeは単に無視される。
    func execute(for storage:KTextStorageReadable, in range:Range<Int>) -> KCommandResult? {
        let options: KCommandOptions
        let resultString: String
        switch self {
        case .insert(let command):
            let result = estimateCommand(command)
            options = result.options
            log(".insert: command:\(result.command), options:\(result.options)")
            resultString = result.command
        case .load(let command): log(".load: \(command)")
            let result = estimateCommand(command)
            options = result.options
            guard let content = readFromApplicationSupport(result.command) else { log("#01"); return nil }
            resultString = content
        case .execute(let command): log(".execute: \(command)")
            let result = estimateCommand(command)
            options = result.options
            resultString = "under construction..."
        }
        
        return .init(string: resultString, options: options)
    }
    
    private func estimateCommand(_ text: String)
        -> (command: String, options: KCommandOptions) {

        var caret: KPostProcessingCaretPosition = .right
        var target: KTextEditingTarget = .selection
        var payload = ""

        // すでに "caret:left, target:all - \"Hello\\nWorld\"" の形で渡る前提
        let inside = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- options部とpayload部を "-" で分離 ---
        let parts = inside.split(separator: "-", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // --- 左側: options部 ---
        if let optPart = parts.first {
            for fragment in optPart.split(separator: ",") {
                let kv = fragment.split(separator: ":", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard kv.count == 2 else { continue }

                switch kv[0].lowercased() {
                case "caret":
                    switch kv[1].lowercased() {
                    case "left": caret = .left
                    case "right": caret = .right
                    case "select": caret = .select
                    default: break
                    }
                case "target":
                    switch kv[1].lowercased() {
                    case "all": target = .all
                    case "selection": target = .selection
                    default: break
                    }
                default: break
                }
            }
        }

        // --- 右側: payload部 ("..."の中身を抽出) ---
        if parts.count > 1 {
            let rhs = parts[1]
            if let start = rhs.firstIndex(of: "\""),
               let end = rhs.lastIndex(of: "\""),
               end > start {
                let raw = rhs[rhs.index(after: start)..<end]
                payload = String(raw).cUnescaped
            }
        }

        return (payload, KCommandOptions(caret: caret, target: target))
    }

    // MARK: - ファイル読み込み補助

    /// Application Support/Ganpi 以下から相対パスでファイルを読み込む。
    private func readFromApplicationSupport(_ relativePath: String) -> String? {
        guard !relativePath.hasPrefix("/") else {
            log("Absolute path not allowed in load command: \(relativePath)")
            return nil
        }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log("Failed to resolve Application Support directory")
            return nil
        }

        let appDir = base.appendingPathComponent("Ganpi", isDirectory: true)
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            log("Failed to create Ganpi directory: \(error)")
            return nil
        }

        let fileURL = appDir.appendingPathComponent(relativePath)
        do {
            let data = try Data(contentsOf: fileURL)
            guard let string = String(data: data, encoding: .utf8) else { log("#01"); return nil }
            let (convertedString, _) = string.normalizeNewlinesAndDetect()
            return convertedString
        } catch {
            log("File not found or unreadable: \(relativePath)")
            return nil
        }
    }


    
}
