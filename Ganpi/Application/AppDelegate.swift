//
//  AppDelegate.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    // 起動直後に復元されるウインドウをすべて無効化
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    
    // ファイル指定で起動中かどうかを検知するためのフラグ
    private var launchingWithFiles = false
    
    // 起動時に無題を開くか：OS標準に従い「基本は開く」。
    // ただし、ファイル指定で起動した場合は false を返す（＝無題を出さない）。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return !launchingWithFiles
    }
    
    // ファイル指定での起動を検知
    func application(_ app: NSApplication, open urls: [URL]) {
        launchingWithFiles = true
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }
    
    @IBAction func showSearchPanel(_ sender: Any?) {
        KSearchPanel.shared.show()
    }
    
    @IBAction func showLogPanel(_ sender: Any?) {
        KLogPanel.shared.show()
    }
    
    @IBOutlet private  var _dockMenuFromNib: NSMenu!  // nib 接続（保持は nib 側）
    
    // ActiveでもInactiveでも、開く直前に必ず呼ばれる
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === _dockMenuFromNib else { return }
        rebuildDockMenu()
    }
    
    // Active時だけ OS が呼ぶ（呼ばれたら一応詰め替えて同じインスタンスを返す）
    @objc(applicationDockMenu:)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        rebuildDockMenu()
        return _dockMenuFromNib
    }
    
    private func rebuildDockMenu() {
        guard let menu = _dockMenuFromNib else { return }
        menu.removeAllItems()
        var added = 0
        for w in NSApp.windows {
            if w.level != .normal { continue }
            if w.isExcludedFromWindowsMenu { continue }
            if w is NSPanel { continue }
            if w.isSheet { continue }
            let item = NSMenuItem(
                title: dockTitle(for: w),
                action: #selector(selectWindowFromDockMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = w
            if w.isMiniaturized { item.toolTip = "Minimized" }
            menu.addItem(item)
            added += 1
        }
        if added == 0 {
            let info = NSMenuItem(title: "No document windows", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
    }
    
    @objc private func selectWindowFromDockMenu(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? NSWindow else { return }
        NSApp.activate(ignoringOtherApps: false)
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }
    
    private func dockTitle(for w: NSWindow) -> String {
        var s: String = {
            if let d = w.windowController?.document as? NSDocument { return d.displayName }
            let t = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Untitled" : t
        }()
        //if w.isDocumentEdited { s = "● " + s }
        if w.isMiniaturized { s += " (Minimized)" }
        return s
    }
    
}

