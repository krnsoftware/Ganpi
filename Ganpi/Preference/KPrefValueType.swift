//
//  KPrefValueType.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/29,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

// MARK: - 値の型

enum KPrefValueType {
    case bool, int, float, string, color, font
}

// MARK: - スキーマ（単一の真実）

struct KPrefSchemaEntry {
    let key: String
    let type: KPrefValueType
    let defaultValue: Any
    let validate: ((Any) -> Any)?   // 必要に応じて最小限のクランプ等
}

final class KPreferenceSchema {
    static let shared = KPreferenceSchema()
    private init() { registerDefaults() }

    private var _entries: [String: KPrefSchemaEntry] = [:]  // private varは_始まり

    func entry(for key: String) -> KPrefSchemaEntry? { _entries[key] }

    private func register(_ e: KPrefSchemaEntry) { _entries[e.key] = e }

    /// アプリ内蔵の既定値をここに集約。これが中央集権の既定セット。
    private func registerDefaults() {
        // 可視/不可視：初期トグル（default）
        register(.init(key: KPrefKey.parserBaseShowInvisiblesDefault,
                       type: .bool, defaultValue: true, validate: nil))

        // 不可視：種別構成（iniで編集可・ランタイムでは不変）
        register(.init(key: KPrefKey.parserBaseShowInvisiblesTab,     type: .bool, defaultValue: true,  validate: nil))
        register(.init(key: KPrefKey.parserBaseShowInvisiblesNewline, type: .bool, defaultValue: true,  validate: nil))
        register(.init(key: KPrefKey.parserBaseShowInvisiblesSpace,   type: .bool, defaultValue: true,  validate: nil))
        register(.init(key: KPrefKey.parserBaseShowInvisiblesFull,    type: .bool, defaultValue: false, validate: nil))

        // 不可視記号（\u許容・空は既定へフォールバック）
        register(.init(key: KPrefKey.parserBaseGlyphNewline, type: .string, defaultValue: "\u{21B5}", validate: { v in
            (v as? String).flatMap(Self.nonEmptyEscaped) ?? "\u{21B5}"
        }))
        register(.init(key: KPrefKey.parserBaseGlyphTab,     type: .string, defaultValue: "»", validate: { v in
            (v as? String).flatMap(Self.nonEmptyEscaped) ?? "»"
        }))
        register(.init(key: KPrefKey.parserBaseGlyphSpace,   type: .string, defaultValue: "·", validate: { v in
            (v as? String).flatMap(Self.nonEmptyEscaped) ?? "·"
        }))
        register(.init(key: KPrefKey.parserBaseGlyphFull,    type: .string, defaultValue: "□", validate: { v in
            (v as? String).flatMap(Self.nonEmptyEscaped) ?? "□"
        }))

        // 色（内部はNSColor。入力は #RRGGBB(A)）
        register(.init(key: KPrefKey.parserBaseColorInvisibles, type: .color, defaultValue: NSColor(calibratedWhite: 0.56, alpha: 1.0), validate: nil))
        register(.init(key: KPrefKey.parserBaseColorSelection,  type: .color, defaultValue: NSColor(calibratedRed: 0.82, green: 0.82, blue: 1.0, alpha: 1.0), validate: nil))
        register(.init(key: KPrefKey.parserBaseColorText,       type: .color, defaultValue: NSColor.labelColor, validate: nil))
        register(.init(key: KPrefKey.parserBaseColorBackground, type: .color, defaultValue: NSColor.textBackgroundColor, validate: nil))

        // フォント（PS+サイズの仕様。既定はシステム等幅）
        register(.init(key: KPrefKey.parserBaseFont, type: .font,
                       defaultValue: Self.defaultFontSpec(), validate: { $0 }))

        // default 群（クランプ）
        register(.init(key: KPrefKey.parserBaseDefaultTabWidth,    type: .int,   defaultValue: 4,   validate: { KPreferenceSchema.clampInt($0, min: 1, max: 16, def: 4) }))
        register(.init(key: KPrefKey.parserBaseDefaultLineSpacing, type: .float, defaultValue: 1.2, validate: { KPreferenceSchema.clampFloat($0, min: 0.8, max: 3.0, def: 1.2) }))
        register(.init(key: KPrefKey.parserBaseDefaultWordWrap,    type: .bool,  defaultValue: true,  validate: nil))
        register(.init(key: KPrefKey.parserBaseDefaultAutoIndent,  type: .bool,  defaultValue: true,  validate: nil))
    }

    // MARK: - validate helpers

    private static func nonEmptyEscaped(_ s: String) -> String? {
        let unescaped = unescapeUnicode(s)
        return unescaped.isEmpty ? nil : unescaped
    }

    /// \uXXXX / \UXXXXXXXX を実体化（簡易版）
    private static func unescapeUnicode(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" {
                let j = s.index(after: i)
                if j < s.endIndex, (s[j] == "u" || s[j] == "U") {
                    let count = (s[j] == "u") ? 4 : 8
                    let start = s.index(j, offsetBy: 1, limitedBy: s.endIndex) ?? s.endIndex
                    let end   = s.index(start, offsetBy: count, limitedBy: s.endIndex) ?? s.endIndex
                    let hex   = String(s[start..<end])
                    if let val = UInt32(hex, radix: 16), let scalar = UnicodeScalar(val) {
                        out.unicodeScalars.append(scalar)
                        i = end
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func clampInt(_ v: Any, min: Int, max: Int, def: Int) -> Int {
        guard let n = v as? Int else { return def }
        return Swift.max(min, Swift.min(max, n))
    }

    static func clampFloat(_ v: Any, min: CGFloat, max: CGFloat, def: CGFloat) -> CGFloat {
        if let d = v as? Double { return Swift.max(min, Swift.min(max, CGFloat(d))) }
        if let g = v as? CGFloat { return Swift.max(min, Swift.min(max, g)) }
        return def
    }

    private static func defaultFontSpec() -> KFontSpec {
        let f = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        return KFontSpec(psName: f.fontName, size: f.pointSize)
    }
}

// MARK: - FontSpec

struct KFontSpec {
    let psName: String
    let size: CGFloat
}
