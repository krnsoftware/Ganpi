//
//  KMiniSearchPanel.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/30,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

final class KMiniSearchPanel: NSWindowController {
    static let shared = KMiniSearchPanel(windowNibName: "MiniSearchPanel")
    
    @IBOutlet private weak var _findField: NSTextField!
    
    var isAlternateSearchDirectionForward:Bool = true
    
    private var _suspendAction = false
        
    override func windowDidLoad() {
        super.windowDidLoad()
        
        _findField.target = self
        _findField.action = #selector(fieldEdited)
        
        //_findField.backgroundColor = NSColor(hexString: "#B8B8B8FF")
        
        guard let w = window else { return }
        
        // タイトルバーを“見た目だけ”完全に隠す
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        
        // ウィンドウボタンを消す
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        
        // 透明ウィンドウとして扱う（必要なら）
        w.isOpaque = false
        w.backgroundColor = .clear
        
    }
    
    func show(at point: CGPoint, font: NSFont) {
        applyFontAndResize(font: font)

        var origin = point
        if let frameHeight = window?.frame.height {
            origin.y -= frameHeight / 2
        }
        guard let win = window else { log("#01", from: self); return }

        win.setFrameOrigin(origin)

        if win.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            _findField.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 0.55)
        } else {
            _findField.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.05)
        }

        _suspendAction = true

        if win.screen == nil { window?.center() }
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(_findField)
        _findField.stringValue = KSearchPanel.shared.searchString

        DispatchQueue.main.async {
            self._suspendAction = false
        }
    }
    
    override func cancelOperation(_ sender: Any?) {
        actCancel(sender)
    }

    
    @objc private func fieldEdited(_ sender: Any?) {
        if _suspendAction { return }

        let input = _findField.stringValue
        if input.isEmpty { return }

        // :s / :%s を優先
        if input.hasPrefix(":s") || input.hasPrefix(":%s") {
            guard let pending = parseSubstituteCommandLine(input) else {
                reportCommandLineParseError("Command parse error", input: input)
                return
            }
            _pendingSubstitute = pending

            let status = NSApp.sendAction(#selector(KTextView.executeSubstituteCommandLineAction),
                                      to: nil,
                                      from: self)
            if status {
                _findField.stringValue = ""
                window?.orderOut(nil)
            } else {
                NSSound.beep()
            }
            return
        }
        
        // :g / :v を優先
        if input.hasPrefix(":g") || input.hasPrefix(":v") {
            guard let pending = parseGlobalCommandLine(input) else {
                reportCommandLineParseError("Command parse error", input: input)
                return
            }
            _pendingGlobal = pending

            let status = NSApp.sendAction(#selector(KTextView.executeGlobalCommandLineAction),
                                      to: nil,
                                      from: self)
            
            if status {
                _findField.stringValue = ""
                window?.orderOut(nil)
            } else {
                NSSound.beep()
            }
            return
        }

        // 従来どおり：検索
        KSearchPanel.shared.searchString = input
        NSApp.sendAction(#selector(KTextView.searchAlternateAction), to: nil, from: self)
        _findField.stringValue = ""
        window?.orderOut(nil)
    }
    
    @IBAction private func actCancel(_ sender: Any?) {
        window?.orderOut(nil)
    }
    
    private func applyFontAndResize(font: NSFont) {
        guard let win = window else { return }

        _findField.font = font

        // 基準（XIBの元サイズが 272x33 / フォント12pt 前提）
        let baseFontSize: CGFloat = 12.0
        let baseWindowSize = CGSize(width: 272, height: 33)

        let scale = max(0.75, min(2.5, font.pointSize / baseFontSize))

        // 高さは素直に追従（上限下限だけ付ける）
        let newHeight = max(28, min(70, round(baseWindowSize.height * scale)))

        // 幅は追従しすぎると不格好なので「緩く」追従させる
        let widthScale = max(1.0, min(1.6, 1.0 + (scale - 1.0) * 0.4))
        let newWidth = max(baseWindowSize.width, round(baseWindowSize.width * widthScale))

        // まずウインドウのコンテンツサイズを変更
        win.setContentSize(NSSize(width: newWidth, height: newHeight))

        // テキストフィールドのフレームを更新（XIBがframeベース前提）
        guard let container = _findField.superview else { return }

        // フォントの実サイズから入力欄の高さを決める
        let fontHeight = ceil(font.ascender - font.descender)
        let fieldHeight = max(18, min(newHeight - 8, fontHeight + 6))

        let insetX: CGFloat = 7
        let insetY: CGFloat = 4

        let fieldWidth = max(80, container.bounds.width - insetX * 2)
        let fieldY = floor((container.bounds.height - fieldHeight) / 2)

        _findField.frame = NSRect(x: insetX, y: max(insetY, fieldY), width: fieldWidth, height: fieldHeight)
    }
    
    
    // MARK: - :s / :%s command support

    private enum KSubstituteTarget {
        case currentLine
        case wholeDocument
    }

    private struct KPendingSubstitute {
        let target: KSubstituteTarget
        let pattern: String
        let replacement: String
        let isGlobal: Bool
    }

    private var _pendingSubstitute: KPendingSubstitute? = nil

    func takePendingSubstitute() -> (isWholeDocument: Bool, pattern: String, replacement: String, isGlobal: Bool)? {
        guard let p = _pendingSubstitute else { return nil }
        _pendingSubstitute = nil
        return (p.target == .wholeDocument, p.pattern, p.replacement, p.isGlobal)
    }

    /// :s/<regex>/<rep>/[g]
    /// :%s/<regex>/<rep>/[g]
    /// - delimiterは'/'固定
    /// - '\/' と '\\' を最低限解釈
    private func parseSubstituteCommandLine(_ input: String) -> KPendingSubstitute? {
        let chars = Array(input)
        if chars.count < 4 { return nil }

        guard chars[0] == ":" else { return nil }

        var index = 1
        var target: KSubstituteTarget = .currentLine

        if index < chars.count, chars[index] == "%" {
            target = .wholeDocument
            index += 1
        }

        guard index < chars.count, chars[index] == "s" else { return nil }
        index += 1

        guard index < chars.count, chars[index] == "/" else { return nil }
        index += 1

        func readSection() -> String? {
            var out: [Character] = []
            var escaped = false

            while index < chars.count {
                let c = chars[index]
                index += 1

                if escaped {
                    out.append(c)
                    escaped = false
                    continue
                }
                if c == "\\" {
                    escaped = true
                    continue
                }
                if c == "/" {
                    return String(out)
                }
                out.append(c)
            }
            return nil
        }

        guard let rawPattern = readSection(), !rawPattern.isEmpty else { return nil }
        guard let rawReplacement = readSection() else { return nil }

        while index < chars.count, chars[index].isWhitespace { index += 1 }

        var isGlobal = false
        if index < chars.count {
            if chars[index] == "g" {
                isGlobal = true
                index += 1
            }
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        if index < chars.count { return nil }

        func unescape(_ s: String) -> String {
            var result: [Character] = []
            let a = Array(s)
            var i = 0
            while i < a.count {
                let c = a[i]
                if c == "\\", i + 1 < a.count {
                    let n = a[i + 1]
                    if n == "/" || n == "\\" {
                        result.append(n)
                        i += 2
                        continue
                    }
                }
                result.append(c)
                i += 1
            }
            return String(result)
        }

        return KPendingSubstitute(target: target,
                                  pattern: unescape(rawPattern),
                                  replacement: unescape(rawReplacement),
                                  isGlobal: isGlobal)
    }
    
    // MARK: - :g / :v command support

    private struct KPendingGlobal {
        let isInvert: Bool   // true = :v
        let pattern: String
    }

    private var _pendingGlobal: KPendingGlobal? = nil

    func takePendingGlobal() -> (isInvert: Bool, pattern: String)? {
        guard let p = _pendingGlobal else { return nil }
        _pendingGlobal = nil
        return (p.isInvert, p.pattern)
    }

    /// :g/<regex>/
    /// :v/<regex>/
    /// - delimiterは'/'固定
    /// - '\/' と '\\' を最低限解釈
    private func parseGlobalCommandLine(_ input: String) -> KPendingGlobal? {
        let chars = Array(input)
        if chars.count < 4 { return nil }

        guard chars[0] == ":" else { return nil }
        let isInvert: Bool
        if chars[1] == "g" {
            isInvert = false
        } else if chars[1] == "v" {
            isInvert = true
        } else {
            return nil
        }

        var index = 2
        guard index < chars.count, chars[index] == "/" else { return nil }
        index += 1

        var out: [Character] = []
        var escaped = false

        while index < chars.count {
            let c = chars[index]
            index += 1

            if escaped {
                out.append(c)
                escaped = false
                continue
            }
            if c == "\\" {
                escaped = true
                continue
            }
            if c == "/" {
                // 末尾は空白のみ許容
                while index < chars.count, chars[index].isWhitespace { index += 1 }
                if index < chars.count { return nil }
                let raw = String(out)
                if raw.isEmpty { return nil }
                return KPendingGlobal(isInvert: isInvert, pattern: unescapeSlashAndBackslash(raw))
            }
            out.append(c)
        }
        return nil
    }

    private func unescapeSlashAndBackslash(_ s: String) -> String {
        var result: [Character] = []
        let a = Array(s)
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "\\", i + 1 < a.count {
                let n = a[i + 1]
                if n == "/" || n == "\\" {
                    result.append(n)
                    i += 2
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return String(result)
    }
    
    private func reportCommandLineParseError(_ message: String, input: String) {
        KLog.shared.log(id: "commandline", message: "\(message) (\(input))")
        KLogPanel.shared.present()
    }
    
}
