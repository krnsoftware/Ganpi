//
//  KPreference.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/29,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

final class KPreference {
    static let shared = KPreference()

    // 生のINI（正規化後）を2層で保持：ユーザー優先 → 内蔵 → スキーマ既定
    private var _userIni:    [String: String] = [:]
    private var _bundledIni: [String: String] = [:]

    // 現在の言語・テーマ（parser解決時に使用）
    private var _currentTheme: String? = nil   // "dark" / "light" / nil
    private var _currentLang:  String? = nil   // "ruby" / "html" / nil

    private init() {}

    // MARK: - ロード/更新

    /// INIをすべて入れ替える（Reload Settings でも使用）。default.* は後段で無視する。
    func load(userIni: [String: String],
              bundledIni: [String: String],
              theme: String?, lang: String?) {
        _userIni    = userIni
        _bundledIni = bundledIni
        _currentTheme = theme?.lowercased()
        _currentLang  = lang?.lowercased()
    }

    // MARK: - グローバル値（非parser）

    /// グローバルなフルキーを直接解決（user → bundled → schema）。default.* でも可。
    func value(for fullKey: String) -> Any? {
        // user
        if let v = coercedValue(for: fullKey, in: _userIni) { return v }
        // bundled
        if let v = coercedValue(for: fullKey, in: _bundledIni) { return v }
        // schema default（登録がある場合）
        return KPreferenceSchema.shared.entry(for: fullKey)?.defaultValue
    }

    // MARK: - parser用（言語・テーマ依存の 値系）

    /// 例: baseKey = "color.comment" / "font" / "invisibles.glyph.tab" など
    func parserValue(for baseKey: String, lang: String? = nil, theme: String? = nil) -> Any? {
        let langKey = (lang ?? _currentLang) ?? "base"
        let themedSuffixes = (theme ?? _currentTheme).map { [".\($0)", ""] } ?? [""]

        for layer in [_userIni, _bundledIni] {
            // parser.<lang>
            for suf in themedSuffixes {
                let k = "parser.\(langKey).\(baseKey)\(suf)"
                if let v = coercedValue(for: k, in: layer) { return v }
            }
            // parser.base
            for suf in themedSuffixes {
                let k = "parser.base.\(baseKey)\(suf)"
                if let v = coercedValue(for: k, in: layer) { return v }
            }
        }

        // 最後の砦：schema default（parser.base.<baseKey>）
        return KPreferenceSchema.shared.entry(for: "parser.base.\(baseKey)")?.defaultValue
    }

    // 型付きショートカット
    func parserColor(_ key: String, lang: String? = nil, theme: String? = nil) -> NSColor {
        (parserValue(for: key, lang: lang, theme: theme) as? NSColor)
        ?? (KPreferenceSchema.shared.entry(for: "parser.base.\(key)")?.defaultValue as? NSColor)
        ?? NSColor.labelColor
    }

    func parserFont(_ key: String = "font", lang: String? = nil, theme: String? = nil) -> NSFont {
        (parserValue(for: key, lang: lang, theme: theme) as? NSFont)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    // MARK: - parser用（言語依存の default系）起動/新規ドキュメント時のみ使う

    /// 例: baseKey = "tab_width" / "line_spacing" / "word_wrap" / "auto_indent" / "show.invisibles"
    func parserDefault<T>(_ baseKey: String, lang: String? = nil) -> T? {
        let langKey = (lang ?? _currentLang) ?? "base"
        let full = "default.\(baseKey)"

        for layer in [_userIni, _bundledIni] {
            if let v = coercedValue(for: "parser.\(langKey).\(full)", in: layer) as? T { return v }
            if let v = coercedValue(for: "parser.base.\(full)",     in: layer) as? T { return v }
        }
        return KPreferenceSchema.shared.entry(for: "parser.base.\(full)")?.defaultValue as? T
    }

    // MARK: - 可視/不可視の便宜API

    /// ドキュメント初期表示トグル（default）。ランタイムではユーザー操作が優先。
    func initialShowInvisibles(lang: String? = nil) -> Bool {
        parserDefault("show.invisibles", lang: lang) ?? true
    }

    enum InvisibleKind: String { case tab, newline, space, fullwidth_space }

    /// 種別構成（iniで設定・ランタイムでは固定）
    func showsInvisibleKind(_ kind: InvisibleKind, lang: String? = nil) -> Bool {
        let key = "show.invisibles.\(kind.rawValue)"
        // 値系として解決（テーマ非依存）
        return (parserValue(for: key, lang: lang, theme: nil) as? Bool)
            ?? (KPreferenceSchema.shared.entry(for: "parser.base.\(key)")?.defaultValue as? Bool)
            ?? false
    }

    // MARK: - 低レベル：一枚キーを型変換（指定レイヤのみ）

    /// 指定レイヤの `fullKey` をスキーマに基づいて型変換。未定義は nil（正常）。
    private func coercedValue(for fullKey: String, in layer: [String: String]) -> Any? {
        guard let e = KPreferenceSchema.shared.entry(for: fullKey) else { return nil }
        guard let rawStr = layer[fullKey] else { return nil }

        let raw = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let val: Any?

        switch e.type {
        case .bool:
            val = Self.parseBool(raw)
        case .int:
            val = Int(raw)
        case .float:
            val = Double(raw).map { CGFloat($0) }
        case .string:
            val = raw
        case .color:
            val = NSColor(hexString: raw) // 失敗は nil → 既定へ
        case .font:
            // 互換キーは「同じレイヤ」から拾う（読み取り時のみ許容）
            val = Self.parseFont(raw,
                                 deprecatedFamily: layer[KPrefKey.parserBaseFontFamilyDeprecated],
                                 deprecatedSize:   layer[KPrefKey.parserBaseFontSizeDeprecated])
        }

        let validated = e.validate?(val ?? e.defaultValue) ?? (val ?? e.defaultValue)
        if e.type == .font, let spec = validated as? KFontSpec {
            return KPreference.makeFont(from: spec)
        }
        return validated
    }

    // MARK: - パース補助

    private static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true","1","yes","on": return true
        case "false","0","no","off": return false
        default: return nil
        }
    }

    /// 仕様: "<PostScriptName> <size>"。非推奨の family/size があれば合成。
    private static func parseFont(_ s: String, deprecatedFamily: String?, deprecatedSize: String?) -> NSFont? {
        let comps = s.split(separator: " ", omittingEmptySubsequences: true)
        if comps.count >= 2, let size = Double(comps.last!) {
            let ps = comps.dropLast().joined(separator: " ")
            if let f = NSFont(name: ps, size: CGFloat(size)) { return f }
        }
        if let fam = deprecatedFamily, let sz = deprecatedSize, let d = Double(sz),
           let f = NSFont(name: fam, size: CGFloat(d)) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
    }

    static func makeFont(from spec: KFontSpec) -> NSFont {
        NSFont(name: spec.psName, size: spec.size)
        ?? NSFont.monospacedSystemFont(ofSize: spec.size, weight: .regular)
    }
}
