//
//  KScriptPerformUserMacroCommand.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/06/08,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Cocoa

@objc(GanpiPerformUserMacroCommand)
final class KScriptPerformUserMacroCommand: NSScriptCommand {
    
    override func performDefaultImplementation() -> Any? {
        guard let macroString = directParameter as? String else {
            setScriptError("Missing user macro string.", number: -1701)
            return NSNumber(value: false)
        }
        
        let trimmedMacroString = macroString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMacroString.isEmpty else {
            setScriptError("The user macro string is empty.", number: -1701)
            return NSNumber(value: false)
        }
        
        let actions = KKeymapLoader.parseActions(from: trimmedMacroString)
        guard !actions.isEmpty else {
            setScriptError("The user macro could not be parsed.", number: -1701)
            return NSNumber(value: false)
        }
        
        guard let viewController = frontDocumentViewController() else {
            setScriptError("The front window is not a document window.", number: -10000)
            return NSNumber(value: false)
        }
        
        guard let textView = viewController.activeTextView() else {
            setScriptError("The front document has no active text view.", number: -10000)
            return NSNumber(value: false)
        }
        
        textView.performUserActions(actions)
        
        return NSNumber(value: true)
    }
    
    private func setScriptError(_ message: String, number: Int) {
        scriptErrorNumber = number
        scriptErrorString = message
    }
    
    private func frontDocumentViewController() -> KViewController? {
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized {
            guard let viewController = window.windowController?.contentViewController as? KViewController else {
                continue
            }
            
            return viewController
        }
        
        return nil
    }
}
