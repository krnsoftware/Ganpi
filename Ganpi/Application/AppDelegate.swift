//
//  AppDelegate.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import Cocoa


@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    @IBOutlet weak var _userMenuItem: NSMenuItem!
    
    // ファイル指定で起動中かどうかを検知するためのフラグ
    private var launchingWithFiles = false
    
    // delete buffer
    var deleteBuffer: String = ""
    
    private enum FolderKind {
        case scripts
        case applicationSupportRoot
        case templates
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
            
        case .templates:
            guard let url = KAppPaths.templatesDirectoryURL(createIfNeeded: true) else {
                KLog.shared.log(id: "folders", message: "Templates directory not available.")
                return
            }
            // この case だけは url をここで確定するので、下の共通処理へ渡す形にする
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                KLog.shared.log(id: "folders", message: "Failed to create directory: \(url.path)")
                return
            }
            
            NSWorkspace.shared.open(url)
            return
            
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

        constructMenus()
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

        constructMenus()
    }
    
    @IBAction func openScriptsFolder(_ sender: Any?) {
        openFolder(.scripts)
    }

    @IBAction func openApplicationSupportFolder(_ sender: Any?) {
        openFolder(.applicationSupportRoot)
    }
    
    @IBAction func openTemplatesFolder(_ sender: Any?) {
        openFolder(.templates)
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        openUserIniFile()
    }

    @IBAction func openHelp(_ sender: Any?) {
        guard let helpURL = Bundle.main.url(forResource: "help", withExtension: "html") else {
            NSSound.beep()
            NSLog("help.html not found in app bundle.")
            return
        }

        // 「OS標準ブラウザ」を引くため、https の既定ハンドラを取得する
        guard let probeURL = URL(string: "https://example.com"),
              let browserAppURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
            NSSound.beep()
            NSLog("default browser not found.")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.open([helpURL],
                                withApplicationAt: browserAppURL,
                                configuration: config) { _, error in
            if let error = error {
                NSSound.beep()
                NSLog("failed to open help in browser: \(error)")
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
    
    // MARK: - User Menu

    private func constructMenus() {
        let result = buildUserMenu()
        _userMenuItem.title = result.title
        _userMenuItem.submenu = result.menu
    }

    private func buildUserMenu() -> (title: String, menu: NSMenu) {
        guard let text = loadUserMenuText() else {
            KLog.shared.log(id: "usermenu", message: "usermenu.txt not found.")
            let title = _userMenuItem.title
            return (title, NSMenu(title: title))
        }

        let rawLines = text.split(whereSeparator: \.isNewline).map { String($0) }

        var rootTitle = _userMenuItem.title
        let rootMenu = NSMenu(title: rootTitle)

        // 実メニュー階層用スタック（rootMenu は常に残す）
        var stack: [NSMenu] = [rootMenu]

        // 先頭 menu "..." を「ルートの menu ブロック」として扱うためのフラグ
        // これが true の間は「ルート配下を構築中」
        var rootMenuBlockOpen = false

        var currentItemTitle: String? = nil
        var currentItemKey: String? = nil
        var currentItemCommand: String? = nil

        func flushItemIfNeeded(_ lineNo: Int) {
            guard let title = currentItemTitle else { return }

            let command = currentItemCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if command.isEmpty {
                KLog.shared.log(id: "usermenu", message: "Line \(lineNo): Item '\(title)' has no command; skipped.")
                currentItemTitle = nil
                currentItemKey = nil
                currentItemCommand = nil
                return
            }

            let actions = KKeymapLoader.parseActions(from: command)
            if actions.isEmpty {
                KLog.shared.log(id: "usermenu", message: "Line \(lineNo): Item '\(title)' has no valid actions; skipped.")
                currentItemTitle = nil
                currentItemKey = nil
                currentItemCommand = nil
                return
            }

            let item = NSMenuItem(title: title,
                                  action: #selector(KTextView.performUserActions(_:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = actions

            if let keyText = currentItemKey {
                applyMenuShortcut(from: keyText, to: item)
            }

            stack[stack.count - 1].addItem(item)

            currentItemTitle = nil
            currentItemKey = nil
            currentItemCommand = nil
        }

        for i in 0..<rawLines.count {
            let lineNo = i + 1
            let line = stripComment(from: rawLines[i]).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            // menu "Title"
            if line.hasPrefix("menu") {
                flushItemIfNeeded(lineNo)

                guard let title = parseLeadingQuotedString(afterKeyword: "menu", line: line) else {
                    KLog.shared.log(id: "usermenu", message: "Line \(lineNo): invalid menu syntax.")
                    continue
                }

                // ルート直下で最初に現れた menu は、サブメニューを作らず「ルート名の設定＋ブロック開始」として扱う
                if stack.count == 1 && rootMenuBlockOpen == false {
                    rootTitle = title
                    rootMenu.title = title
                    rootMenuBlockOpen = true
                    continue
                }

                // 通常の submenu
                let submenu = NSMenu(title: title)
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.submenu = submenu
                stack[stack.count - 1].addItem(menuItem)
                stack.append(submenu)
                continue
            }

            // end
            if line == "end" {
                flushItemIfNeeded(lineNo)

                if stack.count > 1 {
                    _ = stack.popLast()
                } else if rootMenuBlockOpen {
                    // ルート menu ブロックを閉じる
                    rootMenuBlockOpen = false
                } else {
                    KLog.shared.log(id: "usermenu", message: "Line \(lineNo): stray end ignored.")
                }
                continue
            }

            // item "Title"
            if line.hasPrefix("item") {
                flushItemIfNeeded(lineNo)

                guard let title = parseLeadingQuotedString(afterKeyword: "item", line: line) else {
                    KLog.shared.log(id: "usermenu", message: "Line \(lineNo): invalid item syntax.")
                    continue
                }

                currentItemTitle = title
                continue
            }

            // key "cmd+opt+P"
            if line.hasPrefix("key") {
                guard currentItemTitle != nil else {
                    KLog.shared.log(id: "usermenu", message: "Line \(lineNo): key without item ignored.")
                    continue
                }
                guard let keyText = parseLeadingQuotedString(afterKeyword: "key", line: line) else {
                    KLog.shared.log(id: "usermenu", message: "Line \(lineNo): invalid key syntax.")
                    continue
                }
                currentItemKey = keyText
                continue
            }

            // command: ...
            if line.hasPrefix("command:") {
                guard currentItemTitle != nil else {
                    KLog.shared.log(id: "usermenu", message: "Line \(lineNo): command without item ignored.")
                    continue
                }
                let body = String(line.dropFirst("command:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentItemCommand = body
                continue
            }

            KLog.shared.log(id: "usermenu", message: "Line \(lineNo): unknown directive ignored: \(line)")
        }

        flushItemIfNeeded(rawLines.count)

        if stack.count != 1 || rootMenuBlockOpen {
            KLog.shared.log(id: "usermenu", message: "Unclosed menu blocks detected. (missing end?)")
        }

        return (rootTitle, rootMenu)
    }

    private func loadUserMenuText() -> String? {
        // 1) User: ~/Library/Application Support/<bundle id>/usermenu.txt
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dirName = Bundle.main.bundleIdentifier ?? "ApplicationSupport"
            let url = base.appendingPathComponent(dirName, isDirectory: true)
                .appendingPathComponent("menu", isDirectory: true)
                .appendingPathComponent("usermenu.txt", isDirectory: false)
            log("url:\(url)",from:self)
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }

        // 2) Bundle: usermenu.txt
        if let url = Bundle.main.url(forResource: "usermenu", withExtension: "txt"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }

        return nil
    }

    private func stripComment(from line: String) -> String {
        var out = ""
        var quote: Character? = nil
        var escape = false

        for c in line {
            if let q = quote {
                out.append(c)
                if escape {
                    escape = false
                } else if c == "\\" {
                    escape = true
                } else if c == q {
                    quote = nil
                }
                continue
            }

            if c == "\"" || c == "'" {
                quote = c
                out.append(c)
                continue
            }

            if c == "#" || c == ";" {
                break
            }

            out.append(c)
        }

        return out
    }

    private func parseLeadingQuotedString(afterKeyword keyword: String, line: String) -> String? {
        var s = line
        if s.hasPrefix(keyword) {
            s = String(s.dropFirst(keyword.count))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.first == "\"" else { return nil }

        var result = ""
        var escape = false
        var index = s.index(after: s.startIndex)

        while index < s.endIndex {
            let c = s[index]

            if escape {
                switch c {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: result.append(c)
                }
                escape = false
                index = s.index(after: index)
                continue
            }

            if c == "\\" {
                escape = true
                index = s.index(after: index)
                continue
            }

            if c == "\"" {
                return result
            }

            result.append(c)
            index = s.index(after: index)
        }

        return nil
    }

    private func applyMenuShortcut(from keyText: String, to item: NSMenuItem) {
        // 文字キーのみ対応（英数字1文字）。
        // 形式例: "cmd+opt+P"
        let parts = keyText
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var mask: NSEvent.ModifierFlags = []
        var key: String? = nil

        for p in parts {
            switch p {
            case "cmd", "command":
                mask.insert(.command)
            case "opt", "option", "alt":
                mask.insert(.option)
            case "ctrl", "control":
                mask.insert(.control)
            case "shift":
                mask.insert(.shift)
            default:
                // 最後に見つかった非修飾をキー扱い
                key = p
            }
        }

        guard var k = key, !k.isEmpty else { return }

        // 1文字英数字のみ
        if k.count != 1 {
            KLog.shared.log(id: "usermenu", message: "Menu shortcut ignored (not 1-char): \(keyText)")
            return
        }

        let ch = k.first!
        guard ch.isLetter || ch.isNumber else {
            KLog.shared.log(id: "usermenu", message: "Menu shortcut ignored (not alnum): \(keyText)")
            return
        }

        // keyEquivalent は小文字が基本
        k = String(ch).lowercased()

        item.keyEquivalent = k
        item.keyEquivalentModifierMask = mask
    }
    
}

