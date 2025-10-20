//
//  KKeymapBundle.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/21,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



//
//  KKeymapLoader.swift
//  Ganpi
//
//  Created by KARINO Masatsugu for Ganpi Project.
//  All rights reserved.
//
//  Keymap INI file loader for Ganpi
//  - Format:
//      [normal]
//      ctrl+a : moveToBeginningOfParagraph
//      [edit]
//      h : moveLeft
//
//  Supports UTF-8 LF only.
//  Comments: lines beginning with # or ; are ignored.
//  No inline comment supported.
//

import Foundation
import AppKit

struct KKeymapBundle {
    var normal: [KKeyAssign.KShortCut]
    var edit:   [KKeyAssign.KShortCut]
}

struct KKeymapLoader {

    private init() {}

    static func load(from url: URL) throws -> KKeymapBundle {

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "KKeymapLoader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to read keymap file (not UTF-8)"])
        }

        var currentMode: KEditMode = .normal
        var normal: [KKeyAssign.KShortCut] = []
        var edit: [KKeyAssign.KShortCut] = []

        let lines = content.components(separatedBy: .newlines)
        var lineNumber = 0

        for rawLine in lines {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // skip empty and comment
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            // section header
            if line.lowercased() == "[normal]" {
                currentMode = .normal
                continue
            } else if line.lowercased() == "[edit]" {
                currentMode = .edit
                continue
            }

            // "keys : actions"
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                log("Parse error at line \(lineNumber): missing ':' separator")
                continue
            }

            let keyTokens = parts[0].split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map { String($0) }
            let actionTokens = parts[1].split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map { String($0) }

            var strokes: [KKeyStroke] = []
            var actions: [String] = []

            for token in keyTokens {
                if let stroke = KKeyStroke(token) {
                    strokes.append(stroke)
                } else {
                    log("Line \(lineNumber): invalid keystroke token '\(token)'")
                }
            }

            for token in actionTokens {
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }

                // command形式 execute[file], load[file], or [file]
                if trimmed.hasPrefix("execute[") || trimmed.hasPrefix("load[") || trimmed.hasPrefix("[") {
                    actions.append(trimmed)
                } else {
                    // セレクタ名として":"を付ける（未指定なら）
                    actions.append(trimmed.hasSuffix(":") ? trimmed : trimmed + ":")
                }
            }

            if strokes.isEmpty || actions.isEmpty {
                log("Line \(lineNumber): skipped (no valid keys or actions)")
                continue
            }

            let shortcut = KKeyAssign.KShortCut(keys: strokes, actions: actions)

            switch currentMode {
            case .normal: normal.append(shortcut)
            case .edit:   edit.append(shortcut)
            }
        }

        log("Loaded \(normal.count) normal shortcuts and \(edit.count) edit shortcuts from INI file")

        return KKeymapBundle(normal: normal, edit: edit)
    }
}