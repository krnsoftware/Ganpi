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
//  Ganpi - macOS Text Editor
//
//  設定ファイル（default.ini, user.ini）を読み込み、
//  内部的に型変換を行った上で value accessor を提供する。
//  列挙型は String のまま保持し、getter 側で fromSetting() を実行。
//  色は light/dark に対応し fallback を処理する。
//


import AppKit

final class KPreference {

    // シングルトン
    static let shared = KPreference()

    // KPrefKey → 生文字列（loader が生成）
    private var _rawValues: [KPrefKey: String] = [:]

    // KPrefKey → 型変換後の値（Color/Font/Bool/Int/Float/String）
    private var _values: [KPrefKey: Any] = [:]

    private init() {}


    // MARK: - Load (default.ini + user.ini)

    func load(defaultURL: URL, userURL: URL?) {
        _rawValues.removeAll()
        _values.removeAll()

        // --- default.ini （必須。読めない場合も空辞書が返る）---
        let rawDefault = KPrefLoader.load(from: defaultURL)
        if rawDefault.isEmpty {
            log("KPreference.load(): default.ini is empty or could not be read")
        }
        merge(rawDefault)

        // --- user.ini （任意。存在しなければ呼び出し側で nil を渡す）---
        if let userURL {
            let rawUser = KPrefLoader.load(from: userURL)
            if rawUser.isEmpty {
                log("KPreference.load(): user.ini is empty or could not be read")
            }
            merge(rawUser)
        }

        // --- 生文字列を内部型へ変換 ---
        convertAll()
    }



    // MARK: - Raw merge

    /// loader の [String:String]（フルキー → 値）を rawValue 辞書へ統合
    private func merge(_ dict: [String:String]) {
        for (fullKey, val) in dict {
            guard let key = KPrefKey(rawValue: fullKey) else {
                log("KPreference.merge(): unknown key '\(fullKey)'")
                continue
            }
            _rawValues[key] = val
        }
    }


    // MARK: - Convert rawValue → typed value

    private func convertAll() {
        for entry in KPrefSchema.all {
            let key = entry.key

            guard let rawStr = _rawValues[key] else {
                // 設定が存在しない（default.ini でも user.ini でも無い）
                // → _values に登録しない（getter 側で default を適用）
                continue
            }

            let converted: Any?

            switch entry.type {

            case .bool:
                converted = Bool(rawStr)

            case .int:
                converted = Int(rawStr)

            case .float:
                converted = CGFloat(Double(rawStr) ?? 0.0)

            case .string:
                converted = rawStr

            case .enumerated:
                converted = rawStr   // enum 化は getter で実施

            case .color:
                converted = parseColor(rawStr)

            case .font:
                converted = parseFont(rawStr)
            }

            if converted == nil {
                log("KPreference.convertAll(): invalid value for \(key.rawValue) = '\(rawStr)'")
            }

            if let v = converted {
                _values[key] = v
            }
        }
    }


    // MARK: - Color/Font parsing

    private func parseColor(_ s: String) -> NSColor? {
        // "#RRGGBB" 形式
        guard s.hasPrefix("#") else { return nil }
        let hex = String(s.dropFirst())

        guard hex.count == 6,
              let rgb = Int(hex, radix: 16) else { return nil }

        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    private func parseFont(_ s: String) -> NSFont? {
        // "FontName 14.0"
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let fam = parts.dropLast().joined(separator: " ")
        guard let size = Double(parts.last!) else { return nil }

        return NSFont(name: fam, size: CGFloat(size))
    }


    // MARK: - Getter（型別アクセサ）

    func bool(_ key: KPrefKey, default def: Bool) -> Bool {
        (_values[key] as? Bool) ?? def
    }

    func int(_ key: KPrefKey, default def: Int) -> Int {
        (_values[key] as? Int) ?? def
    }

    func float(_ key: KPrefKey, default def: CGFloat) -> CGFloat {
        (_values[key] as? CGFloat) ?? def
    }

    func string(_ key: KPrefKey, default def: String = "") -> String {
        (_values[key] as? String) ?? def
    }

    func color(_ key: KPrefKey,
               lightDefault: NSColor,
               darkDefault: NSColor) -> NSColor {

        // 値そのもの
        if let c = _values[key] as? NSColor {
            return c
        }

        // dark の fallback 判定は外部（KParser など）が呼ぶ想定
        return lightDefault
    }

    func font(_ key: KPrefKey, default def: NSFont) -> NSFont {
        (_values[key] as? NSFont) ?? def
    }
}
