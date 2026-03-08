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
        
        let search = _findField.stringValue
        
        if !search.isEmpty {
            KSearchPanel.shared.searchString = search
            NSApp.sendAction(#selector(KTextView.searchAlternateAction), to: nil, from: self)
            _findField.stringValue = ""
            window?.orderOut(nil)
        }
        
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
    
}
