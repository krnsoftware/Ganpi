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
        let string = textStorage[string: selection]
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
        guard let storage = textStorage as? KTextStorageProtocol else { log("textstorage is not writable.", from:self); return }
        let selection = selectionRange
        storage.replaceString(in: selection, with: string)
        selectionRange = selection.lowerBound..<selection.lowerBound + string.count
    }
    
}
