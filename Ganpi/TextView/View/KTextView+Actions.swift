//
//  KTextView+Actions.swift
//  Ganpi
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
        KSearchPanel.shared.close()
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
    
    
    
    // MARK: - Undo actions
    
    @IBAction func undo(_ sender: Any?) {
        textStorage.undo()
    }
    
    @IBAction func redo(_ sender: Any?) {
        textStorage.redo()
    }
    
    // MARK: - Color treatment
    
    // Show Color Panel.
    // If you press down a option key in calling this function, show alpha value.
    @IBAction func showColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        let selection = selectionRange
        //let string = textStorage[string: selection]
        let string = textStorage.string(in: selection)
        let isOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        panel.showsAlpha = isOption ? true : false
        
        if  let color = NSColor(hexString: string) {
            panel.color = color
        }
        
        panel.isContinuous = true
        panel.orderFront(self)
    }
    
    // insert the color string to selection. Basically #RRGGBB, if show panel.showAlpha, #RRGGBBAA.
    @IBAction func changeColor(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { log("sender is not NSColorPanel.", from:self); return }
        guard let string = panel.color.toHexString(includeAlpha: panel.showsAlpha) else { log("string is nil.", from:self); return }
        //guard let storage = textStorage as? KTextStorageProtocol else { log("textstorage is not writable.", from:self); return }

        let selection = selectionRange
        textStorage.replaceString(in: selection, with: string)
        selectionRange = selection.lowerBound..<selection.lowerBound + string.count
    }
    
    // MARK: - Unicode Normalization.
    
    @IBAction func doNFC(_ sender: Any?) {
        selectedString = selectedString.precomposedStringWithCanonicalMapping
    }
    
    @IBAction func doNFKC(_ sender: Any?) {
        selectedString = selectedString.precomposedStringWithCompatibilityMapping
    }
    
    // MARK: - Surround Selection.
    
    @IBAction func surroundSelectionWithDoubleQuote(_ sender: Any?) {
        surroundSelection(left: "\"", right: "\"")
    }
    
    @IBAction func surroundSelectionWithSingleQuote(_ sender: Any?) {
        surroundSelection(left: "'", right: "'")
    }
    
    @IBAction func surroundSelectionWithParen(_ sender: Any?) {
        surroundSelection(left:"(", right:")")
    }
    
    @IBAction func surroundSelectionWithBlacket(_ sender: Any?) {
        surroundSelection(left:"[", right:"]")
    }
    
    @IBAction func surroundSelectionWithBrace(_ sender: Any?) {
        surroundSelection(left:"{", right:"}")
    }
    
    private func surroundSelection(left:String, right:String) {
        selectedString = left + selectedString + right
    }
    
    // MARK: - URL Encode/Decode
    
    @IBAction func urlEncode(_ sender: Any?) {
        if let encoded = selectedString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            selectedString = encoded
            return
        }
        NSSound.beep()
    }
    
    @IBAction func urlDecode(_ sender: Any?) {
        if let encoded = selectedString.removingPercentEncoding {
            selectedString = encoded
            return
        }
        NSSound.beep()
    }
    
    // MARK: - Base64 Encode/Decode
    
    @IBAction func base64Encode(_ sender: Any?) {
        if let data = selectedString.data(using: .utf8) {
            selectedString = data.base64EncodedString()
            return
        }
        NSSound.beep()
    }
    
    @IBAction func base64Decode(_ sender: Any?) {
        if let data = Data(base64Encoded: selectedString),
           let decoded = String(data: data, encoding: .utf8) {
            selectedString = decoded
            return
        }
        NSSound.beep()
    }
    
    // MARK: - Hiragana <-> Katakana
    
    @IBAction func hiraganaToKatakana(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.hiraganaToKatakana, reverse: false) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    @IBAction func katakanaToHiragana(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.hiraganaToKatakana, reverse: true) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    @IBAction func fullWidthToHalfWidth(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.fullwidthToHalfwidth, reverse: false) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    @IBAction func halfWidthToFullWidth(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.fullwidthToHalfwidth, reverse: true) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    //MARK: - Encrypt.
    
    @IBAction func rot13(_ sender: Any?) {
        let text = selectedString
        let transform: (Character) -> Character = {
            guard let ascii = $0.asciiValue else { return $0 }
            switch ascii {
            case 65...90:  return Character(UnicodeScalar(65 + (ascii - 65 + 13) % 26))
            case 97...122: return Character(UnicodeScalar(97 + (ascii - 97 + 13) % 26))
            default:       return $0
            }
        }
        selectedString = String(text.map(transform))
    }
    
    
     
}
