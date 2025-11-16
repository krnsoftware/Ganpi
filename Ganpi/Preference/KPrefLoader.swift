//
//  KPrefLoaderError.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/16,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



//
//  KPrefLoader.swift
//  Ganpi - macOS Text Editor
//
//  読み取り専用の INI ローダ。
//  default.ini / user.ini を読んで
//  [String:String] 形式の辞書を返す。
//  値が "?" の場合は KPreference 側で未設定(nil)扱い。
//  guard let での失敗は必ず log を出す。
//  コメントは行頭の # ; のみ有効。
//  キーが "." で始まる場合は現在のカテゴリ名を接頭辞として連結。
//  例: [parser.base] + .color.text → "parser.base.color.text"
//

import Foundation

struct KPrefLoader {

    private init() {}

    /// INI ファイルを読み込み、キーと値の辞書を返す。
    /// user.ini → default.ini の順に読み込む場合は、
    /// 先に default を読み、後で user を上書きする。
    static func load(from url: URL) -> [String:String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            log("KPrefLoader: cannot read file at \(url.path)")
            return [:]
        }

        var results: [String:String] = [:]
        var category = ""
        let lines = text.split(whereSeparator: \.isNewline)

        var lineNo = 0

        for rawLine in lines {
            lineNo += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 空行・コメント行のスキップ
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }

            // セクション行
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = line.dropFirst().dropLast()
                let cat = name.trimmingCharacters(in: .whitespaces)
                if cat.isEmpty {
                    log("KPrefLoader: Line \(lineNo): empty section name")
                } else {
                    category = cat
                }
                continue
            }

            // "=" ではなく ":" で分割
            guard let colon = line.firstIndex(of: ":") else {
                log("KPrefLoader: Line \(lineNo): missing ':' in '\(line)'")
                continue
            }

            let left = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let right = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if left.isEmpty {
                log("KPrefLoader: Line \(lineNo): empty key")
                continue
            }

            // フルパスキーの生成
            let fullKey: String
            if left.hasPrefix(".") {
                // カテゴリ名 + left
                if category.isEmpty {
                    log("KPrefLoader: Line \(lineNo): key '\(left)' used without a category")
                    continue
                }
                // ".xxx" → "category.xxx"
                fullKey = category + left
            } else {
                // そのままフルパス扱い
                fullKey = left
            }

            // 値（String）のまま格納
            results[fullKey] = right
        }

        return results
    }
}
