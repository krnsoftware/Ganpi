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
    
    func show(at point:CGPoint) {
        var origin = point
        if let frameHeight = window?.frame.height {
            origin.y -= frameHeight / 2
        }
        guard let win = window else { log("#01", from:self); return }
        
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
    
}
