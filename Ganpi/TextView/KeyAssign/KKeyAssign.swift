//
//  KKeyAssign.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/21,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
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

enum KEditMode {
    case normal
    case edit
}

class KKeyAssign {
    
    enum KStatusCode {
        case passthrough   // システム/Responder に流す
        case preserve      // さらなるキー入力を待つ（多段ストロークの途中）
        case execute       // 対応アクションを実行
        case block         // Editモード時などでブロック
    }
    
    struct KShortCut {
        var keys: [KKeyStroke]
        var actions: [String]   // セレクタ名（":" 必須）
    }
    
    static let shared: KKeyAssign = .init()
    
    private var _normalmodeShortcuts: [KShortCut] = []//defaultNormalModeKeyAssign
    private var _editmodeShortCuts: [KShortCut]   = []//defaultEditModeKeyAssign
    
    private var _storedKeyStrokes: [KKeyStroke] = []
    private var _mode: KEditMode = .normal
    
    // owner（複数テキストビュー間の遷移対策）
    private weak var _pendingOwner: NSResponder? = nil
    private var _pendingOwnerID: ObjectIdentifier? = nil
    
    private var mode: KEditMode {
        get { _mode }
        set {
            // モード変更時は入力中の多段ストロークを破棄
            if _mode != newValue { _storedKeyStrokes.removeAll() }
            _mode = newValue
        }
    }
    
    var shortcuts: [KShortCut] {
        get { mode == .normal ? _normalmodeShortcuts : _editmodeShortCuts }
    }
    
    var hasStoredKeyStrokes: Bool { !_storedKeyStrokes.isEmpty }
    
    init() {
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
    
    func reset() { _storedKeyStrokes.removeAll(); _pendingOwner = nil }
    
    func estimateKeyStroke(_ key: KKeyStroke, requester: NSResponder, mode: KEditMode = .normal) -> KStatusCode {
        // フォーカス移動などでオーナーが変わったらペンディング破棄
        if let owner = _pendingOwner, let oid = _pendingOwnerID, !(owner === requester && oid == ObjectIdentifier(requester)) {
            resetPending()
        }
        _pendingOwner   = requester
        _pendingOwnerID = ObjectIdentifier(requester)
        
        self.mode = mode
        
        _storedKeyStrokes.append(key)
        var executeShortcut: KShortCut? = nil
        var hasLongCandidate = false
        
        assignLoop: for shortcut in shortcuts {
            if shortcut.keys.count < _storedKeyStrokes.count { continue }
            for i in 0..<_storedKeyStrokes.count {
                if _storedKeyStrokes[i] != shortcut.keys[i] { continue assignLoop }
            }
            if shortcut.keys.count == _storedKeyStrokes.count {
                executeShortcut = shortcut
            } else {
                hasLongCandidate = true
            }
        }
        
        if let exec = executeShortcut {
            // 実行（複数アクション対応）
            if let owner = _pendingOwner {
                for action in exec.actions {
                    owner.doCommand(by: Selector(action))
                }
            }
            reset()
            return .execute
        } else if hasLongCandidate {
            // さらなるキー入力待ち
            return .preserve
        } else if mode == .edit {
            // Editモードでは未定義はブロック（文字入力抑止）
            reset()
            return .block
        } else {
            // Normalモードではシステムにパススルー
            reset()
            return .passthrough
        }
    }
    
    private func resetPending() {
        _pendingOwner = nil
        _pendingOwnerID = nil
        reset()
    }
    
    
    // MARK: - 既定キーバインド（Normal）
    /*
    // すべて KC（KKeyCode）ベースで非オプショナル生成
    private static let defaultNormalModeKeyAssign: [KShortCut] = [
        .init(keys: [KKeyStroke(code: KC.a, modifiers: [.control])], actions: ["moveToBeginningOfParagraph:"]),
        .init(keys: [KKeyStroke(code: KC.s, modifiers: [.control])], actions: ["moveLeft:"]),
        .init(keys: [KKeyStroke(code: KC.d, modifiers: [.control])], actions: ["moveRight:"]),
        .init(keys: [KKeyStroke(code: KC.f, modifiers: [.control])], actions: ["moveToEndOfParagraph:"]),
        .init(keys: [KKeyStroke(code: KC.e, modifiers: [.control])], actions: ["moveUp:"]),
        .init(keys: [KKeyStroke(code: KC.x, modifiers: [.control])], actions: ["moveDown:"]),
        .init(keys: [KKeyStroke(code: KC.r, modifiers: [.control])], actions: ["pageUp:"]),
        .init(keys: [KKeyStroke(code: KC.c, modifiers: [.control])], actions: ["pageDown:"]),
        
        .init(keys: [KKeyStroke(code: KC.h, modifiers: [.control])], actions: ["deleteBackward:"]),
        .init(keys: [KKeyStroke(code: KC.g, modifiers: [.control])], actions: ["deleteForward:"]),
        
        .init(keys: [KKeyStroke(code: KC.y, modifiers: [.option])], actions: ["yankPop:"]),
        .init(keys: [KKeyStroke(code: KC.y, modifiers: [.option, .shift])], actions: ["yankPopReverse:"]),
        
        .init(keys: [KKeyStroke(code: KC.i, modifiers: [.control])], actions: ["insertTab:"]),
        .init(keys: [KKeyStroke(code: KC.m, modifiers: [.control])], actions: ["insertNewline:"]),
        
        .init(keys: [KKeyStroke(code: KC.u, modifiers: [.control])], actions: ["uppercaseWord:"]),
        .init(keys: [KKeyStroke(code: KC.l, modifiers: [.control])], actions: ["lowercaseWord:"]),
        
        .init(keys: [KKeyStroke(code: KC.p, modifiers: [.control])], actions: ["toggleCompletionMode:"]),
        
        .init(keys: [KKeyStroke(code: KC.a, modifiers: [.control, .shift])], actions: ["moveToBeginningOfParagraphAndModifySelection:"]),
        .init(keys: [KKeyStroke(code: KC.s, modifiers: [.control, .shift])], actions: ["moveLeftAndModifySelection:"]),
        .init(keys: [KKeyStroke(code: KC.d, modifiers: [.control, .shift])], actions: ["moveRightAndModifySelection:"]),
        .init(keys: [KKeyStroke(code: KC.f, modifiers: [.control, .shift])], actions: ["moveToEndOfParagraphAndModifySelection:"]),
        
        // 2ストローク
        .init(keys: [KKeyStroke(code: KC.q, modifiers: [.control]),
                     KKeyStroke(code: KC.r, modifiers: [.control])],
              actions: ["moveToBeginningOfDocument:"]),
        .init(keys: [KKeyStroke(code: KC.q, modifiers: [.control]),
                     KKeyStroke(code: KC.c, modifiers: [.control])],
              actions: ["moveToEndOfDocument:"]),
        .init(keys: [KKeyStroke(code: KC.q, modifiers: [.control]),
                     KKeyStroke(code: KC.n1, modifiers: [.control])],
              actions: ["removeSplit:"]),
        .init(keys: [KKeyStroke(code: KC.q, modifiers: [.control]),
                     KKeyStroke(code: KC.n2, modifiers: [.control])],
              actions: ["splitHorizontally:"]),
        .init(keys: [KKeyStroke(code: KC.q, modifiers: [.control]),
                     KKeyStroke(code: KC.n3, modifiers: [.control])],
              actions: ["focusForwardTextView:"]),
        
        // Ctrl+[ → Editモードへ（Esc 等価：KKeyStroke(event:) で正規化済み）
        .init(keys: [KKeyStroke(code: KC.leftBracket, modifiers: [.control])], actions: ["setEditModeToEdit:"]),
    ]
    
    // MARK: - 既定キーバインド（Edit）
    private static let defaultEditModeKeyAssign: [KShortCut] = [
        .init(keys: [KKeyStroke(code: KC.h)], actions: ["moveLeft:"]),
        .init(keys: [KKeyStroke(code: KC.j)], actions: ["moveDown:"]),
        .init(keys: [KKeyStroke(code: KC.k)], actions: ["moveUp:"]),
        .init(keys: [KKeyStroke(code: KC.l)], actions: ["moveRight:"]),
        
        // Insert（Normalへ戻る）
        .init(keys: [KKeyStroke(code: KC.i)], actions: ["setEditModeToNormal:"]),
    ]
     */
}


// MARK: - User Keymap Loader

extension KKeyAssign {

    /// Load user-defined keymap from INI file and apply to singleton instance.
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
