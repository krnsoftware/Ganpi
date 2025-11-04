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
import Darwin

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
    var caret: KPostProcessingCaretPosition = .right
    var target: KTextEditingTarget = .selection
    var timeout: Float = 5.0
    var extras: [String: String] = [:]
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
            let targetRange = options.target == .selection ? range : 0..<storage.count
            guard let content = readFromStream(from:result.command, string:storage.string(in: targetRange)) else { log("#02"); return nil }
            resultString = content
        }
        
        return .init(string: resultString, options: options)
    }
    
    private func estimateCommand(_ command: String) -> (command: String, options: KCommandOptions) {
        var opts = KCommandOptions()
        var optText = ""
        var payloadText = ""

        // [] 内の文字を抽出
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("", opts)
        }

        // 区切り '-' の探索（クォート外で ':' を左に含む最初の '-'）
        var inQuote = false
        var escape = false
        var splitIndex: String.Index? = nil
        var hasColon = false

        for i in trimmed.indices {
            let c = trimmed[i]
            if escape {
                escape = false
                continue
            }
            switch c {
            case "\\":
                escape = true
            case "\"":
                inQuote.toggle()
            case ":":
                if !inQuote { hasColon = true }
            case "-":
                if !inQuote && hasColon {
                    splitIndex = i
                    break
                }
            default:
                break
            }
        }

        if let idx = splitIndex {
            optText = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            payloadText = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        } else {
            payloadText = trimmed
        }

        // オプション解析
        if !optText.isEmpty {
            var key = ""
            var value = ""
            var inQuoteOpt = false
            var escapeOpt = false
            var buffer = ""
            var parsingValue = false

            func commitOption() {
                let k = key.trimmingCharacters(in: .whitespaces)
                let v = value.trimmingCharacters(in: .whitespaces)
                guard !k.isEmpty, !v.isEmpty else { return }

                switch k.lowercased() {
                case "caret":
                    switch v.lowercased() {
                    case "left":   opts.caret = .left
                    case "right":  opts.caret = .right
                    case "select": opts.caret = .select
                    default: break
                    }

                case "target":
                    switch v.lowercased() {
                    case "all":        opts.target = .all
                    case "selection":  opts.target = .selection
                    default: break
                    }

                case "timeout":
                    if let f = Float(v) { opts.timeout = f }

                default:
                    opts.extras[k] = v
                }

            }

            for c in optText {
                if escapeOpt {
                    buffer.append(c)
                    escapeOpt = false
                    continue
                }
                switch c {
                case "\\":
                    escapeOpt = true
                case "\"":
                    inQuoteOpt.toggle()
                case ":" where !inQuoteOpt && !parsingValue:
                    key = buffer
                    buffer = ""
                    parsingValue = true
                case "," where !inQuoteOpt:
                    value = buffer
                    commitOption()
                    key = ""
                    value = ""
                    buffer = ""
                    parsingValue = false
                default:
                    buffer.append(c)
                }
            }

            // 最後の要素を登録
            if parsingValue {
                value = buffer
                commitOption()
            }
        }

        // 後節（payload）解析
        let payload: String
        if payloadText.hasPrefix("\"") && payloadText.hasSuffix("\"") && payloadText.count >= 2 {
            let inner = payloadText.dropFirst().dropLast()
            payload = inner.cUnescaped
        } else {
            payload = payloadText
        }

        return (payload, opts)
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

        let appDir = base.appendingPathComponent("Ganpi/snippets", isDirectory: true)
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

    
    /// Application Support/Ganpi/scripts 以下の外部コマンドを実行し、
    /// UTF-8/LF 文字列を標準入出力でやり取りする。
    /// - Parameter relativePath: scripts/ 以下の相対パス
    /// - Returns: コマンドの標準出力 (UTF-8/LF) 。失敗時は nil。
    /*
    private func readFromStream(from relativePath: String, string: String) -> String? {
        // --- パス安全性チェック ---
        guard !relativePath.hasPrefix("/") else {
            log("Absolute path not allowed in execute command: \(relativePath)")
            return nil
        }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else {
            log("Failed to resolve Application Support directory")
            return nil
        }

        // --- ~/Library/Application Support/Ganpi/scripts/... ---
        let scriptsDir = base.appendingPathComponent("Ganpi/scripts", isDirectory: true)
        let fileURL = scriptsDir.appendingPathComponent(relativePath)

        // --- ファイルの存在確認 ---
        guard fm.isExecutableFile(atPath: fileURL.path) else {
            log("Script not found or not executable: \(fileURL.path)")
            return nil
        }

        // --- 外部プロセス実行 ---
        let process = Process()
        process.executableURL = fileURL

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            log("Failed to launch process: \(error)")
            return nil
        }

        // --- 入力をUTF-8で送る ---
        if let data = string.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        // --- 出力をUTF-8で受け取る ---
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: outputData, encoding: .utf8) else {
            log("Failed to decode command output (non-UTF8)")
            return nil
        }
        
        let (normalizedString, _) = output.normalizeNewlinesAndDetect()
        return normalizedString
    }
    }*/
    

    private func readFromStream(from relativePath: String, string: String) -> String? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { log("#01"); return nil }

        let scriptsDir = base.appendingPathComponent("Ganpi/scripts", isDirectory: true)
        let fileURL = scriptsDir.appendingPathComponent(relativePath)
        guard fm.isExecutableFile(atPath: fileURL.path) else { log("#02"); return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [fileURL.path]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try? process.run()

        // 入力
        if let data = string.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        // 非同期読み込み
        var resultData = Data()
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            while process.isRunning {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                resultData.append(chunk)
            }
            group.leave()
        }

        // タイムアウトでdetach（killしない）
        let waitResult = group.wait(timeout: .now() + 5)
        if waitResult == .timedOut {
            KLog.shared.log(id: "execute", message: "Process did not finish in time: \(relativePath)")
            return nil
        }

        guard let result = String(data: resultData, encoding: .utf8) else { log("#03"); return nil }
        let (convertedString, _) = result.normalizeNewlinesAndDetect()
        return convertedString
    }





}
