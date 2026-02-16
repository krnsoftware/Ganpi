//
//  KAppPaths.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/02/15,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



import Foundation

/// アプリの各種データ置き場（Application Support / Application Scripts）を一箇所で定義する。
struct KAppPaths {

    // MARK: - Base directories

    static func applicationSupportBaseURL(createIfNeeded: Bool) -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }

        guard let dirName = Bundle.main.bundleIdentifier else { fatalError("Bundle identifier is missing.") }
        let url = base.appendingPathComponent(dirName, isDirectory: true)

        if createIfNeeded {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func applicationScriptsBaseURL(createIfNeeded: Bool) -> URL? {
        let fm = FileManager.default
        guard let url = try? fm.url(for: .applicationScriptsDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: false) else { return nil }

        if createIfNeeded {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: - Application Support subdirectories

    static func keywordsDirectoryURL(createIfNeeded: Bool) -> URL? {
        guard let base = applicationSupportBaseURL(createIfNeeded: createIfNeeded) else { return nil }
        let url = base.appendingPathComponent("keywords", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func templatesDirectoryURL(createIfNeeded: Bool) -> URL? {
        guard let base = applicationSupportBaseURL(createIfNeeded: createIfNeeded) else { return nil }
        let url = base.appendingPathComponent("templates", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func preferencesDirectoryURL(createIfNeeded: Bool) -> URL? {
        guard let base = applicationSupportBaseURL(createIfNeeded: createIfNeeded) else { return nil }
        let url = base.appendingPathComponent("preferences", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func preferenceFileURL(fileName: String, createDirectoryIfNeeded: Bool) -> URL? {
        guard let dir = preferencesDirectoryURL(createIfNeeded: createDirectoryIfNeeded) else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Application Scripts subdirectories

    static func scriptsDirectoryURL(createIfNeeded: Bool) -> URL? {
        guard let base = applicationScriptsBaseURL(createIfNeeded: createIfNeeded) else { return nil }
        let url = base.appendingPathComponent("scripts", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
