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
    
    
    // MARK: - Yanks
    
    @IBAction func yankPop(_ sender: Any?) {
        log("here!",from:self)
    }
    
    @IBAction func yankPopReverse(_ sender: Any?) {
        log("here!",from:self)
    }
    
    
}
