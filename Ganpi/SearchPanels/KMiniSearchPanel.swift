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
    
    enum Mode {
        case search
        case substitute
        case selectionSubstitute
        case wholeDocumentSubstitute
        case globalFilter
        case inverseGlobalFilter
    }
    
    @IBOutlet private weak var _findField: NSTextField!
    
    var isAlternateSearchDirectionForward: Bool = true
    
    private var _suspendAction = false
    private var _mode: Mode = .search
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        _findField.target = self
        _findField.action = #selector(fieldEdited)
        
        guard let w = window else { return }
        
        // タイトルバーを“見た目だけ”完全に隠す
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        
        // ウィンドウボタンを消す
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        
        // 透明ウィンドウとして扱う
        w.isOpaque = false
        w.backgroundColor = .clear
    }
    
    func show(at point: CGPoint, font: NSFont, mode: Mode) {
        _mode = mode
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

        switch mode {
        case .search:
            _findField.stringValue = KSearchPanel.shared.searchString
            _findField.placeholderString = nil

        case .substitute, .selectionSubstitute, .wholeDocumentSubstitute:
            _findField.stringValue = ""
            _findField.placeholderString = "/pattern/rep/[g]"

        case .globalFilter, .inverseGlobalFilter:
            _findField.stringValue = ""
            _findField.placeholderString = "pattern"
        }

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

        switch _mode {
        case .search:
            KSearchPanel.shared.searchString = input
            NSApp.sendAction(#selector(KTextView.searchAlternateAction), to: nil, from: self)
            _findField.stringValue = ""
            window?.orderOut(nil)

        case .substitute:
            guard let pending = parseSubstituteBody(input, target: .currentLine) else {
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

        case .selectionSubstitute:
            guard let pending = parseSubstituteBody(input, target: .selection) else {
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

        case .wholeDocumentSubstitute:
            guard let pending = parseSubstituteBody(input, target: .wholeDocument) else {
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

        case .globalFilter:
            guard let pending = parseGlobalPattern(input, isInvert: false) else {
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

        case .inverseGlobalFilter:
            guard let pending = parseGlobalPattern(input, isInvert: true) else {
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
        }
    }
    
    @IBAction private func actCancel(_ sender: Any?) {
        window?.orderOut(nil)
    }
    
    private func applyFontAndResize(font: NSFont) {
        guard let win = window else { return }

        _findField.font = font

        let baseFontSize: CGFloat = 12.0
        let baseWindowSize = CGSize(width: 272, height: 33)

        let scale = max(0.75, min(2.5, font.pointSize / baseFontSize))

        let newHeight = max(28, min(70, round(baseWindowSize.height * scale)))

        let widthScale = max(1.0, min(1.6, 1.0 + (scale - 1.0) * 0.4))
        let newWidth = max(baseWindowSize.width, round(baseWindowSize.width * widthScale))

        win.setContentSize(NSSize(width: newWidth, height: newHeight))

        guard let container = _findField.superview else { return }

        let fontHeight = ceil(font.ascender - font.descender)
        let fieldHeight = max(18, min(newHeight - 8, fontHeight + 6))

        let insetX: CGFloat = 7
        let insetY: CGFloat = 4

        let fieldWidth = max(80, container.bounds.width - insetX * 2)
        let fieldY = floor((container.bounds.height - fieldHeight) / 2)

        _findField.frame = NSRect(x: insetX, y: max(insetY, fieldY), width: fieldWidth, height: fieldHeight)
    }
    
    
    // MARK: - Substitute command support

    private enum KSubstituteTarget {
        case currentLine
        case selection
        case wholeDocument
    }

    private struct KPendingSubstitute {
        let target: KSubstituteTarget
        let pattern: String
        let replacement: String
        let isGlobal: Bool
    }

    private var _pendingSubstitute: KPendingSubstitute? = nil

    func takePendingSubstitute() -> (target: String, pattern: String, replacement: String, isGlobal: Bool)? {
        guard let pending = _pendingSubstitute else { return nil }
        _pendingSubstitute = nil

        let target: String
        switch pending.target {
        case .currentLine:
            target = "currentLine"
        case .selection:
            target = "selection"
        case .wholeDocument:
            target = "wholeDocument"
        }

        return (target, pending.pattern, pending.replacement, pending.isGlobal)
    }

    /// /<regex>/<rep>/[g]
    /// - delimiterは'/'固定
    /// - '\/' と '\\' を最低限解釈
    /// /<regex>/<rep>/[g]
    /// - delimiterは'/'固定
    /// - '\/' のみ区切り文字のエスケープとして扱う
    /// - '\\' や '\+' など、その他のバックスラッシュ列は壊さずそのまま残す
    private func parseSubstituteBody(_ input: String, target: KSubstituteTarget) -> KPendingSubstitute? {
        let characters = Array(input)
        if characters.count < 3 { return nil }

        var currentIndex = 0
        guard characters[currentIndex] == "/" else { return nil }
        currentIndex += 1

        func readSection() -> String? {
            var output: [Character] = []

            while currentIndex < characters.count {
                let character = characters[currentIndex]

                if character == "/" {
                    currentIndex += 1
                    return String(output)
                }

                if character == "\\" {
                    guard currentIndex + 1 < characters.count else {
                        output.append(character)
                        currentIndex += 1
                        continue
                    }

                    let nextCharacter = characters[currentIndex + 1]

                    if nextCharacter == "/" {
                        output.append("/")
                        currentIndex += 2
                        continue
                    }

                    output.append("\\")
                    output.append(nextCharacter)
                    currentIndex += 2
                    continue
                }

                output.append(character)
                currentIndex += 1
            }

            return nil
        }

        guard let pattern = readSection(), !pattern.isEmpty else { return nil }
        guard let replacement = readSection() else { return nil }

        while currentIndex < characters.count, characters[currentIndex].isWhitespace {
            currentIndex += 1
        }

        var isGlobal = false
        if currentIndex < characters.count {
            if characters[currentIndex] == "g" {
                isGlobal = true
                currentIndex += 1
            }

            while currentIndex < characters.count, characters[currentIndex].isWhitespace {
                currentIndex += 1
            }
        }

        if currentIndex < characters.count { return nil }

        return KPendingSubstitute(
            target: target,
            pattern: pattern,
            replacement: replacement,
            isGlobal: isGlobal
        )
    }
    
    // MARK: - Global filter command support

    private struct KPendingGlobal {
        let isInvert: Bool
        let pattern: String
    }

    private var _pendingGlobal: KPendingGlobal? = nil

    func takePendingGlobal() -> (isInvert: Bool, pattern: String)? {
        guard let p = _pendingGlobal else { return nil }
        _pendingGlobal = nil
        return (p.isInvert, p.pattern)
    }

    private func parseGlobalPattern(_ input: String, isInvert: Bool) -> KPendingGlobal? {
        let pattern = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        return KPendingGlobal(isInvert: isInvert, pattern: pattern)
    }
    
    private func reportCommandLineParseError(_ message: String, input: String) {
        KLog.shared.log(id: "commandline", message: "\(message) (\(input))")
        KLogPanel.shared.present()
    }
}
