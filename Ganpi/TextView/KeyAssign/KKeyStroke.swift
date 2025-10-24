//
//  KKeyStroke.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/20,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
//  (keyCode, modifiers) による単一ストローク表現。
//  - Esc と Ctrl+[ は等価に正規化（keyCode=KC.escape, .control は除去）
//  - Command(⌘) は現段階では扱わない
//  - 設定用トークン（例: "<esc>", "<home>"）は KKeyCode.specialToKC を参照
//

import AppKit

struct KKeyStroke: Equatable, Hashable {

    // MARK: - 内部設定

    /// 許可する修飾キー集合
    /// commandを含むが、key assignとしてはcommandは無視される仕様。これはユーザーメニュー構築にも使用するため。
    private static let _allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// 1文字シンボル → keyCode（ANSI US を前提）
    private static let _ansiUSCharToKC: [Character: UInt16] = [
        "a": KC.a, "b": KC.b, "c": KC.c, "d": KC.d, "e": KC.e, "f": KC.f, "g": KC.g, "h": KC.h,
        "i": KC.i, "j": KC.j, "k": KC.k, "l": KC.l, "m": KC.m, "n": KC.n, "o": KC.o, "p": KC.p,
        "q": KC.q, "r": KC.r, "s": KC.s, "t": KC.t, "u": KC.u, "v": KC.v, "w": KC.w, "x": KC.x, "y": KC.y, "z": KC.z,
        "0": KC.n0, "1": KC.n1, "2": KC.n2, "3": KC.n3, "4": KC.n4, "5": KC.n5, "6": KC.n6, "7": KC.n7, "8": KC.n8, "9": KC.n9,
        "-": KC.minus, "=": KC.equal, "[": KC.leftBracket, "]": KC.rightBracket, ";": KC.semicolon,
        "'": KC.quote, ",": KC.comma, ".": KC.period, "/": KC.slash, "\\": KC.backslash, "`": KC.grave
    ]

    // MARK: - プロパティ

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    // MARK: - イニシャライザ

    /// 物理 keyCode 指定（逃げ道用）。修飾は許可集合に正規化。
    init(code keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self._allowedModifiers)
    }

    /// 記述式（1ストローク専用）。例: "ctrl+[", "alt+;", "shift+<tab>", "<esc>", "<home>"
    init?(_ description: String) {
        guard let (mods, core) = Self.parseDescription(description) else { return nil }

        // まず <token> を優先的に解決
        if let kc = KKeyCode.specialToKC[core] {
            // Esc ≡ Ctrl+[ の正規化もここで吸収（<esc> は ctrl を除去）
            let normalizedMods = (kc == KC.escape) ? mods.subtracting([.control]) : mods
            self.keyCode = kc
            self.modifiers = normalizedMods.intersection(Self._allowedModifiers)
            return
        }

        // "ctrl+[" 等の表記（単一可印字文字）を解決
        if core.count == 1, let ch = core.first {
            let lower = Character(String(ch).lowercased())

            // Ctrl+[ → Esc に畳む（vi 互換）
            if lower == "[", mods.contains(.control) {
                self.keyCode = KC.escape
                self.modifiers = mods.subtracting([.control]).intersection(Self._allowedModifiers)
                return
            }

            if let kc = Self._ansiUSCharToKC[lower] {
                self.keyCode = kc
                self.modifiers = mods.intersection(Self._allowedModifiers)
                return
            }
        }

        // どれにも当てはまらなければ失敗
        return nil
    }

    /// 特殊トークン（"<esc>" 等）または 1 文字を直接指定
    init?(symbol: String, modifiers: NSEvent.ModifierFlags = []) {
        let token = symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // トークン優先
        if let kc = KKeyCode.specialToKC[token] {
            let mods = (kc == KC.escape) ? modifiers.subtracting([.control]) : modifiers
            self.keyCode = kc
            self.modifiers = mods.intersection(Self._allowedModifiers)
            return
        }

        // 単一文字
        if token.count == 1, let ch = token.first, let kc = Self._ansiUSCharToKC[Character(String(ch).lowercased())] {
            self.keyCode = kc
            self.modifiers = modifiers.intersection(Self._allowedModifiers)
            return
        }

        return nil
    }

    /// NSEvent から生成（ここで正規化を完結）
    init?(event: NSEvent) {
        let rawMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = rawMods.intersection(Self._allowedModifiers)

        // Esc または Ctrl+[ を Esc に統一
        if event.keyCode == KC.escape || event.charactersIgnoringModifiers == "\u{001B}" {
            self.keyCode = KC.escape
            self.modifiers = mods.subtracting([.control])
            return
        }

        self.keyCode = event.keyCode
        self.modifiers = mods
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: - 内部：記述式パーサ

    /// "ctrl+[", "shift+<tab>", "<esc>" などを (mods, coreToken) に分解する。
    /// coreToken は "<...>" 形式または 1 文字（小文字）に正規化して返す。
    private static func parseDescription(_ raw: String) -> (NSEvent.ModifierFlags, String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // 角括弧トークンはそのまま返す（例: "<esc>", "<home>", "<kp+>"）
        if lower.hasPrefix("<"), lower.hasSuffix(">") {
            return (.init(), lower)
        }

        // 区切りは '+'
        let tokens = lower
            .replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "+" })
            .map { String($0) }

        guard !tokens.isEmpty else { return nil }

        var mods: NSEvent.ModifierFlags = []
        var core: String?

        for t in tokens {
            switch t {
            case "ctrl", "control":
                mods.insert(.control)
            case "alt", "option", "opt":
                mods.insert(.option)
            case "shift":
                mods.insert(.shift)
            case "command", "cmd":
                mods.insert(.command)
            default:
                if core == nil {
                    core = t
                } else {
                    return nil // 非修飾トークンが複数は不正
                }
            }
        }

        guard var coreToken = core, !coreToken.isEmpty else { return nil }

        // 1 文字は小文字に揃える（ANSI マップのキーに合わせる）
        if coreToken.count == 1 {
            coreToken = coreToken.lowercased()
        }

        return (mods, coreToken)
    }
}
