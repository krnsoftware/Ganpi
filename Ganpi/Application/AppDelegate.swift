//
//  AppDelegate.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import Cocoa


@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    // ファイル指定で起動中かどうかを検知するためのフラグ
    private var launchingWithFiles = false
    
    private enum FolderKind {
        case scripts
        case applicationSupportRoot
    }

    private func openFolder(_ kind: FolderKind) {
        let fm = FileManager.default

        let url: URL?
        switch kind {
        case .scripts:
            // ~/Library/Application Scripts/<bundle id>/scripts/
            guard let base = try? fm.url(for: .applicationScriptsDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: false) else {
                KLog.shared.log(id: "folders", message: "Application Scripts directory not available.")
                return
            }
            url = base.appendingPathComponent("scripts", isDirectory: true)

        case .applicationSupportRoot:
            guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                KLog.shared.log(id: "folders", message: "Application Support directory not available.")
                return
            }

            let dirName = Bundle.main.bundleIdentifier ?? "ApplicationSupport"
            url = base.appendingPathComponent(dirName, isDirectory: true)
            
        }

        guard let url else { return }

        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            KLog.shared.log(id: "folders", message: "Failed to create directory: \(url.path)")
            return
        }

        NSWorkspace.shared.open(url)
    }
    
    private func openUserIniFile() {
        let fm = FileManager.default

        guard let userIniURL = KAppPaths.preferenceFileURL(fileName: "user.ini", createDirectoryIfNeeded: true) else {
            KLog.shared.log(id: "preferences", message: "Preferences directory is not available.")
            return
        }

        if fm.fileExists(atPath: userIniURL.path) {
            NSWorkspace.shared.open(userIniURL)
            return
        }

        guard let templateURL = Bundle.main.url(forResource: "default", withExtension: "ini") else {
            KLog.shared.log(id: "preferences", message: "default.ini is missing in app bundle.")
            return
        }

        guard let templateString = try? String(contentsOf: templateURL, encoding: .utf8) else {
            KLog.shared.log(id: "preferences", message: "Failed to read default.ini.")
            return
        }

        let content = makeCommentedUserIni(from: templateString)

        do {
            try content.write(to: userIniURL, atomically: true, encoding: .utf8)
        } catch {
            KLog.shared.log(id: "preferences", message: "Failed to create user.ini: \(userIniURL.path)")
            return
        }

        NSWorkspace.shared.open(userIniURL)
    }
    
    private func makeCommentedUserIni(from template: String) -> String {
        let lines = template.components(separatedBy: "\n")

        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行はそのまま
            if trimmed.isEmpty {
                outLines.append(line)
                continue
            }

            // 既存コメントはそのまま
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                outLines.append(line)
                continue
            }

            // セクション（カテゴリ）はそのまま
            if trimmed.hasPrefix("[") && trimmed.contains("]") {
                outLines.append(line)
                continue
            }

            // それ以外はすべてコメントアウト（元の行を保持したまま先頭に "# "）
            outLines.append("# " + line)
        }

        // UTF-8/LF に統一（末尾改行は付ける）
        return outLines.joined(separator: "\n") + "\n"
    }
    
    // delete buffer
    var deleteBuffer: String = ""
    
    // 起動直後に復元されるウインドウをすべて無効化
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    
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
        
        UserDefaults.standard.register(defaults: [
            KDefaultSearchKey.ignoreCase : true,
            KDefaultSearchKey.useRegex : false,
            KDefaultSearchKey.selectionOnly : false
        ])
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }
    
    //MARK: - Actions
    
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
    
    @IBAction func openScriptsFolder(_ sender: Any?) {
        openFolder(.scripts)
    }

    @IBAction func openApplicationSupportFolder(_ sender: Any?) {
        openFolder(.applicationSupportRoot)
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        openUserIniFile()
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

