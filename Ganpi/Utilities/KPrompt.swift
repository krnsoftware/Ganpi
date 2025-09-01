//
//  Prompt.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/08/28.
//


import Cocoa

enum KPrompt {
    /// シートで整数入力を促す（OKで Int、キャンセルで nil）
    static func number(title: String,
                       message: String,
                       defaultValue: Int,
                       min: Int? = nil,
                       max: Int? = nil,
                       in window: NSWindow,
                       completion: @escaping (Int?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: "\(defaultValue)")
        textField.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        textField.alignment = .right

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        if let min { formatter.minimum = NSNumber(value: min) }
        if let max { formatter.maximum = NSNumber(value: max) }
        textField.formatter = formatter

        alert.accessoryView = textField

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn,
               let number = formatter.number(from: textField.stringValue)?.intValue {
                completion(number)
            } else {
                completion(nil)
            }
        }

        // フォーカスと選択を遅延で確実に
        DispatchQueue.main.async {
            window.makeFirstResponder(textField)
            textField.selectText(nil)
        }
    }

    /// 参考：アプリモーダルで同期取得したい場合
    @discardableResult
    static func numberModal(title: String,
                            message: String,
                            defaultValue: Int,
                            min: Int? = nil,
                            max: Int? = nil) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: "\(defaultValue)")
        textField.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        textField.alignment = .right

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        if let min { formatter.minimum = NSNumber(value: min) }
        if let max { formatter.maximum = NSNumber(value: max) }
        textField.formatter = formatter

        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
              let number = formatter.number(from: textField.stringValue)?.intValue
        else { return nil }
        return number
    }
}
