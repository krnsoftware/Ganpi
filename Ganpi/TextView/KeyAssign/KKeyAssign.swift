//
//  KKeyAssign.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/21,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Cocoa

class KKeyAssign {
    
    enum KStatusCode {
        case passthrough
        case preserve
        case execute
    }
    
    struct KShortCut {
        var keys: [KKeyStroke]
        var actions: [String]
    }
    
    private var _storedKeyStrokes: [KKeyStroke] = []
    private var _shortcuts: [KShortCut] = []
    private weak var _pendingOwner: NSResponder? = nil
    private var _pendingOwnerID: ObjectIdentifier? = nil
    
    var shortcuts: [KShortCut] {
        set { _shortcuts = newValue }
        get { _shortcuts }
    }
    
    static let shared: KKeyAssign = .init()
    
    var hasStoredKeyStrokes: Bool { _storedKeyStrokes.count > 0 }
    
    init(_ shortcuts:[KShortCut] = defaultKeyAssign) {
        _shortcuts = shortcuts
    }
    
    func reset() { _storedKeyStrokes.removeAll(); _pendingOwner = nil }
    
    func estimateKeyStroke(_ key: KKeyStroke, requester: NSResponder) -> KStatusCode {
        if let owner = _pendingOwner, let oid = _pendingOwnerID, !(owner === requester && oid == ObjectIdentifier(requester)){
            resetPending()
        }
        _pendingOwner = requester
        _pendingOwnerID = ObjectIdentifier(requester)
        
        _storedKeyStrokes.append(key)
        var executeShortcut: KShortCut? = nil
        var hasLongCandidate = false
        
        assingLoop: for shortcut in shortcuts {
            if shortcut.keys.count < _storedKeyStrokes.count { continue }
            for i in 0..<_storedKeyStrokes.count {
                if _storedKeyStrokes[i] != shortcut.keys[i] { continue assingLoop }
            }
            if shortcut.keys.count == _storedKeyStrokes.count { executeShortcut = shortcut }
            hasLongCandidate = true
        }
        if let exec = executeShortcut {
            for action in exec.actions {
                //NSApp.sendAction(Selector(action), to: nil, from: self)
                if let owner = _pendingOwner {
                    owner.doCommand(by: Selector(action))
                }
            }
            reset()
            return .execute
        } else if hasLongCandidate {
            return .preserve
        } else {
            reset()
            return .passthrough
        }
    }
    
    private func resetPending() {
        _pendingOwner = nil
        _pendingOwnerID = nil
        reset()
    }
    
    private static let defaultKeyAssign:[KShortCut] = [
        .init(keys:[KKeyStroke("A", [.control])], actions: ["moveToBeginningOfParagraph:"]),
        //.init(keys:[KKeyStroke("S", [.control])], actions: ["moveBackward:"]),
        .init(keys:[KKeyStroke("S", [.control])], actions: ["moveLeft:"]),
        //.init(keys:[KKeyStroke("D", [.control])], actions: ["moveForward:"]),
        .init(keys:[KKeyStroke("D", [.control])], actions: ["moveRight:"]),
        .init(keys:[KKeyStroke("F", [.control])], actions: ["moveToEndOfParagraph:"]),
        .init(keys:[KKeyStroke("E", [.control])], actions: ["moveUp:"]),
        .init(keys:[KKeyStroke("X", [.control])], actions: ["moveDown:"]),
        .init(keys:[KKeyStroke("R", [.control])], actions: ["pageUp:"]),
        .init(keys:[KKeyStroke("C", [.control])], actions: ["pageDown:"]),
        .init(keys:[KKeyStroke("H", [.control])], actions: ["deleteBackward:"]),
        .init(keys:[KKeyStroke("G", [.control])], actions: ["deleteForward:"]),
        //.init(keys:[KKeyStroke("Y", [.control])], actions: ["deleteToEndOfParagraph:"]),
        //.init(keys:[KKeyStroke("Y", [.control])], actions: ["yank:"]),
        .init(keys:[KKeyStroke("Y", [.option])], actions: ["yankPop:"]),
        .init(keys:[KKeyStroke("Y", [.option, .shift])], actions: ["yankPopReverse:"]),
        .init(keys:[KKeyStroke("I", [.control])], actions: ["insertTab:"]),
        .init(keys:[KKeyStroke("M", [.control])], actions: ["insertNewline:"]),
        .init(keys:[KKeyStroke("U", [.control])], actions: ["uppercaseWord:"]),
        .init(keys:[KKeyStroke("L", [.control])], actions: ["lowercaseWord:"]),

        .init(keys:[KKeyStroke("P", [.control])], actions: ["transpose:"]),
/*
        .init(keys:[KKeyStroke.init(keys.leftArrow, [.control])], actions: ["moveDividerUp:"]),
        .init(keys:[KKeyStroke.init(keys.rightArrow, [.control])], actions: ["moveDividerDown:"]),
        .init(keys:[KKeyStroke.init(keys.upArrow, [.control])], actions: ["makeFirstResponderToUpperTextView:"]),
        .init(keys:[KKeyStroke.init(keys.downArrow, [.control])], actions: ["makeFirstResponderToLowerTextView:"]),
*/
        .init(keys:[KKeyStroke("A", [.control, .shift])], actions: ["moveToBeginningOfParagraphAndModifySelection:"]),
        .init(keys:[KKeyStroke("S", [.control, .shift])], actions: ["moveLeftAndModifySelection:"]),
        .init(keys:[KKeyStroke("D", [.control, .shift])], actions: ["moveRightAndModifySelection:"]),
        .init(keys:[KKeyStroke("F", [.control, .shift])], actions: ["moveToEndOfParagraphAndModifySelection:"]),

        .init(keys:[KKeyStroke("Q", [.control]), KKeyStroke("R", [.control])], actions: ["moveToBeginningOfDocument:"]),
        .init(keys:[KKeyStroke("Q", [.control]), KKeyStroke("C", [.control])], actions: ["moveToEndOfDocument:"]),
        .init(keys:[KKeyStroke("Q", [.control]), KKeyStroke("1", [.control])], actions: ["removeSplit:"]),
        .init(keys:[KKeyStroke("Q", [.control]), KKeyStroke("2", [.control])], actions: ["splitHorizontally:"]),
        .init(keys:[KKeyStroke("Q", [.control]), KKeyStroke("3", [.control])], actions: ["focusForwardTextView:"])
        
        
    ]
}


