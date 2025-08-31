//
//  KTextView+Actions.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/08/15.
//

import AppKit

extension KTextView {
    
    // MARK: - Search actions
    
    @IBAction func setSearchStringWithSelectedString(_ sender: Any?) {
        if selectionRange.isEmpty { NSSound.beep(); return }
        
        KSearchPanel.shared.searchString = String( textStorage[selectionRange] ?? [])
    }
    
    @IBAction func searchNextAction(_ sender: Any?) {
        search(for: .forward)
    }
    
    @IBAction func searchPrevAction(_ sender: Any?) {
        search(for: .backward)
    }
    
    @IBAction func replaceAllAction(_ sender: Any?) {
        replaceAll()
    }
    
    @IBAction func replaceAction(_ sender: Any?) {
        replace()
    }
    
    @IBAction func replaceAndFindeAgainAction(_ sender: Any?) {
        replace()
        search(for: .forward)
    }
    
    // MARK: - Font Size actions
    /*
    @IBAction func increaseFontSize(_ sender: Any?) {
        if let storage = textStorage as? KTextStorage {
            storage.fontSize = storage.fontSize + 1
        }
    }
    
    @IBAction func decreaseFontSize(_ sender: Any?) {
        if let storage = textStorage as? KTextStorage {
            if storage.fontSize <= 5 { return }
            storage.fontSize = storage.fontSize - 1
        }
    }
    
    @IBAction func showFontSizeSheet(_ sender: Any?) {
        guard let documentWindow = window,
              let textStorage = textStorage as? KTextStorage else { return }

        KPrompt.number(title: "Font Size",
                       message: "",
                       defaultValue: Int(textStorage.fontSize),
                       min: 5, max: 100,
                       in: documentWindow) { [weak textStorage] value in
            defer {
                documentWindow.makeFirstResponder(self)
            }
            if let size = value {
                let clampedSize = max(5, size)
                textStorage?.fontSize = CGFloat(clampedSize)
            } else {
                NSSound.beep()
            }
        }
    }*/
    
    
    
    // MARK: - Undo actions
    
    @IBAction func undo(_ sender: Any?) {
        textStorage.undo()
    }
    
    @IBAction func redo(_ sender: Any?) {
        textStorage.redo()
    }
    
    
}
