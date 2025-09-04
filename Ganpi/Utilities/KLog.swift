//
//  KLogEntry.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/04,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import Foundation

// 新規ログ追記時の通知
extension Notification.Name {
    static let KLogDidAppend = Notification.Name("KLogDidAppend")
}

// 1件のログ
struct KLogEntry {
    let date: Date
    let id: String
    let message: String
}

/// シングルトン・ロガー
/// - API: KLog.shared.log(id: "parser", message: "開始")
/// - UI: snapshot() で全件取得、追記時は .KLogDidAppend を発火
final class KLog {

    static let shared = KLog()

    // 設定
    var capacity: Int { _capacity }

    // 内部状態（リングバッファ）
    private let _queue = DispatchQueue(label: "com.drycarbon.ganpi.klog")
    private let _capacity: Int
    private var _entries: [KLogEntry?]
    private var _head = 0         // 次に書く位置
    private var _count = 0        // 現在件数

    // 初期化（容量だけ指定可能）
    private init(capacity: Int = 1000) {
        _capacity = max(100, capacity)
        _entries = Array(repeating: nil, count: _capacity)
    }

    /// ログを1件追加（軽量・スレッドセーフ）
    func log(id: String, message: String) {
        let entry = KLogEntry(date: Date(), id: id, message: message)
        _queue.async {
            self._entries[self._head] = entry
            self._head = (self._head + 1) % self._capacity
            if self._count < self._capacity { self._count += 1 }

            // UIへ通知（メインスレッド）
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .KLogDidAppend, object: nil)
            }
        }
    }

    /// 現在のログ（古い→新しい順）をスナップショット
    func snapshot() -> [KLogEntry] {
        var result: [KLogEntry] = []
        _queue.sync {
            guard _count > 0 else { return }
            result.reserveCapacity(_count)
            let start = (_head - _count + _capacity) % _capacity
            for i in 0..<_count {
                let idx = (start + i) % _capacity
                if let e = _entries[idx] { result.append(e) }
            }
        }
        return result
    }
}
