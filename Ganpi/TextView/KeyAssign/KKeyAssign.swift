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
    
    static func fromSetting(_ raw: String) -> KEditMode {
        switch raw.lowercased() {
        case "normal": return .normal
        case "edit": return .edit
        default: return .normal
        }
    }
}

enum KKeyAssignKind {
    case ganpi
    case emacs
    case vi
    case system
    case user
    
    var fileName: String? {
        switch self {
        case .ganpi: return "keymap_ganpi"
        case .emacs: return "keymap_emacs"
        case .vi:    return "keymap_vi"
        case .system: return nil
        case .user:   return nil
        }
    }
    
    static func fromSetting(_ raw: String) -> KKeyAssignKind? {
        switch raw.lowercased() {
        case "ganpi": return .ganpi
        case "emacs": return .emacs
        case "vi":    return .vi
        case "system": return .system
        case "user":   return .user
        default:       return nil
        }
    }

}

// MARK: - Actions (strict & type-safe)

struct KShortCut {
    var keys: [KKeyStroke]
    var actions: [KUserAction]
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
    private var _editmodeShortcuts:   [KShortCut] = []
    
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
        mode == .normal ? _normalmodeShortcuts : _editmodeShortcuts
    }
    
    var hasStoredKeyStrokes: Bool { !_storedKeyStrokes.isEmpty }
    
    init() {
        // Load bundled keymap on launch if present
        /*if let path = Bundle.main.path(forResource: "keymap_ganpi", ofType: "ini") {
            loadUserKeymap(at: URL(fileURLWithPath: path))
        }*/
        load()
    }
    
    func load() {
        let assign = KPreference.shared.keyAssign()

        let url: URL?
        switch assign {
        case .ganpi:
            url = Bundle.main.url(forResource: "keymap_ganpi", withExtension: "ini")
        case .emacs:
            url = Bundle.main.url(forResource: "keymap_emacs", withExtension: "ini")
        case .vi:
            url = Bundle.main.url(forResource: "keymap_vi", withExtension: "ini")

        case .user:
            guard let keymapURL = KAppPaths.preferenceFileURL(fileName: "keymap.ini", createDirectoryIfNeeded: true) else {
                KLog.shared.log(id: "keymap", message: "Preferences directory not available.")
                url = nil
                break
            }

            if FileManager.default.fileExists(atPath: keymapURL.path) {
                url = keymapURL
            } else {
                // keymap.ini は「全置換」なので、自動生成はしない。無ければデフォルト運用。
                url = nil
            }

        case .system:
            url = nil
        }

        _normalmodeShortcuts.removeAll()
        _editmodeShortcuts.removeAll()

        if let url = url {
            loadUserKeymap(at: url)
        }

        reset()
    }
    
    func setShortcuts(with shortcuts:[KShortCut], for mode:KEditMode = .normal) {
        log("setShortcuts")
        switch mode {
        case .normal: _normalmodeShortcuts = shortcuts
        case .edit:   _editmodeShortcuts   = shortcuts
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
    
    private func executeActions(_ actions: [KUserAction]) {
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
