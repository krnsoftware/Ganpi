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
        
    override func windowDidLoad() {
        _findField.target = self
        _findField.action = #selector(fieldEdited)
    }
    
    func show() {
        if window?.screen == nil { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(_findField)  // initial focus.
        _findField.stringValue = KSearchPanel.shared.searchString

    }
    
    override func cancelOperation(_ sender: Any?) {
        actCancel(sender)
    }

    
    @objc private func fieldEdited(_ sender: Any?) {
        
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
