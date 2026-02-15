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
            guard let result = estimateCommand(command) else {
                KLog.shared.log(id: "useraction", message: "Invalid insert command: \(command)")
                return nil
            }
            options = result.options
            log(".insert: command:\(result.command), options:\(result.options)")
            resultString = result.command

        case .load(let command):
            guard let result = estimateCommand(command) else {
                KLog.shared.log(id: "useraction", message: "Invalid load command: \(command)")
                return nil
            }
            options = result.options
            guard let content = readFromApplicationSupport(result.command) else { log("#01"); return nil }
            resultString = content

        case .execute(let command):
            guard let result = estimateCommand(command) else {
                KLog.shared.log(id: "useraction", message: "Invalid execute command: \(command)")
                return nil
            }
            options = result.options
            let targetRange = options.target == .selection ? range : 0..<storage.count
            guard let content = readFromStream(from: result.command,
                                               string: storage.string(in: targetRange),
                                               timeout: options.timeout) else { log("#02"); return nil }
            resultString = content
        }
        
        return .init(string: resultString, options: options)
    }
    
    private func estimateCommand(_ command: String) -> (command: String, options: KCommandOptions)? {
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
                if let f = Float(v) { opts.timeout = f } else { opts.extras[k] = v }
            default:
                opts.extras[k] = v
            }
        }

        var opts = KCommandOptions()
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KLog.shared.log(id: "useraction", message: "Invalid command: empty payload")
            return nil
        }

        var index = trimmed.startIndex

        func skipSpaces() {
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
        }

        // 1) options ブロック { ... }（任意）
        skipSpaces()
        if index < trimmed.endIndex, trimmed[index] == "{" {
            var braceDepth = 1
            var quote: Character? = nil
            var escape = false
            index = trimmed.index(after: index) // skip '{'

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
                KLog.shared.log(id: "useraction", message: "Invalid command: options block not closed: \(command)")
                return nil
            }

            // options 解析（key:value を , 区切り。クォート保護）
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

        // 2) payload はクォート必須
        skipSpaces()
        guard index < trimmed.endIndex else {
            KLog.shared.log(id: "useraction", message: "Invalid command: missing quoted payload: \(command)")
            return nil
        }

        let quoteChar = trimmed[index]
        guard quoteChar == "\"" || quoteChar == "'" else {
            KLog.shared.log(id: "useraction", message: "Invalid command: payload must be quoted: \(command)")
            return nil
        }

        index = trimmed.index(after: index) // skip opening quote

        var rawPayload = ""
        var payloadEscape = false
        var closed = false

        while index < trimmed.endIndex {
            let c = trimmed[index]

            if payloadEscape {
                rawPayload.append("\\")
                rawPayload.append(c)
                payloadEscape = false
                index = trimmed.index(after: index)
                continue
            }

            if c == "\\" {
                payloadEscape = true
                index = trimmed.index(after: index)
                continue
            }

            if c == quoteChar {
                index = trimmed.index(after: index) // skip closing quote
                closed = true
                break
            }

            rawPayload.append(c)
            index = trimmed.index(after: index)
        }

        guard closed else {
            KLog.shared.log(id: "useraction", message: "Invalid command: quoted payload not closed: \(command)")
            return nil
        }

        skipSpaces()
        if index < trimmed.endIndex {
            KLog.shared.log(id: "useraction", message: "Invalid command: trailing characters after payload: \(command)")
            return nil
        }

        let payload = unescapePayload(rawPayload)
        return (payload, opts)
    }


    // MARK: - ファイル読み込み補助

    /// Application Support/<bundle id>/snippets 以下から相対パスでファイルを読み込む。
    private func readFromApplicationSupport(_ relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            KLog.shared.log(id: "load", message: "Invalid path: empty")
            return nil
        }
        guard !trimmed.hasPrefix("/") else {
            KLog.shared.log(id: "load", message: "Absolute path not allowed: \(trimmed)")
            return nil
        }
        if trimmed.contains("..") {
            KLog.shared.log(id: "load", message: "Path traversal not allowed: \(trimmed)")
            return nil
        }

        let fm = FileManager.default
        guard let appDir = KAppPaths.snippetsDirectoryURL(createIfNeeded: true) else {
            KLog.shared.log(id: "load", message: "Snippets directory not available.")
            return nil
        }

        let baseURL = appDir.resolvingSymlinksInPath()
        let fileURL = baseURL.appendingPathComponent(trimmed).resolvingSymlinksInPath()
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard fileURL.path.hasPrefix(basePath) else {
            KLog.shared.log(id: "load", message: "Path escapes snippets directory: \(trimmed)")
            return nil
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            KLog.shared.log(id: "load", message: "File not found (or is a directory): \(trimmed)")
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let string = String(data: data, encoding: .utf8) else { log("#01"); return nil }
            let (convertedString, _) = string.normalizeNewlinesAndDetect()
            return convertedString
        } catch {
            KLog.shared.log(id: "load", message: "File unreadable: \(trimmed)")
            return nil
        }
    }

    
    /// Application Scripts/<bundle id>/scripts 以下の外部コマンドを実行し、
    /// UTF-8/LF 文字列を標準入出力でやり取りする。
    private func readFromStream(from relativePath: String, string: String, timeout: Float) -> String? {
        func makeLogSnippet(from data: Data, limit: Int) -> String {
            guard !data.isEmpty else { return "(no output)" }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if text.count <= limit { return text }
            return "\(text.prefix(limit))…"
        }

        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            KLog.shared.log(id: "execute", message: "Invalid path: empty")
            return nil
        }
        guard !trimmed.hasPrefix("/") else {
            KLog.shared.log(id: "execute", message: "Absolute path not allowed: \(trimmed)")
            return nil
        }
        if trimmed.contains("..") {
            KLog.shared.log(id: "execute", message: "Path traversal not allowed: \(trimmed)")
            return nil
        }

        let fm = FileManager.default
        guard let scriptsDir = KAppPaths.scriptsDirectoryURL(createIfNeeded: true) else {
            KLog.shared.log(id: "execute", message: "Scripts directory not available.")
            return nil
        }

        let baseURL = scriptsDir.resolvingSymlinksInPath()
        let fileURL = baseURL.appendingPathComponent(trimmed).resolvingSymlinksInPath()
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard fileURL.path.hasPrefix(basePath) else {
            KLog.shared.log(id: "execute", message: "Path escapes scripts directory: \(trimmed)")
            return nil
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            KLog.shared.log(id: "execute", message: "Script not found: \(trimmed)")
            return nil
        }
        guard !isDir.boolValue else {
            KLog.shared.log(id: "execute", message: "Script is a directory: \(trimmed)")
            return nil
        }
        guard fm.isExecutableFile(atPath: fileURL.path) else {
            KLog.shared.log(id: "execute", message: "Script is not executable: \(trimmed)")
            return nil
        }

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
            KLog.shared.log(id: "execute", message: "Failed to launch process: \(trimmed) (\(error))")
            return nil
        }

        let pid = process.processIdentifier

        if let data = string.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        var resultData = Data()
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            while process.isRunning {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                resultData.append(chunk)
            }

            let tail = outputPipe.fileHandleForReading.availableData
            if !tail.isEmpty { resultData.append(tail) }

            group.leave()
        }

        let timeoutSeconds = max(0.1, Double(timeout))
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1000.0))

        let waitResult = group.wait(timeout: deadline)
        if waitResult == .timedOut {
            let snippetBefore = makeLogSnippet(from: resultData, limit: 500)

            process.terminate()

            let graceSeconds = 0.3
            let graceDeadline = DispatchTime.now() + .milliseconds(Int(graceSeconds * 1000.0))
            _ = group.wait(timeout: graceDeadline)

            var killed = false
            if process.isRunning {
                _ = kill(pid, SIGKILL)
                killed = true
            }

            let finalWaitSeconds = 0.2
            let finalDeadline = DispatchTime.now() + .milliseconds(Int(finalWaitSeconds * 1000.0))
            _ = group.wait(timeout: finalDeadline)

            let action = killed ? "terminate+kill" : "terminate"
            KLog.shared.log(
                id: "execute",
                message: """
                Process timed out (\(timeoutSeconds)s) [\(action)] pid=\(pid) script="\(trimmed)"
                Output (partial):
                \(snippetBefore)
                """
            )
            return nil
        }

        guard let result = String(data: resultData, encoding: .utf8) else { log("#03"); return nil }
        let (convertedString, _) = result.normalizeNewlinesAndDetect()
        return convertedString
    }

}
