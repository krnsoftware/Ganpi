//
//  KTextField.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/12/05,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

class KTextField: NSTextField {

    // Option+Return / Option+Tab を文字として挿入する
    override func keyDown(with event: NSEvent) {
        let hasOption = event.modifierFlags.contains(.option)

        if hasOption {
            if event.keyCode == KC.returnKey {
                insertCharacter("\n")
                return
            }
            if event.keyCode == KC.tab {
                insertCharacter("\t")
                return
            }
        }

        super.keyDown(with: event)
    }

    // 現在のエディタに文字を挿入する補助
    private func insertCharacter(_ string: String) {
        if let editor = currentEditor() {
            editor.insertText(string)
        }
    }
}
