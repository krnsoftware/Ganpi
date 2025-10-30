//
//  KKeyAssign.swift
//  Ganpi - macOS Text Editor
//
//  Strict literal matching. No modifier carry-over/ignore.
//  Normal can accept bare first key if it is explicitly defined.
//  No timer. No ambiguity handling at runtime.
//

import Cocoa

enum KEditMode {
    case normal
    case edit
}

// MARK: - Actions (strict & type-safe)

enum KAction {
    case selector(String)        // e.g. "moveRight" (no trailing ":")
    case command(KCommand)       // e.g. .execute("/usr/bin/sort")
}

enum KCommand {
    case load(String)            // load[PATH] or [PATH]
    case execute(String)         // execute[PATH]
}

struct KShortCut {
    var keys: [KKeyStroke]
    var actions: [KAction]
}

// MARK: - Key Assign Core

class KKeyAssign {
    
    enum KStatusCode {
        case passthrough   // let system/Responder handle it
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
    
    // MARK: - Matching (strict, no timer)
    //
    // - Exact match -> execute
    // - Prefix-only  -> preserve (no timeout; wait indefinitely)
    // - No match     -> passthrough (normal) / block (edit)
    //
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
        let table = shortcuts
        
        var hasExact = false
        var hasPrefixOnly = false
        var exactShortcut: KShortCut? = nil
        
        outer: for sc in table {
            if sc.keys.count < _storedKeyStrokes.count { continue }
            for i in 0..<_storedKeyStrokes.count {
                if _storedKeyStrokes[i] != sc.keys[i] { continue outer }
            }
            if sc.keys.count == _storedKeyStrokes.count {
                hasExact = true
                exactShortcut = sc
            } else {
                hasPrefixOnly = true
            }
        }
        
        if hasExact && !hasPrefixOnly {
            // exact only -> execute now
            executeActions(exactShortcut!.actions)
            resetSequence()
            return .execute
        }
        if hasExact && hasPrefixOnly {
            // exact & longer candidates -> preserve (no timer; spec keeps waiting)
            log("Preserve (exact & longer candidates) buffer=\(_storedKeyStrokes)")
            return .preserve
        }
        if !hasExact && hasPrefixOnly {
            // prefix only -> preserve (no timer)
            log("Preserve (prefix only) buffer=\(_storedKeyStrokes)")
            return .preserve
        }
        
        // no match
        //log("No match; sequence cleared (buffer was \(_storedKeyStrokes))")
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
        for a in actions {
            switch a {
            case .selector(let name):
                //let selector = Selector(name + ":")
                owner.doCommand(by: Selector(name + ":"))
                //_ = NSApp.sendAction(selector, to: nil, from: self)
            case .command(let cmd):
                switch cmd {
                case .load(let path):
                    log("load[\(path)] (stub)")
                case .execute(let path):
                    log("execute[\(path)] (stub)")
                }
            }
        }
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
