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
        
        performUserActions(actions, textView: textView, viewController: viewController)
        
        return NSNumber(value: true)
    }
    
    private func performUserActions(_ actions: [KUserAction], textView: KTextView, viewController: KViewController) {
        for action in actions {
            switch action {
            case .selector(let name):
                performSelectorAction(name, textView: textView, viewController: viewController)
                
            case .command:
                textView.performUserActions([action])
            }
        }
    }
    
    private func performSelectorAction(_ name: String, textView: KTextView, viewController: KViewController) {
        let selector = Selector(name + ":")
        
        if textView.responds(to: selector) {
            textView.doCommand(by: selector)
            return
        }
        
        if viewController.responds(to: selector) {
            NSApp.sendAction(selector, to: viewController, from: textView)
            return
        }
        
        if let document = viewController.document, document.responds(to: selector) {
            NSApp.sendAction(selector, to: document, from: textView)
            return
        }
        
        if let appDelegate = NSApp.delegate, appDelegate.responds(to: selector) {
            NSApp.sendAction(selector, to: appDelegate, from: textView)
            return
        }
        
        if NSApp.responds(to: selector) {
            NSApp.sendAction(selector, to: NSApp, from: textView)
            return
        }
        
        NSApp.sendAction(selector, to: nil, from: textView)
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
