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
    
    // 全てのDocumentを保存せずに閉じてアプリケーションを終了する。
    @IBAction func terminateWithoutStore(_ sender: Any?) {
        for doc in NSDocumentController.shared.documents {
            if let kdoc = doc as? Document {
                kdoc.performCloseWithoutStore(self)
            }
        }
        NSApp.terminate(self)
    }
    
    @IBAction func reloadPreferences(_ sender: Any?) {
        KPreference.shared.load()
        KKeyAssign.shared.load()
        
        for doc in NSDocumentController.shared.documents {
            if let document = doc as? Document {
                // パーサを新しいものに入れ替える。
                document.textStorage.replaceParser(for: document.syntaxType)
            }
        }
    }
    
    // MARK: - Dock menu

    @objc(applicationDockMenu:)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "DockMenu")

        // 最近使ったドキュメント（開いているファイルは除外）
        let openDocURLs = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL })
        let recents = NSDocumentController.shared.recentDocumentURLs
            .filter { !openDocURLs.contains($0) }

        if !recents.isEmpty {
            for url in recents.prefix(10) {
                let item = NSMenuItem(
                    title: url.lastPathComponent,
                    action: #selector(openRecentDocumentFromDock(_:)),
                    keyEquivalent: ""
                )
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                icon.isTemplate = false
                item.image = icon //
                item.representedObject = url
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 新規ドキュメント
        let newItem = NSMenuItem(
            title: "New Document",
            action: #selector(createNewDocumentFromDock(_:)),
            keyEquivalent: ""
        )
        newItem.target = self
        menu.addItem(newItem)

        return menu
    }

    @objc private func openRecentDocumentFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    @objc private func createNewDocumentFromDock(_ sender: NSMenuItem) {
        NSDocumentController.shared.newDocument(nil)
    }
    
}

