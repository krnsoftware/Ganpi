//
//  KBlobRef.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/25,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
//  簡易な文字列ペイロードのファイルオフロード（読み込み時はメモリマップ）
//

import Foundation

struct KBlobRef: Hashable {
    let path: String
    let offset: Int
    let length: Int
    let byteCount: Int
}

final class KBlobStore {

    // 基本は ~/Library/Caches/GanpiUndo/
    private let _baseURL: URL
    private let _fm = FileManager.default

    init(baseURL: URL? = nil) {
        if let u = baseURL {
            _baseURL = u
        } else {
            let caches = _fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            _baseURL = caches.appendingPathComponent("GanpiUndo", isDirectory: true)
        }
        try? _fm.createDirectory(at: _baseURL, withIntermediateDirectories: true, attributes: nil)
    }

    // 文字列をUTF-8として保存し、その参照を返す
    @discardableResult
    func writeString(_ string: String) -> KBlobRef? {
        let data = Data(string.utf8)
        let name = UUID().uuidString + ".txtblob"
        let url = _baseURL.appendingPathComponent(name, isDirectory: false)
        do {
            // 書き込み
            try data.write(to: url, options: [.atomic])
            return KBlobRef(path: url.path, offset: 0, length: data.count, byteCount: data.count)
        } catch {
            NSLog("KBlobStore write failed: \(error.localizedDescription)")
            return nil
        }
    }

    // マップ読みで文字列化
    func readString(ref: KBlobRef) -> String? {
        let url = URL(fileURLWithPath: ref.path)
        do {
            let mapped = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
            // 範囲がファイル全体想定だが、将来オフセット/長さに対応可能
            return String(decoding: mapped, as: UTF8.self)
        } catch {
            NSLog("KBlobStore read failed: \(error.localizedDescription)")
            return nil
        }
    }

    // 単一削除
    func remove(ref: KBlobRef) {
        let url = URL(fileURLWithPath: ref.path)
        try? _fm.removeItem(at: url)
    }

    // 全削除（リセット用）
    func clearAll() {
        guard let files = try? _fm.contentsOfDirectory(at: _baseURL, includingPropertiesForKeys: nil) else { return }
        for f in files { try? _fm.removeItem(at: f) }
    }
}
