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

    
    
}

