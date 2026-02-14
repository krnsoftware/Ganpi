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
            guard let content = readFromStream(from: result.command,
                                               string: storage.string(in: targetRange),
                                               timeout: options.timeout) else { log("#02"); return nil }
            resultString = content
        }
        
        return .init(string: resultString, options: options)
    }
    
    private func estimateCommand(_ command: String) -> (command: String, options: KCommandOptions) {
        func unescapePayload(_ raw: String) -> String {
            var result = ""
            var escape = false
            for c in raw {
                if escape {
                    switch c {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    case "'": result.append("'")
                    default: result.append(c)
                    }
                    escape = false
                    continue
                }

                if c == "\\" {
                    escape = true
                    continue
                }
                result.append(c)
            }
            // 末尾が "\" で終わった場合は "\" をそのまま残す
            if escape { result.append("\\") }
            return result
        }

        func commitOption(key: String, value: String, opts: inout KCommandOptions) {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { return }

            switch k {
            case "caret":
                switch v.lowercased() {
                case "left": opts.caret = .left
                case "right": opts.caret = .right
                case "select": opts.caret = .select
                default:
                    opts.extras[k] = v
                }
            case "target":
                switch v.lowercased() {
                case "all": opts.target = .all
                case "selection": opts.target = .selection
                default:
                    opts.extras[k] = v
                }
            case "timeout":
                if let f = Float(v) {
                    opts.timeout = f
                } else {
                    opts.extras[k] = v
                }
            default:
                opts.extras[k] = v
            }
        }

        var opts = KCommandOptions()

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            log("Invalid command: empty payload")
            return ("", opts)
        }

        var index = trimmed.startIndex

        func skipSpaces() {
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
        }

        // 1) options ブロック { ... } を読む（任意）
        skipSpaces()
        if index < trimmed.endIndex, trimmed[index] == "{" {
            var braceDepth = 0
            var quote: Character? = nil
            var escape = false
            index = trimmed.index(after: index) // skip '{'
            braceDepth = 1

            var optionText = ""

            while index < trimmed.endIndex {
                let c = trimmed[index]

                if let q = quote {
                    optionText.append(c)
                    if escape {
                        escape = false
                    } else if c == "\\" {
                        escape = true
                    } else if c == q {
                        quote = nil
                    }
                    index = trimmed.index(after: index)
                    continue
                }

                if c == "\"" || c == "'" {
                    quote = c
                    optionText.append(c)
                    index = trimmed.index(after: index)
                    continue
                }

                if c == "{" {
                    braceDepth += 1
                    optionText.append(c)
                    index = trimmed.index(after: index)
                    continue
                }
                if c == "}" {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        index = trimmed.index(after: index) // skip '}'
                        break
                    }
                    optionText.append(c)
                    index = trimmed.index(after: index)
                    continue
                }

                optionText.append(c)
                index = trimmed.index(after: index)
            }

            if braceDepth != 0 {
                log("Invalid command: options block not closed")
                return ("", opts)
            }

            // options を解析： key:value を , 区切り（クォート保護）
            var currentKey = ""
            var currentValue = ""
            var readingValue = false
            var optQuote: Character? = nil
            var optEscape = false

            func commitPair() {
                if !currentKey.isEmpty || !currentValue.isEmpty {
                    commitOption(key: currentKey, value: currentValue, opts: &opts)
                }
                currentKey = ""
                currentValue = ""
                readingValue = false
            }

            for c in optionText {
                if let q = optQuote {
                    if readingValue { currentValue.append(c) } else { currentKey.append(c) }

                    if optEscape {
                        optEscape = false
                    } else if c == "\\" {
                        optEscape = true
                    } else if c == q {
                        optQuote = nil
                    }
                    continue
                }

                if c == "\"" || c == "'" {
                    optQuote = c
                    if readingValue { currentValue.append(c) } else { currentKey.append(c) }
                    continue
                }

                if c == ":" && !readingValue {
                    readingValue = true
                    continue
                }

                if c == "," {
                    commitPair()
                    continue
                }

                if readingValue { currentValue.append(c) } else { currentKey.append(c) }
            }
            commitPair()

            skipSpaces()
        }

        // 2) payload は必ずクォート必須（"..." または '...'）
        skipSpaces()
        guard index < trimmed.endIndex else {
            log("Invalid command: missing quoted payload")
            return ("", opts)
        }

        let quoteChar = trimmed[index]
        guard quoteChar == "\"" || quoteChar == "'" else {
            log("Invalid command: payload must be quoted with \"...\" or '...'")
            return ("", opts)
        }

        index = trimmed.index(after: index) // skip opening quote

        var rawPayload = ""
        var escape = false
        while index < trimmed.endIndex {
            let c = trimmed[index]
            if escape {
                rawPayload.append("\\")
                rawPayload.append(c)
                escape = false
                index = trimmed.index(after: index)
                continue
            }
            if c == "\\" {
                escape = true
                index = trimmed.index(after: index)
                continue
            }
            if c == quoteChar {
                index = trimmed.index(after: index) // skip closing quote
                break
            }
            rawPayload.append(c)
            index = trimmed.index(after: index)
        }

        // 閉じクォートが無い
        if index <= trimmed.endIndex, (index == trimmed.endIndex && (trimmed.last != quoteChar)) {
            // 末尾まで到達しているのに閉じていないケースを拾う
            // （上のループは quoteChar で break するため）
            if trimmed.last != quoteChar {
                log("Invalid command: quoted payload not closed")
                return ("", opts)
            }
        }

        skipSpaces()
        if index < trimmed.endIndex {
            // 余剰文字は不正（破壊的変更なので厳格）
            log("Invalid command: trailing characters after payload")
            return ("", opts)
        }

        let payload = unescapePayload(rawPayload)
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

    private func readFromStream(from relativePath: String, string: String, timeout: Float) -> String? {
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

        do {
            try process.run()
        } catch {
            KLog.shared.log(id: "execute", message: "Failed to launch process: \(relativePath) (\(error))")
            return nil
        }

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

            // 終了後の残りも回収
            let tail = outputPipe.fileHandleForReading.availableData
            if !tail.isEmpty { resultData.append(tail) }

            group.leave()
        }

        // timeout 秒で待つ（最低 0.1 秒は待つ）
        let timeoutSeconds = max(0.1, Double(timeout))
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1000.0))

        let waitResult = group.wait(timeout: deadline)
        if waitResult == .timedOut {
            // 意味のある timeout：プロセスを終了させる
            process.terminate()
            KLog.shared.log(id: "execute", message: "Process timed out (\(timeoutSeconds)s): \(relativePath)")
            return nil
        }

        guard let result = String(data: resultData, encoding: .utf8) else { log("#03"); return nil }
        let (convertedString, _) = result.normalizeNewlinesAndDetect()
        return convertedString
    }

}
