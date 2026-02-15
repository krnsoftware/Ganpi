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
    
    private var _appearanceObserver: NSKeyValueObservation?

    private let _defaultINI: URL
    private let _userINI: URL

    // user.ini / default.ini の raw
    private var _userValues:    [String:Any] = [:]
    private var _defaultValues: [String:Any] = [:]

    private var _colorCache: [String : NSColor] = [:]
    private var _fontCache:  [String : NSFont]  = [:]

    private init() {

        _defaultINI = Bundle.main.url(forResource: "default", withExtension: "ini")!

        guard let userIniURL = KAppPaths.preferenceFileURL(fileName: "user.ini", createDirectoryIfNeeded: true) else {
            fatalError("Preferences directory is not available.")
        }

        _userINI = userIniURL

        load()
        
        _appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                    self?.handleAppearanceChange()
                }
        
        //test
        //_defaultValues.keys.forEach{ log("key:\($0), \(_defaultValues[$0]!)") }
    }

    deinit {
        _appearanceObserver = nil
    }

    // Appearanceが変更された時に呼び出されるメソッド
    private func handleAppearanceChange() {
        for doc in NSDocumentController.shared.documents {
            if let document = doc as? Document {
                // パーサを新しいものに入れ替える。
                document.textStorage.replaceParser(for: document.syntaxType)
            }
        }
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
        
    }

    private func loadOne(dict: [String:String], into store: inout [String:Any]) {
        for (key, raw) in dict {
            
            var modifiedKey = key
            
            // .darkについてはそれを取り除いたkeyでschemaを取り出す。
            let darkSuffix = ".dark"
            if modifiedKey.hasSuffix(darkSuffix) {
                modifiedKey = String(modifiedKey.dropLast(darkSuffix.count))
            }
            
            // parser.<lang>. の場合、schemaはparser.base.のものを使用する。
            modifiedKey = modifiedKey.replacingOccurrences(
                of: #"^parser\.[A-Za-z_]+\."#,
                with: "parser.base.",
                options: .regularExpression
            )

                        
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
        if let final = resolveColorKey(key, lang: lang) {
            if let user = _userValues[final] as? NSColor { return user }
            if let def = _defaultValues[final] as? NSColor { return def }
        }
        
        log("color fallback for \(key.rawKey ?? "?")", from:self)
        return .black
    }


    func font(_ key: KPrefKey, lang: KSyntaxType? = nil) -> NSFont {
        let fontFamily = string(.parserFontFamily, lang: lang)
        let rawSize = float(.parserFontSize, lang: lang)
        let fontSize = rawSize > 3.0 && rawSize < 100.0 ? rawSize : 12.0
        
        let fontKey = "\(fontFamily):\(fontSize)"
        if let cache = _fontCache[fontKey] { return cache }
        
        let font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        _fontCache[fontKey] = font
        return font
    }

    
    // enum 型

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
    
    func newlineType() -> String.ReturnCharacter {
        if let type = String.ReturnCharacter.fromSetting(string(.documentNewline)) { return type }
        log("Invalid newlineType: \(string(.documentNewline))",from:self)
        return .lf
    }
    
    func characterCodeType() -> KTextEncoding {
        if let type = KTextEncoding.fromSetting(string(.documentCharacterCode)) { return type }
        log("Invalid characterCodeType",from:self)
        return .utf8
    }
    
    func syntaxType() -> KSyntaxType {
        if let type = KSyntaxType.fromSetting(string(.documentFileType)) { return type }
        log("Invalid syntaxType/documentFileType",from:self)
        return .plain
    }

    // -------- resolver（本丸）

    private func resolveCandidates(for key: KPrefKey, lang: KSyntaxType?) -> [String] {

        guard let baseKey = key.rawKey else {
            fatalError("resolveCandidates received abstract key: \(key)")
        }

        // appearance 展開
        func expand(_ raw: String) -> [String] {
            
            if isInDarkAppearance {
                return [raw + ".dark", raw]
            } else {
                return [raw]
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
        
        for ck in candidates {
            if _userValues[ck] != nil { return ck }
        }
        for ck in candidates {
            if _defaultValues[ck] != nil { return ck }
        }

        if let raw = key.rawKey {
            if _userValues[raw] != nil { return raw }
            if _defaultValues[raw] != nil { return raw }
        }

        return nil
    }
    
    
    private func resolveColorKey(_ key: KPrefKey, lang: KSyntaxType?) -> String? {

        guard let base = key.rawKey else { return nil }

        let suffix = base.dropFirst("parser.base.".count)
        let modeIsDark = isInDarkAppearance

        func makeKeys(prefix: String) -> (dark: String, light: String) {
            return (
                dark:  "\(prefix).\(suffix).dark",
                light: "\(prefix).\(suffix)"
            )
        }

        // ---------------------------
        // 1. 構築: lang 系の key
        // ---------------------------
        var langKeys: (dark: String, light: String)?
        if let lang {
            langKeys = makeKeys(prefix: "parser.\(lang.settingName)")
        }

        // ---------------------------
        // 2. 構築: base 系の key
        // ---------------------------
        let baseKeys = makeKeys(prefix: "parser.base")

        // ============================================================
        //   Dark Mode の場合の探索順序（ご主人様指定の 1〜8）
        // ============================================================
        if modeIsDark {

            // 1. user.lang.dark
            if let keys = langKeys, _userValues[keys.dark] != nil { return keys.dark }

            // 2. app.lang.dark
            if let keys = langKeys, _defaultValues[keys.dark] != nil { return keys.dark }

            // 3. user.lang.light
            if let keys = langKeys, _userValues[keys.light] != nil { return keys.light }

            // 4. app.lang.light
            if let keys = langKeys, _defaultValues[keys.light] != nil { return keys.light }

            // 5. user.base.dark
            if _userValues[baseKeys.dark] != nil { return baseKeys.dark }

            // 6. app.base.dark
            if _defaultValues[baseKeys.dark] != nil { return baseKeys.dark }

            // 7. user.base.light
            if _userValues[baseKeys.light] != nil { return baseKeys.light }

            // 8. app.base.light
            if _defaultValues[baseKeys.light] != nil { return baseKeys.light }

            return nil
        }

        // ============================================================
        //   Light Mode の場合（ダーク関連は完全無視）
        // ============================================================

        // user.lang.light
        if let keys = langKeys, _userValues[keys.light] != nil { return keys.light }

        // app.lang.light
        if let keys = langKeys, _defaultValues[keys.light] != nil { return keys.light }

        // user.base.light
        if _userValues[baseKeys.light] != nil { return baseKeys.light }

        // app.base.light
        if _defaultValues[baseKeys.light] != nil { return baseKeys.light }

        return nil
    }



    var isInDarkAppearance: Bool {
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }


    private func lookupValue(_ key: KPrefKey, lang: KSyntaxType?) -> Any? {
        if let final = resolveFinalKey(key, lang: lang) {
            return _userValues[final] ?? _defaultValues[final]
        }
        return nil
    }
}
