//
//  KSyntaxParserPlain.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/08/20.
//

import AppKit

// KSyntaxParserProtocolの最小実装。
final class KSyntaxParserPlain: KSyntaxParserProtocol {
    private unowned let _storage: KTextStorageReadable
    var storage: KTextStorageReadable { _storage }
    init(storage: KTextStorageReadable) { _storage = storage }

    func noteEdit(oldRange: Range<Int>, newCount: Int) { /* no-op */ }
    func ensureUpToDate(for range: Range<Int>) { /* no-op */ }
    func parse(range: Range<Int>) { /* no-op */ }

    // ハイライトなし
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan] { [] }
    
    // 欧文のみ（日本語は storage.wordRange が先に処理）
    func wordRange(at index: Int) -> Range<Int>? {
        //return storage.wordRange(at: index)
        return nil
    }
}


