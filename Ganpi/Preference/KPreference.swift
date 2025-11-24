//
//  KPreference.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/16,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

//
//  KPreference.swift
//  Ganpi
//

import Foundation
import AppKit

final class KPreference {

    static let shared = KPreference()

    private let _defaultINI: URL
    private let _userINI: URL

    // user.ini / default.ini の raw
    private var _userValues:    [String:Any] = [:]
    private var _defaultValues: [String:Any] = [:]

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
        updateCurrentAppearance()
        
        //test
        //_defaultValues.keys.forEach{ log("key:\($0), \(_defaultValues[$0]!)") }
    }

    func load() {
        _userValues.removeAll()
        _defaultValues.removeAll()
        _colorCache.removeAll()
        _fontCache.removeAll()

        let defaultDict = KPrefLoader.load(from: _defaultINI)
        let userDict    = KPrefLoader.load(from: _userINI)

        loadOne(dict: defaultDict, into: &_defaultValues)
        loadOne(dict: userDict,    into: &_userValues)

        if let raw = (_userValues["system.appearance_mode"] ??
                      _defaultValues["system.appearance_mode"]) as? String {
            _appearanceMode = KAppearance.fromSetting(raw)
        }
    }

    private func loadOne(dict: [String:String], into store: inout [String:Any]) {
        for (key, raw) in dict {
            
            // .darkについてはそれを取り除いたkeyでschemaを取り出す。
            var modifiedKey:String
            if key.hasSuffix(".dark") {
                modifiedKey = String(key.dropLast(5))
            } else {
                modifiedKey = key
            }
                        
            if let schema = KPrefSchema.table[modifiedKey] {
                switch schema.type {

                case .bool:
                    let v = raw.lowercased()
                    if v == "true"      { store[key] = true }
                    else if v == "false"{ store[key] = false }
                    else { log("Invalid bool \(raw) for \(key)", from: self) }

                case .int:
                    if let v = Int(raw) { store[key] = v }
                    else { log("Invalid int \(raw) for \(key)", from: self) }

                case .float:
                    if let v = Double(raw) { store[key] = CGFloat(v) }
                    else { log("Invalid float \(raw) for \(key)", from: self) }

                case .string:
                    store[key] = raw

                case .enumerated:
                    store[key] = raw

                case .color:
                    if let c = NSColor(hexString: raw) { store[key] = c }
                    else { log("Invalid color \(raw) for \(key)", from: self) }

                case .font:
                    store[key] = raw
                }

            } else {
                store[key] = raw
            }
        }
    }

    // appearance_mode = system のときに実際の macOS appearance を読む
    func updateCurrentAppearance() {
        if _appearanceMode == .system {
            if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                _currentAppearance = .dark
            } else {
                _currentAppearance = .light
            }
        } else {
            _currentAppearance = _appearanceMode
        }
        _colorCache.removeAll()
    }

    // getter（非 optional）

    func bool(_ key: KPrefKey, lang: KSyntaxType? = nil) -> Bool {
        if let v = lookupValue(key, lang: lang) as? Bool { return v }
        log("Bool missing for \(key.rawKey ?? "?")", from: self)
        return false
    }

    func int(_ key: KPrefKey, lang: KSyntaxType? = nil) -> Int {
        if let v = lookupValue(key, lang: lang) as? Int { return v }
        log("Int missing for \(key.rawKey ?? "?")", from: self)
        return 0
    }

    func float(_ key: KPrefKey, lang: KSyntaxType? = nil) -> CGFloat {
        if let v = lookupValue(key, lang: lang) as? CGFloat { return v }
        log("Float missing for \(key.rawKey ?? "?")", from: self)
        return 0
    }

    func string(_ key: KPrefKey, lang: KSyntaxType? = nil) -> String {
        if let v = lookupValue(key, lang: lang) as? String { return v }
        log("String missing for \(key.rawKey ?? "?")", from: self)
        return ""
    }

    func color(_ key: KPrefKey, lang: KSyntaxType?) -> NSColor {
        if let final = resolveColorKey(key, lang: lang),
           let c = _defaultValues[final] as? NSColor ?? _userValues[final] as? NSColor {
            return c
        }
        log("color fallback for \(key.rawKey ?? "?")", from:self)
        return .black
    }


    func font(_ key: KPrefKey, lang: KSyntaxType? = nil) -> NSFont {
        let fam  = string(.parserFontFamily, lang: lang)
        let size = float(.parserFontSize,  lang: lang)

        let k = "\(fam):\(size)"
        if let c = _fontCache[k] { return c }

        let f = NSFont(name: fam, size: size) ?? NSFont.systemFont(ofSize: size)
        _fontCache[k] = f
        return f
    }

    // enum 型

    func appearanceMode() -> KAppearance {
        //KAppearance.fromSetting(string(.systemAppearanceMode))
        if let raw = _userValues["system.appearance_mode"] as? String {
            return KAppearance.fromSetting(raw)
        }
        if let raw = _defaultValues["system.appearance_mode"] as? String {
            return KAppearance.fromSetting(raw)
        }
        // default.ini に必ず存在するため本来到達しないが一応
        log("Missing system.appearance_mode — fallback to system", from: self)
        return .system
    }

    func keyAssign() -> KKeyAssignKind {
        let raw = string(.editorKeyAssign)
        if let v = KKeyAssignKind.fromSetting(raw) { return v }
        log("Invalid key_assign \(raw)", from: self)
        return .ganpi
    }

    func editMode() -> KEditMode {
        KEditMode.fromSetting(string(.editorEditMode))
    }

    func wraplineOffset(_ lang: KSyntaxType?) -> KWrapLineOffsetType {
        if let raw = lookupValue(.parserWraplineOffset, lang: lang) as? String,
           let t = KWrapLineOffsetType.fromSetting(raw) {
            return t
        }
        log("Invalid wrapline_offset", from: self)
        return .same
    }

    // -------- resolver（本丸）

    private func resolveCandidates(for key: KPrefKey, lang: KSyntaxType?) -> [String] {

        guard let baseKey = key.rawKey else {
            fatalError("resolveCandidates received abstract key: \(key)")
        }

        // appearance 展開
        func expand(_ raw: String) -> [String] {
            switch _currentAppearance {
            case .light:
                return [ raw ]
            case .dark:
                return [ raw + ".dark", raw ]
            case .system:
                log("Unexpected _currentAppearance == .system", from:self)
                return [ raw ]
            }
        }

        var candidates: [String] = []

        // ------- 1) 言語がある場合は parser.<lang>.* を候補に ------
        if let lang = lang,
           baseKey.hasPrefix("parser.base.") {

            let suffix = baseKey.dropFirst("parser.base.".count)
            let langKey = "parser.\(lang.settingName).\(suffix)"

            candidates.append(contentsOf: expand(langKey))
        }

        // ------- 2) 必ず base キーも追加する ------
        candidates.append(contentsOf: expand(baseKey))

        return candidates
    }



    private func resolveFinalKey(_ key: KPrefKey, lang: KSyntaxType?) -> String? {

        let candidates = resolveCandidates(for: key, lang: lang)
        
        log("candidates:\(candidates)",from:self)

        for ck in candidates {
            if _userValues[ck] != nil { return ck }
        }
        for ck in candidates {
            if _defaultValues[ck] != nil { return ck }
        }
        
        log("here")

        if let raw = key.rawKey {
            if _userValues[raw] != nil { return raw }
            if _defaultValues[raw] != nil { return raw }
        }

        return nil
    }
    
    
    private func resolveColorKey(_ key: KPrefKey, lang: KSyntaxType?) -> String? {

        guard let base = key.rawKey else { return nil }

        let suffix = base.dropFirst("parser.base.".count)
        let modeIsDark = (_currentAppearance == .dark)

        // 1) user.lang
        if let lang = lang {
            if modeIsDark, _userValues["parser.\(lang.settingName).\(suffix).dark"] != nil {
                return "parser.\(lang.settingName).\(suffix).dark"
            }
            if _userValues["parser.\(lang.settingName).\(suffix)"] != nil {
                return "parser.\(lang.settingName).\(suffix)"
            }
        }

        // 2) user.base
        if modeIsDark, _userValues["parser.base.\(suffix).dark"] != nil {
            return "parser.base.\(suffix).dark"
        }
        if _userValues["parser.base.\(suffix)"] != nil {
            return "parser.base.\(suffix)"
        }

        // 3) default.lang
        if let lang = lang {
            if modeIsDark, _defaultValues["parser.\(lang.settingName).\(suffix).dark"] != nil {
                return "parser.\(lang.settingName).\(suffix).dark"
            }
            if _defaultValues["parser.\(lang.settingName).\(suffix)"] != nil {
                return "parser.\(lang.settingName).\(suffix)"
            }
        }

        // 4) default.base
        if modeIsDark, _defaultValues["parser.base.\(suffix).dark"] != nil {
            return "parser.base.\(suffix).dark"
        }
        if _defaultValues["parser.base.\(suffix)"] != nil {
            return "parser.base.\(suffix)"
        }

        return nil
    }




    private func lookupValue(_ key: KPrefKey, lang: KSyntaxType?) -> Any? {
        if let final = resolveFinalKey(key, lang: lang) {
            return _userValues[final] ?? _defaultValues[final]
        }
        return nil
    }
}
