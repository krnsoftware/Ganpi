//
//  KPreference.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/16,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Foundation
import AppKit

final class KPreference {

    static let shared = KPreference()

    private let _defaultINI: URL
    private let _userINI: URL

    // user / default の型変換済みデータ
    private var _defaultValues: [String : Any] = [:]
    private var _userValues:    [String : Any] = [:]

    // macOS の動的 appearance（dark / light）
    private var _currentAppearance: KAppearance = .light

    // キャッシュ
    private var _colorCache: [String : NSColor] = [:]
    private var _fontCache:  [String : NSFont]  = [:]


    // MARK: - Init

    private init() {

        _defaultINI = Bundle.main.url(forResource: "default", withExtension: "ini")!

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Ganpi")

        _userINI = support.appendingPathComponent("user.ini")

        load()
    }


    // MARK: - Load

    func load() {

        _defaultValues.removeAll()
        _userValues.removeAll()
        _colorCache.removeAll()
        _fontCache.removeAll()

        let rawDefault = KPrefLoader.load(from: _defaultINI)
        let rawUser    = KPrefLoader.load(from: _userINI)

        // --- default のロード ---
        for (key, raw) in rawDefault {
            if let schema = KPrefSchema.table[key] {
                if let v = convert(raw: raw, schema: schema, fullKey: key) {
                    _defaultValues[key] = v
                }
            } else {
                _defaultValues[key] = raw
            }
        }

        // --- user のロード ---
        for (key, raw) in rawUser {
            if let schema = KPrefSchema.table[key] {
                if let v = convert(raw: raw, schema: schema, fullKey: key) {
                    _userValues[key] = v
                }
            } else {
                _userValues[key] = raw
            }
        }
    }


    // MARK: - raw → typed conversion

    private func convert(raw: String, schema: KPrefSchema, fullKey: String) -> Any? {
        switch schema.type {

        case .bool:
            let lc = raw.lowercased()
            if lc == "true" { return true }
            if lc == "false" { return false }
            log("Invalid bool '\(raw)' for key '\(fullKey)'", from: self)
            return nil

        case .int:
            if let v = Int(raw) { return v }
            log("Invalid int '\(raw)' for key '\(fullKey)'", from: self)
            return nil

        case .float:
            if let d = Double(raw) { return CGFloat(d) }
            log("Invalid float '\(raw)' for key '\(fullKey)'", from: self)
            return nil

        case .string, .enumerated, .font:
            return raw

        case .color:
            if let c = NSColor(hexString: raw) { return c }
            log("Invalid color '\(raw)' for key '\(fullKey)'", from: self)
            return nil
        }
    }


    // MARK: - Resolver (lang + appearance + user→default)

    private func resolveLangKey(_ key: KPrefKey, lang: KSyntaxType?) -> String? {

        guard let raw = key.rawKey else { return nil }

        guard raw.hasPrefix("parser.base.") else { return raw }
        guard let lang = lang else { return raw }

        let suffix = raw.dropFirst("parser.base.".count)
        let langKey = "parser.\(lang.settingName).\(suffix)"

        // その言語の記述が存在すれば置換
        if _userValues[langKey] != nil { return langKey }
        if _defaultValues[langKey] != nil { return langKey }

        return raw
    }


    private func appearanceCandidates(for raw: String) -> [String] {
        // getter の appearanceMode() が最終的な設定値
        let prefMode = appearanceMode()

        switch prefMode {

        case .light:
            return [ raw ]

        case .dark:
            return [ raw + ".dark", raw ]

        case .system:
            // 本来の動作は _currentAppearance
            switch _currentAppearance {
            case .dark:
                return [ raw + ".dark", raw ]
            case .light:
                return [ raw ]
            case .system:
                return [ raw ]
            }
        }
    }


    private func resolvedKeys(_ key: KPrefKey, lang: KSyntaxType?) -> [String] {

        guard let langFixed = resolveLangKey(key, lang: lang) else { return [] }

        let candidates = appearanceCandidates(for: langFixed)
        var out: [String] = []

        for k in candidates {
            out.append("user:\(k)")
            out.append("default:\(k)")
        }

        return out
    }


    private func lookup(_ key: KPrefKey, lang: KSyntaxType?) -> Any? {

        for item in resolvedKeys(key, lang: lang) {

            if item.hasPrefix("user:") {
                let k = String(item.dropFirst("user:".count))
                if let v = _userValues[k] { return v }

            } else { // default
                let k = String(item.dropFirst("default:".count))
                if let v = _defaultValues[k] { return v }
            }
        }

        return nil
    }


    // MARK: - Getter

    func bool(_ key: KPrefKey, lang: KSyntaxType? = nil) -> Bool {
        if let v = lookup(key, lang: lang) as? Bool { return v }
        log("bool fallback for \(key.rawKey ?? "?")", from: self)
        return false
    }

    func int(_ key: KPrefKey, lang: KSyntaxType? = nil) -> Int {
        if let v = lookup(key, lang: lang) as? Int { return v }
        log("int fallback for \(key.rawKey ?? "?")", from: self)
        return 0
    }

    func float(_ key: KPrefKey, lang: KSyntaxType? = nil) -> CGFloat {
        if let v = lookup(key, lang: lang) as? CGFloat { return v }
        log("float fallback for \(key.rawKey ?? "?")", from: self)
        return 0
    }

    func string(_ key: KPrefKey, lang: KSyntaxType? = nil) -> String {
        if let v = lookup(key, lang: lang) as? String { return v }
        log("string fallback for \(key.rawKey ?? "?")", from: self)
        return ""
    }


    func color(_ key: KPrefKey, lang: KSyntaxType? = nil) -> NSColor {

        if let v = lookup(key, lang: lang) as? NSColor {
            return v
        }

        log("color fallback for \(key.rawKey ?? "?")", from: self)
        return .black
    }


    func font(_ key: KPrefKey, lang: KSyntaxType? = nil) -> NSFont {

        let fam  = string(.parserFontFamily, lang: lang)
        let size = float(.parserFontSize,  lang: lang)

        let cacheKey = "\(fam):\(size)"
        if let cached = _fontCache[cacheKey] { return cached }

        let f = NSFont(name: fam, size: size) ?? NSFont.systemFont(ofSize: size)
        _fontCache[cacheKey] = f
        return f
    }


    // MARK: - Enumerated

    func appearanceMode() -> KAppearance {
        // user → default の順で探す
        if let raw = _userValues["system.appearance_mode"] as? String {
            return KAppearance.fromSetting(raw)
        }
        if let raw = _defaultValues["system.appearance_mode"] as? String {
            return KAppearance.fromSetting(raw)
        }
        return .system
    }

    func keyAssign() -> KKeyAssignKind {
        let raw = string(.editorKeyAssign)
        return KKeyAssignKind.fromSetting(raw) ?? .ganpi
    }

    func editMode() -> KEditMode {
        let raw = string(.editorEditMode)
        return KEditMode.fromSetting(raw)
    }

    func wraplineOffset(_ lang: KSyntaxType?) -> KWrapLineOffsetType {
        let raw = string(.parserWraplineOffset, lang: lang)
        return KWrapLineOffsetType.fromSetting(raw) ?? .same
    }
}
