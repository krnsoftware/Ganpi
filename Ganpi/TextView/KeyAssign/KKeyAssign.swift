//
//  KKeyAssign.swift
//  Ganpi - macOS Text Editor
//
//  Strict literal matching. No modifier carry-over/ignore.
//  Normal can accept bare first key if it is explicitly defined.
//  No timer. No ambiguity handling at runtime.
//

import Cocoa

// Ganpi edit modes.
enum KEditMode {
    case normal  // insert characters and functions.
    case edit    // functional key sequence only.
}

// MARK: - Actions (strict & type-safe)

struct KShortCut {
    var keys: [KKeyStroke]
    var actions: [KAction]
}

// MARK: - Key Assign Core

class KKeyAssign {
    
    enum KStatusCode {
        case passthrough   // let system/responder handle it
        case preserve      // waiting for further keystrokes (prefix-only)
        case execute       // run actions
        case block         // block in edit mode
    }
    
    static let shared: KKeyAssign = .init()
    
    // Tables
    private var _normalmodeShortcuts: [KShortCut] = []
    private var _editmodeShortCuts:   [KShortCut] = []
    
    // Sequence buffer & mode/owner
    private var _storedKeyStrokes: [KKeyStroke] = []
    private var _mode: KEditMode = .normal
    
    private weak var _pendingOwner: NSResponder? = nil
    private var _pendingOwnerID: ObjectIdentifier? = nil
    
    private var mode: KEditMode {
        get { _mode }
        set {
            if _mode != newValue { resetSequence() }
            _mode = newValue
        }
    }
    
    var shortcuts: [KShortCut] {
        mode == .normal ? _normalmodeShortcuts : _editmodeShortCuts
    }
    
    var hasStoredKeyStrokes: Bool { !_storedKeyStrokes.isEmpty }
    
    init() {
        // Load bundled keymap on launch if present
        if let path = Bundle.main.path(forResource: "keymap_ganpi", ofType: "ini") {
            loadUserKeymap(at: URL(fileURLWithPath: path))
        }
    }
    
    func setShortcuts(with shortcuts:[KShortCut], for mode:KEditMode = .normal) {
        switch mode {
        case .normal: _normalmodeShortcuts = shortcuts
        case .edit:   _editmodeShortCuts   = shortcuts
        }
    }
    
    func reset() {
        resetSequence()
        _pendingOwner = nil
        _pendingOwnerID = nil
    }
    
    // MARK: - Matching
    
    func estimateKeyStroke(_ key: KKeyStroke, requester: NSResponder, mode: KEditMode = .normal) -> KStatusCode {
        // owner change -> drop pending
        if let owner = _pendingOwner, let oid = _pendingOwnerID,
           !(owner === requester && oid == ObjectIdentifier(requester)) {
            resetPending()
            log("Sequence buffer reset due to owner change")
        }
        _pendingOwner   = requester
        _pendingOwnerID = ObjectIdentifier(requester)
        self.mode = mode
        
        // append
        _storedKeyStrokes.append(key)
        
        var hasPrefix = false
        
        for shortcut in shortcuts {
            if shortcut.keys.starts(with: _storedKeyStrokes) {
                if shortcut.keys.count == _storedKeyStrokes.count {
                    executeActions(shortcut.actions)
                    resetSequence()
                    return .execute
                } else {
                    hasPrefix = true
                }
            }
        }
        
        if hasPrefix {
            return .preserve
        }
        
       resetSequence()
       return (mode == .edit) ? .block : .passthrough
        
    }
    
    // MARK: - Helpers
    
    private func resetPending() {
        _pendingOwner = nil
        _pendingOwnerID = nil
        resetSequence()
    }
    
    private func resetSequence() {
        _storedKeyStrokes.removeAll()
    }
    
    private func executeActions(_ actions: [KAction]) {
        guard let owner = _pendingOwner else {
            log("No owner to receive actions")
            return
        }
        owner.perform(#selector(KTextView.performUserActions(_:)), with: actions)
    }
    
    
}

// MARK: - User Keymap Loader hook

extension KKeyAssign {
    func loadUserKeymap(at url: URL) {
        do {
            let bundle = try KKeymapLoader.load(from: url)
            setShortcuts(with: bundle.normal, for: .normal)
            setShortcuts(with: bundle.edit, for: .edit)
            log("User keymap loaded successfully: \(url.lastPathComponent)")
        } catch {
            log("Failed to load user keymap: \(error.localizedDescription)")
        }
    }
}
