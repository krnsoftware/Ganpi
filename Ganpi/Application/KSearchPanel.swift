//
//  KSearchPanel.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import AppKit

struct KDefaultSearchKey {
    static let ignoreCase = "searchIgnoreCase"
    static let useRegex = "searchUseRegex"
    static let selectionOnly = "searchSelectionOnly"
}

/// 検索パネル（XIB: "SearchPanel.xib"）
final class KSearchPanel: NSWindowController {

    // MARK: - Singleton
    static let shared = KSearchPanel(windowNibName: "SearchPanel")

    // MARK: - Outlets (XIB 接続)
    @IBOutlet private weak var findField: NSTextField!
    @IBOutlet private weak var replaceField: NSTextField!

    @IBOutlet private weak var searchButton: NSButton!      // Default (Return)
    @IBOutlet private weak var cancelButton: NSButton!      // Esc
    @IBOutlet private weak var replaceAllButton: NSButton!

    // MARK: - Backing Store（未ロード時の保持）
    private var _searchString:  String = ""
    private var _replaceString: String = ""
    
    

    // MARK: - 外部公開（KTextView 等から参照・設定）
    @objc dynamic var searchString: String {
        get { isWindowLoaded ? findField.stringValue : _searchString }
        set {
            _searchString = newValue
            if isWindowLoaded { findField.stringValue = newValue }
        }
    }
    @objc dynamic var replaceString: String {
        get { isWindowLoaded ? replaceField.stringValue : _replaceString }
        set {
            _replaceString = newValue
            if isWindowLoaded { replaceField.stringValue = newValue }
        }
    }
    

    // MARK: - Lifecycle
    override func windowDidLoad() {
        super.windowDidLoad()
        
        // 既定キー
        searchButton.keyEquivalent = "\r"      // Return = Search
        cancelButton.keyEquivalent = "\u{1b}"  // Esc = Cancel

        // ★ バックストア → UI へ初期反映
        findField.stringValue    = _searchString
        replaceField.stringValue = _replaceString

        // 任意：編集終了でバックストアへ戻す
        findField.target = self;     findField.action = #selector(_fieldsEdited)
        replaceField.target = self;  replaceField.action = #selector(_fieldsEdited)
    }

    /// 表示（メニュー等から呼ぶ）
    func show() {
        if window?.screen == nil { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(findField)  // 初期フォーカス
    }

    // MARK: - Actions
    
    @IBAction private func actCancel(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - UI→バックストア 同期
    @objc private func _fieldsEdited(_ sender: Any?) {
        _searchString  = findField.stringValue
        _replaceString = replaceField.stringValue
    }
}
