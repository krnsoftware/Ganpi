//
//  KLogPanelController.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/04,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import Cocoa

final class KLogPanel: NSWindowController, NSWindowDelegate {
    
    static let shared: KLogPanel = .init(windowNibName: "LogPanel")

    // MARK: - Outlets

    @IBOutlet private weak var _textView: NSTextView!   // xibで接続（必須）

    // MARK: - 状態

    private var _lastCount = 0                          // 既に表示した件数
    private let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - ライフサイクル

    override func windowDidLoad() {
        super.windowDidLoad()
        
        guard let panel = window else { log("window = nil.",from:self); return }
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        

        // NSTextView の見た目と挙動を最小設定（黒背景／薄グレー文字／選択コピー可）
        _textView.isEditable = false
        _textView.isSelectable = true
        _textView.usesFontPanel = false
        _textView.isRichText = false
        _textView.isAutomaticQuoteSubstitutionEnabled = false
        _textView.isAutomaticDashSubstitutionEnabled = false
        _textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        _textView.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        _textView.backgroundColor = .black
        _textView.drawsBackground = true

        // 初回全件表示
        reloadAll()

        // 追記通知を購読
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didAppendLog(_:)),
                                               name: .KLogDidAppend,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 公開操作

    /// 前面表示
    func present() {
        guard let w = window else { log("window is nil.",from:self); return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle() {
        log("toggle",from:self)
        guard let w = window else { log("window is nil.",from:self); return }
        //w.makeKeyAndOrderFront(nil)
        w.isVisible ? w.orderOut(nil) : w.makeKeyAndOrderFront(nil)
    }

    // 「×」ボタンを押されたときの挙動を “隠す” に
    /*
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        log("out!",from:self)
        return false
    }*/
    
    func show() {
        //if window?.screen == nil { window?.center() }
        guard let panel = window else { log("window is nil.",from:self); return}
        panel.makeKeyAndOrderFront(nil)
    }
    
    

    // MARK: - 更新

    /// スナップショットを全描画（MVP: まずは全再描画で十分軽い）
    private func reloadAll() {
        let entries = KLog.shared.snapshot()
        let s = entries.map { formatLine($0) }.joined()
        _textView.string = s
        _lastCount = entries.count
        scrollToBottom()
    }

    /// 追記通知（差分だけ追加）
    @objc private func didAppendLog(_ note: Notification) {
        let entries = KLog.shared.snapshot()
        guard entries.count > _lastCount else { return }

        let delta = entries[_lastCount..<entries.count]
        let appended = delta.map { formatLine($0) }.joined()

        if let ts = _textView.textStorage {
            ts.beginEditing()
            ts.append(NSAttributedString(string: appended,
                                         attributes: [
                                            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
                                         ]))
            ts.endEditing()
        } else {
            _textView.string += appended
        }

        _lastCount = entries.count
        scrollToBottom()
    }

    // MARK: - ユーティリティ

    private func formatLine(_ e: KLogEntry) -> String {
        "[\(_dateFormatter.string(from: e.date))][\(e.id)] \(e.message)\n"
    }

    private func scrollToBottom() {
        _textView.scrollRangeToVisible(NSRange(location: _textView.string.count, length: 0))
    }
}
