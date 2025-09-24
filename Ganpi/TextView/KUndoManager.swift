//
//  KUndoManager.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/24,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

struct KUndoUnit {
    let range: Range<Int>
    let oldCharacters: [Character]
    let newCharacters: [Character]
}

enum KUndoAction {
    case undo
    case redo
    case none
}

class KUndoManager {
    private weak var _storage:KTextStorage?
    
    private var _history: KRingBuffer<KUndoUnit> = .init(capacity: 5000)
    private var _undoDepth: Int = 0
    private var _undoActions: KRingBuffer<KUndoAction> = .init(capacity: 2)
    
    init(with storage:KTextStorage) {
        _storage = storage
        
        _undoActions.append(.none)
        _undoActions.append(.none)
    }
    
    func register(range: Range<Int>, oldCharacters:[Character], newCharacters:[Character]) {
        if _undoActions.element(at: 0)! == .none {
        //if let action = _undoActions.element(at: 0), action == .none {
            let undoUnit = KUndoUnit(range: range, oldCharacters: oldCharacters, newCharacters: newCharacters)
            if _undoActions.element(at: 1)! != .none {
                _history.removeNewerThan(index: _undoDepth)
                _undoDepth = 0
            }
            
            _history.append(undoUnit)
        }
        log("_undoDepth:\(_undoDepth), _history.count:\(_history.count)",from:self)
    }
    
    func undo() {
        guard _undoDepth < _history.count else {
            NSSound.beep()
            //log("_undoDepth:\(_undoDepth), _history.count:\(_history.count)",from:self)
            log("undo: no more history", from: self)
            return
        }

        _undoActions.append(.undo)

        guard let undoUnit = _history.element(at: _undoDepth) else { log("undo: failed to get undoUnit at \(_undoDepth)", from: self); return }
        guard let storage = _storage else { log("_storage is nil.", from: self); return }

        let range = undoUnit.range.lowerBound..<undoUnit.range.lowerBound + undoUnit.newCharacters.count
        storage.replaceCharacters(in: range, with: undoUnit.oldCharacters)

        _undoDepth += 1
    }
    
    func redo() {
        guard _undoDepth > 0 else {
            NSSound.beep()
            log("redo: no redo available", from: self)
            return
        }

        _undoActions.append(.redo)

        let redoIndex = _undoDepth - 1

        guard let undoUnit = _history.element(at: redoIndex) else { log("redo: failed to get redoUnit at \(redoIndex)", from: self); return }
        guard let storage = _storage else { log("_storage is nil.", from: self); return }

        storage.replaceCharacters(in: undoUnit.range, with: undoUnit.newCharacters)

        _undoDepth -= 1
    }
    
    func canUndo() -> Bool {
        return _undoDepth < _history.count
    }

    func canRedo() -> Bool {
        return _undoDepth > 0
    }
    
    func resetUndoHistory() {
        _history.reset()
        _undoDepth = 0
    }
    
    func appendUndoAction(with action: KUndoAction) {
        _undoActions.append(action)
    }
}
