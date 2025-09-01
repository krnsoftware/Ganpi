import AppKit

/// 検索パネル（XIB: "SearchPanel.xib"）
final class KSearchPanel: NSWindowController {

    // MARK: - Singleton
    static let shared = KSearchPanel(windowNibName: "SearchPanel")

    // MARK: - Outlets (XIB 接続)
    @IBOutlet private weak var findField: NSTextField!
    @IBOutlet private weak var replaceField: NSTextField!
    @IBOutlet private weak var ignoreCaseBtn: NSButton!
    @IBOutlet private weak var useRegexBtn: NSButton!

    @IBOutlet private weak var searchButton: NSButton!      // Default (Return)
    @IBOutlet private weak var cancelButton: NSButton!      // Esc
    @IBOutlet private weak var replaceAllButton: NSButton!

    // MARK: - Backing Store（未ロード時の保持）
    private var _searchString:  String = ""
    private var _replaceString: String = ""
    private var _ignoreCase:    Bool   = true
    private var _useRegex:      Bool   = false
    
    

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
    @objc dynamic var ignoreCase: Bool {
        get { isWindowLoaded ? (ignoreCaseBtn.state == .on) : _ignoreCase }
        set {
            _ignoreCase = newValue
            if isWindowLoaded { ignoreCaseBtn.state = newValue ? .on : .off }
        }
    }
    @objc dynamic var useRegex: Bool {
        get { isWindowLoaded ? (useRegexBtn.state == .on) : _useRegex }
        set {
            _useRegex = newValue
            if isWindowLoaded { useRegexBtn.state = newValue ? .on : .off }
        }
    }

    // MARK: - Lifecycle
    override func windowDidLoad() {
        super.windowDidLoad()
        guard let p = window as? NSPanel else { return }
        
        // パネル設定
        /*
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.title = "Find"
        p.collectionBehavior.insert(.fullScreenAuxiliary)
         */
        
        // 既定キー
        searchButton.keyEquivalent = "\r"      // Return = Search
        cancelButton.keyEquivalent = "\u{1b}"  // Esc = Cancel

        // ★ バックストア → UI へ初期反映
        findField.stringValue    = _searchString
        replaceField.stringValue = _replaceString
        ignoreCaseBtn.state      = _ignoreCase ? .on : .off
        useRegexBtn.state        = _useRegex ? .on : .off

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

    // MARK: - Actions（XIB の Sent Actions を接続）
    /*
    @IBAction private func actSearch(_ sender: Any?) {
        NSApp.sendAction(#selector(KTextView.search(_:)), to: nil, from: sender)
    }
    @IBAction private func actSearchPrev(_ sender: Any?) {
        NSApp.sendAction(#selector(KTextView.searchBackward(_:)), to: nil, from: sender)
    }
    @IBAction private func actReplaceAll(_ sender: Any?) {
        NSApp.sendAction(#selector(KTextView.searchReplaceAll(_:)), to: nil, from: sender)
    }*/
    @IBAction private func actCancel(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - UI→バックストア 同期（任意）
    @objc private func _fieldsEdited(_ sender: Any?) {
        _searchString  = findField.stringValue
        _replaceString = replaceField.stringValue
        _ignoreCase    = (ignoreCaseBtn.state == .on)
        _useRegex      = (useRegexBtn.state == .on)
    }
}
