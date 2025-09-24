//
//  KUndoManager.swift
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/24,
//  Revised by Sebastian for robust/efficient Undo (String+MMAP offload)
//

import AppKit
import QuartzCore // CACurrentMediaTime

// MARK: - 文字列ペイロード（通常は inline、巨大時はファイルオフロード）
enum KUndoPayload: CustomStringConvertible {
    case inline(String)
    case blob(KBlobRef)

    var byteCount: Int {
        switch self {
        case .inline(let s): return s.utf8.count
        case .blob(let ref): return ref.byteCount
        }
    }

    var description: String {
        switch self {
        case .inline(let s):
            return "inline(\(s.count)ch/\(s.utf8.count)B)"
        case .blob(let ref):
            return "blob(\(ref.byteCount)B @\(ref.path.lastPathComponent))"
        }
    }

    // 必要時に String を取り出す（blob はマップ読み）
    func resolvedString(using store: KBlobStore) -> String {
        switch self {
        case .inline(let s): return s
        case .blob(let ref): return store.readString(ref: ref) ?? ""
        }
    }
}

// 1回の差分編集
struct KUndoUnit: CustomStringConvertible {
    let range: Range<Int>          // 編集前のインデックス基準
    let oldPayload: KUndoPayload
    let newPayload: KUndoPayload
    let timeStamp: CFTimeInterval  // グルーピングのための時刻

    var description: String {
        "KUndoUnit{ range:\(range), old:\(oldPayload), new:\(newPayload), t:\(timeStamp) }"
    }
}

// 人間の操作ひとかたまり（classにして追記が参照共有で反映）
final class KUndoGroup: CustomStringConvertible {
    var units: [KUndoUnit] = []

    var totalBytes: Int {
        units.reduce(0) { $0 + $1.oldPayload.byteCount + $1.newPayload.byteCount }
    }

    var description: String {
        var s = "KUndoGroup(totalBytes:\(totalBytes))\n"
        for u in units { s += "  \(u)\n" }
        return s
    }
}

// MARK: - Undo Manager（2スタック方式＋メモリ上限＋オフロード）
final class KUndoManager {

    // 依存: KTextStorage には replaceString(in:with:) がある前提
    private weak var _storage: KTextStorage?

    // 履歴（最新は末尾）
    private var _undoStack: [KUndoGroup] = []
    private var _redoStack: [KUndoGroup] = []

    // 進行中のグルーピング
    private var _pendingGroup: KUndoGroup?
    private var _lastGroupTime: CFTimeInterval?

    // 実行状態
    private var _isPerformingUndoRedo: Bool = false

    // ペイロード保管（大差分はファイルへ）
    private let _blobStore: KBlobStore

    // 設定
    private let _groupingThreshold: CFTimeInterval = 0.30     // 0.2〜0.3s 推奨
    private let _inlineThresholdBytes: Int = 8 * 1024         // 8KB超はblob化
    private var _byteLimit: Int                               // 総量上限（B）
    private var _currentBytes: Int = 0                        // 現在の累積B

    // MARK: - Init

    init(with storage: KTextStorage,
         byteLimitMB: Int = 64,
         blobDirectory: URL? = nil) {
        _storage = storage
        _byteLimit = max(1, byteLimitMB) * 1024 * 1024
        _blobStore = KBlobStore(baseURL: blobDirectory)
    }

    // MARK: - 外部API

    /// 編集発生毎に呼ぶ。range は「編集前」のインデックス基準。
    /// oldString/newString は編集前/後の文字列。
    func register(range: Range<Int>, oldString: String, newString: String) {
        // Undo/Redo実行中は履歴を積まない
        if _isPerformingUndoRedo { return }

        // 新規編集が入る時点で Redo は無効
        if !_redoStack.isEmpty { _redoStack.removeAll(keepingCapacity: true) }

        // ペイロードの格納方針を決める（大差分はblob）
        let now = CACurrentMediaTime()
        let oldPayload = makePayload(from: oldString)
        let newPayload = makePayload(from: newString)

        // 直近のグループへ追記 or 新規開始
        let group = currentOrNewGroup(now: now)
        let unit = KUndoUnit(range: range, oldPayload: oldPayload, newPayload: newPayload, timeStamp: now)
        group.units.append(unit)

        // メモリ使用量の更新（pending中も反映：上限超を早めに検知）
        _currentBytes &+= (oldPayload.byteCount + newPayload.byteCount)

        // 上限管理（最低1回Undo保証）
        trimIfNeeded(keepingAtLeastLatest: true)
    }

    /// 入力の一息（タイマー・キーアップ・フォーカス移動など）で呼ぶとグループ確定
    func flushGrouping() {
        finalizePendingGroupIfNeeded()
    }

    func resetUndoHistory() {
        // blob も含めて全部破棄
        _undoStack.removeAll(keepingCapacity: true)
        _redoStack.removeAll(keepingCapacity: true)
        _pendingGroup = nil
        _lastGroupTime = nil
        _currentBytes = 0
        _blobStore.clearAll()
    }

    func canUndo() -> Bool {
        return !_undoStack.isEmpty || (_pendingGroup?.units.isEmpty == false)
    }

    func canRedo() -> Bool {
        return !_redoStack.isEmpty
    }

    func setByteLimitMB(_ mb: Int) {
        _byteLimit = max(1, mb) * 1024 * 1024
        trimIfNeeded(keepingAtLeastLatest: true)
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let storage = _storage else { NSSound.beep(); return }

        // 未確定グループも対象に含める（確定してから扱う）
        finalizePendingGroupIfNeeded()
        guard !_undoStack.isEmpty else { NSSound.beep(); return }

        _isPerformingUndoRedo = true
        defer { _isPerformingUndoRedo = false }

        let group = _undoStack.removeLast()

        // 取り消しは逆順で適用（rangeは編集前基準）
        for unit in group.units.reversed() {
            // new の実際の文字列を解決
            let newStr = unit.newPayload.resolvedString(using: _blobStore)
            let oldStr = unit.oldPayload.resolvedString(using: _blobStore)

            // 「編集後に存在している長さ」分を削って old に戻す
            let replaced = unit.range.lowerBound ..< (unit.range.lowerBound + newStr.count)
            _ = storage.replaceString(in: replaced, with: oldStr)
        }

        // Redo用に積み替え
        _redoStack.append(group)
    }

    func redo() {
        guard let storage = _storage else { NSSound.beep(); return }
        guard !_redoStack.isEmpty else { NSSound.beep(); return }

        _isPerformingUndoRedo = true
        defer { _isPerformingUndoRedo = false }

        let group = _redoStack.removeLast()

        // やり直しは記録順で適用
        for unit in group.units {
            let newStr = unit.newPayload.resolvedString(using: _blobStore)
            _ = storage.replaceString(in: unit.range, with: newStr)
        }

        _undoStack.append(group)
    }

    // MARK: - 内部：グルーピング

    private func currentOrNewGroup(now: CFTimeInterval) -> KUndoGroup {
        if let t = _lastGroupTime, let g = _pendingGroup, now - t < _groupingThreshold {
            // 同一グループ継続
            _lastGroupTime = now
            return g
        } else {
            // ★しきい値超え：古い pending を確定してから新規グループを開始
            finalizePendingGroupIfNeeded()
            let g = KUndoGroup()
            _pendingGroup = g
            _lastGroupTime = now
            return g
        }
    }

    private func finalizePendingGroupIfNeeded() {
        guard let g = _pendingGroup, !g.units.isEmpty else { return }
        _undoStack.append(g)
        _pendingGroup = nil
        _lastGroupTime = nil
        // _currentBytes は register 時に加算済みなのでここでは触らない
    }

    // MARK: - 内部：容量制御（最低1回Undo保証）

    private func trimIfNeeded(keepingAtLeastLatest: Bool) {
        // 現在の栄養価（ペイロード総量）が上限を超えたら古い方から削る
        guard _currentBytes > _byteLimit else { return }

        // まず pending を確定（古い方から確実に落とせるようにする）
        finalizePendingGroupIfNeeded()

        // undoStack の先頭（最古）から削除。ただし keepingAtLeastLatest=true の場合、
        // 少なくとも「最新の1グループ」は残す。
        while _currentBytes > _byteLimit && _undoStack.count > (keepingAtLeastLatest ? 1 : 0) {
            let removed = _undoStack.removeFirst()
            _currentBytes &-= removed.totalBytes
            // blobの掃除
            cleanupBlobs(in: removed)
        }

        // それでも超過＝最新グループ自体が巨大。
        // 最新1グループは残しつつ、その中の inline を極力 blob 化して RAM を抑える。
        if _currentBytes > _byteLimit, let latest = _undoStack.last {
            var deltaReduced = 0
            for i in 0..<latest.units.count {
                let u = latest.units[i]
                // old
                if case .inline(let s) = u.oldPayload, s.utf8.count > _inlineThresholdBytes {
                    if let ref = _blobStore.writeString(s) {
                        let newPayload = KUndoPayload.blob(ref)
                        deltaReduced += (s.utf8.count - newPayload.byteCount) // 実質は同程度だが、String常駐分を削減
                        latest.units[i] = KUndoUnit(range: u.range, oldPayload: newPayload, newPayload: u.newPayload, timeStamp: u.timeStamp)
                    }
                }
                // new
                let u2 = latest.units[i]
                if case .inline(let s) = u2.newPayload, s.utf8.count > _inlineThresholdBytes {
                    if let ref = _blobStore.writeString(s) {
                        let newPayload = KUndoPayload.blob(ref)
                        deltaReduced += (s.utf8.count - newPayload.byteCount)
                        latest.units[i] = KUndoUnit(range: u2.range, oldPayload: u2.oldPayload, newPayload: newPayload, timeStamp: u2.timeStamp)
                    }
                }
            }
            // Stringの常駐は ARC 解放タイミングに依存するため、厳密なB削減の反映は難しいが、
            // ここでは概算として inline -> blob 化により _currentBytes をオフセット更新しておく。
            if deltaReduced > 0 { _currentBytes &-= max(0, deltaReduced) }
        }
    }

    private func cleanupBlobs(in group: KUndoGroup) {
        for u in group.units {
            if case .blob(let ref) = u.oldPayload {
                _blobStore.remove(ref: ref)
            }
            if case .blob(let ref) = u.newPayload {
                _blobStore.remove(ref: ref)
            }
        }
    }

    // MARK: - 内部：ペイロード生成

    private func makePayload(from string: String) -> KUndoPayload {
        let bytes = string.utf8.count
        if bytes > _inlineThresholdBytes {
            if let ref = _blobStore.writeString(string) {
                return .blob(ref)
            }
        }
        return .inline(string)
    }
}

// MARK: - 便宜: String/Path補助
private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

// newPayloadの「文字数」に基づく置換長が必要な場合の補助（Character数でやるならStorage仕様に合わせて調整）
private extension KUndoPayload {
    func byteCountComputedAsCharactersCount(using store: KBlobStore) -> Int {
        switch self {
        case .inline(let s): return s.count
        case .blob(let ref):
            if let s = store.readString(ref: ref) { return s.count }
            return 0
        }
    }
}
