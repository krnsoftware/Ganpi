//
//  KKeymapBundle.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/21,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Cocoa

struct KKeymapBundle {
    let normal: [KShortCut]
    let edit: [KShortCut]
}

enum KKeymapError: Error {
    case cannotRead
    case invalidFormat(Int)
}

struct KKeymapLoader {
    private init(){}

    static func load(from url: URL) throws -> KKeymapBundle {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw KKeymapError.cannotRead
        }

        var shortcutsNormal: [KShortCut] = []
        var shortcutsEdit: [KShortCut] = []

        var currentMode: KEditMode = .normal
        let lines = text.split(whereSeparator: \.isNewline)
        var lineNo = 0

        for raw in lines {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Skip blank or comment line
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            // Section header
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().lowercased()
                switch name {
                case "normal": currentMode = .normal
                case "edit":   currentMode = .edit
                default:
                    log("load(from:): Line \(lineNo): unknown section '\(name)'")
                }
                continue
            }

            // Split at ":"
            guard let colon = line.firstIndex(of: ":") else {
                log("load(from:): Line \(lineNo): missing ':'")
                continue
            }

            let leftText = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rightText = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Parse keys
            let keyTokens = leftText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            var keySeq: [KKeyStroke] = []

            for tok in keyTokens {
                if let ks = KKeyStroke(tok) {
                    keySeq.append(ks)
                } else {
                    log("load(from:): Line \(lineNo): invalid keystroke token '\(tok)'")
                }
            }

            // Parse right-hand actions
            let actions = parseActions(from: rightText)

            if keySeq.isEmpty || actions.isEmpty {
                //log("load(from:): Line \(lineNo): skipped (no valid keys or actions)")
                continue
            }

            let sc = KShortCut(keys: keySeq, actions: actions)
            switch currentMode {
            case .normal: shortcutsNormal.append(sc)
            case .edit:   shortcutsEdit.append(sc)
            }
        }

        //log("load(from:): Loaded \(shortcutsNormal.count) normal and \(shortcutsEdit.count) edit shortcuts from INI file")
        return KKeymapBundle(normal: shortcutsNormal, edit: shortcutsEdit)
    }

    // MARK: - Parse right-hand actions into [KAction]
    private static func parseActions(from rightSide: String) -> [KAction] {
        let tokens = rightSide
            .split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [KAction] = []

        for tok in tokens {
            if let open = tok.firstIndex(of: "["), let close = tok.lastIndex(of: "]"), close > open {
                let head = String(tok[..<open]).lowercased()
                let body = String(tok[tok.index(after: open)..<close])
                switch head {
                case "execute":
                    result.append(.command(.execute(body)))
                case "load", "":
                    result.append(.command(.load(body))) // "[path]" is shorthand of "load[path]"
                default:
                    log("Unknown command '\(head)' ignored")
                }
            } else {
                result.append(.selector(tok.hasSuffix(":") ? String(tok.dropLast()) : tok))
            }
        }
        return result
    }
}
