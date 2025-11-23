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

    private var _values: [String : Any] = [:]
    private var _appearanceMode: KAppearance = .system
    private var _currentAppearance: KAppearance = .light

    private var _colorCache: [String : NSColor] = [:]
    private var _fontCache:  [String : NSFont]  = [:]

    private init() {

        _defaultINI = Bundle.main.url(forResource: "default", withExtension: "ini")!

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Ganpi")

        _userINI = support.appendingPathComponent("user.ini")

        load()
    }


    func load() {
        _values.removeAll()
        _colorCache.removeAll()
        _fontCache.removeAll()

        let base = KPrefLoader.load(from: _defaultINI)
        let user = KPrefLoader.load(from: _userINI)

        var merged = base
        for (k,v) in user { merged[k] = v }

        for (fullKey, raw) in merged {

            if let schema = KPrefSchema.table[fullKey] {

                switch schema.type {

                case .bool:
                    let lc = raw.lowercased()
                    if lc == "true" {
                        _values[fullKey] = true
                    } else if lc == "false" {
                        _values[fullKey] = false
                    } else {
                        log("Invalid bool '\(raw)' for key '\(fullKey)'", from: self)
                    }

                case .int:
                    if let v = Int(raw) {
                        _values[fullKey] = v
                    } else {
                        log("Invalid int '\(raw)' for key '\(fullKey)'", from: self)
                    }

                case .float:
                    if let d = Double(raw) {
                        _values[fullKey] = CGFloat(d)
                    } else {
                        log("Invalid float '\(raw)' for key '\(fullKey)'", from: self)
                    }

                case .string:
                    _values[fullKey] = raw

                case .enumerated:
                    _values[fullKey] = raw

                case .color:
                    if let c = NSColor(hexString: raw) {
                        _values[fullKey] = c
                    } else {
                        log("Invalid color '\(raw)' for key '\(fullKey)'", from: self)
                    }

                case .font:
                    _values[fullKey] = raw
                }

            } else {
                _values[fullKey] = raw
            }
        }

        if let raw = _values["system.appearance_mode"] as? String {
            _appearanceMode = KAppearance.fromSetting(raw)
        }
    }



    // ---------- Public Getter（Non-Optional + loud fallback）

    func bool(_ key: KPrefKey, lang: KSyntaxType? = nil) -> Bool {
        if let v = _boolInternal(key, lang: lang) { return v }
        log("Missing Bool for '\(key.rawKey ?? "?")' — fallback to false", from: self)
        return false
    }

    func int(_ key: KPrefKey, lang: KSyntaxType? = nil) -> Int {
        if let v = _intInternal(key, lang: lang) { return v }
        log("Missing Int for '\(key.rawKey ?? "?")' — fallback to 0", from: self)
        return 0
    }

    func float(_ key: KPrefKey, lang: KSyntaxType? = nil) -> CGFloat {
        if let v = _floatInternal(key, lang: lang) { return v }
        log("Missing Float for '\(key.rawKey ?? "?")' — fallback to 0", from: self)
        return 0.0
    }

    func string(_ key: KPrefKey, lang: KSyntaxType? = nil) -> String {
        if let v = _stringInternal(key, lang: lang) { return v }
        log("Missing String for '\(key.rawKey ?? "?")' — fallback to \"\"", from: self)
        return ""
    }

    func color(_ key: KPrefKey, lang: KSyntaxType? = nil) -> NSColor {
        let resolved = _selectColorKey(key)

        if let cached = _colorCache[resolved] { return cached }
        if let c = _colorInternal(resolved) {
            _colorCache[resolved] = c
            return c
        }

        log("Missing color for '\(resolved)' — fallback to black", from: self)
        let fallback = NSColor.black
        _colorCache[resolved] = fallback
        return fallback
    }

    func font(_ key: KPrefKey, lang: KSyntaxType? = nil) -> NSFont {
        let fam  = string(.parserFontFamily, lang: lang)
        let size = float(.parserFontSize,  lang: lang)

        if let cached = _fontCache["\(fam):\(size)"] { return cached }

        let f = NSFont(name: fam, size: size) ?? NSFont.systemFont(ofSize: size)
        _fontCache["\(fam):\(size)"] = f
        return f
    }
    
    // MARK: - Enum Getters

    func appearanceMode() -> KAppearance {
        let raw = string(.systemAppearanceMode)
        return KAppearance.fromSetting(raw)
    }

    func keyAssign() -> KKeyAssignKind {
        let raw = string(.editorKeyAssign)
        if let v = KKeyAssignKind.fromSetting(raw) {
            return v
        }
        log("Invalid key_assign '\(raw)' — fallback to .ganpi", from: self)
        return .ganpi
    }

    func editMode() -> KEditMode {
        let raw = string(.editorEditMode)
        return KEditMode.fromSetting(raw)
    }

    // wrapline_offset（言語依存）
    func wraplineOffset(_ lang: KSyntaxType?) -> KWrapLineOffsetType {
        if let raw = _stringInternal(.parserWraplineOffset, lang: lang),
           let v = KWrapLineOffsetType.fromSetting(raw) {
            return v
        }
        log("Invalid wrapline_offset — fallback to .same", from: self)
        return .same
    }



    // ---------- Internal Optional Getter

    private func _boolInternal(_ key: KPrefKey, lang: KSyntaxType?) -> Bool? {
        _lookup(key, lang: lang) as? Bool
    }

    private func _intInternal(_ key: KPrefKey, lang: KSyntaxType?) -> Int? {
        _lookup(key, lang: lang) as? Int
    }

    private func _floatInternal(_ key: KPrefKey, lang: KSyntaxType?) -> CGFloat? {
        _lookup(key, lang: lang) as? CGFloat
    }

    private func _stringInternal(_ key: KPrefKey, lang: KSyntaxType?) -> String? {
        _lookup(key, lang: lang) as? String
    }

    private func _colorInternal(_ rk: String) -> NSColor? {
        _values[rk] as? NSColor
    }


    // ---------- Lookup with meta-table

    private func _lookup(_ key: KPrefKey, lang: KSyntaxType?) -> Any? {

        if let lang = lang,
           let base = key.rawKey,
           base.hasPrefix("parser.base.") {

            let suffix = base.dropFirst("parser.base.".count)
            let ln = lang.settingName
            let lk = "parser.\(ln).\(suffix)"

            if let v = _values[lk] { return v }
        }

        if let rk = key.rawKey, let v = _values[rk] { return v }

        return nil
    }


    private func _selectColorKey(_ key: KPrefKey) -> String {
        guard let raw = key.rawKey else { return "" }

        switch _currentAppearance {

        case .light:
            if _values[raw] != nil { return raw }
            let dark = raw + ".dark"
            return _values[dark] != nil ? dark : raw

        case .dark:
            let dark = raw + ".dark"
            if _values[dark] != nil { return dark }
            return raw

        default:
            log("Unexpected appearance '\(_currentAppearance)' — fallback base color", from: self)
            return raw
        }
    }
}
