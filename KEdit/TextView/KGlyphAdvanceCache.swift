//
//  KGlyphAdvanceCache.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

// 表示される文字の横幅をキャッシュするためのクラス。
// 本文の文字列を可能な限りCTLineを生成せずに構築する目的。
// 現状ではフォント・フォントサイズが変更になった場合はインスタンスを破棄して再生成する。


import Foundation
import AppKit
import CoreText
import os.lock

final class KGlyphAdvanceCache {

    private let _font: NSFont
    private var _advanceCache: [Character: CGFloat] = [:]
    private var _advanceLock = os_unfair_lock_s()
    //private var _tabWidth: CGFloat
    //private let _lock = NSLock()

    private static let _defaultCharacters: [Character] = {
        var result: [Character] = []

        // ASCII（0x20〜0x7E）: 95文字
        result += (0x20...0x7E).compactMap { UnicodeScalar($0).map(Character.init) }

        // ひらがな（0x3040〜0x309F）: 約96文字
        result += (0x3040...0x309F).compactMap { UnicodeScalar($0).map(Character.init) }

        // カタカナ（0x30A0〜0x30FF）: 約96文字
        result += (0x30A0...0x30FF).compactMap { UnicodeScalar($0).map(Character.init) }

        // 記号類（全角スペースや句読点など）: 数文字
        result += [0x3000, 0x3001, 0x3002, 0x30FB].compactMap { UnicodeScalar($0).map(Character.init) }

        // 漢字（JIS第一水準の一部）: 最大で9000文字程度に制限
        let kanjiMaxCount = max(0, 10000 - result.count)
        result += (0x4E00...0x9FFF).prefix(kanjiMaxCount).compactMap { UnicodeScalar($0).map(Character.init) }

        return result
    }()

    var count: Int {
        os_unfair_lock_lock(&_advanceLock)
        defer { os_unfair_lock_unlock(&_advanceLock) }
        return _advanceCache.count
    }
    

    init(font: NSFont) {
        self._font = font
        
        let timer = KTimeChecker(name:"preload")
        preload()
        timer.stop()
    }
    
    
    // advanceはあくまでレイアウト用の仮の値。実測はCTLineに基いて行う。
    /*
    func advance(for character: Character) -> CGFloat {
        os_unfair_lock_lock(&_advanceLock)
        defer { os_unfair_lock_unlock(&_advanceLock) }
        
        if let cached = _advanceCache[character] {
            return cached
        }

        let string = String(character)
        let utf16Length = string.utf16.count

        let attr = NSAttributedString(string: string, attributes: [.font: _font])
        let line = CTLineCreateWithAttributedString(attr)

        let advance = CTLineGetOffsetForStringIndex(line, utf16Length, nil)

        _advanceCache[character] = advance
        return advance
    }*/
    func advance(for character: Character) -> CGFloat {
        // 読み取り用ロック（ロック競合を避ける簡易読み出し）
        var cached: CGFloat? = nil
        os_unfair_lock_lock(&_advanceLock)
        cached = _advanceCache[character]
        os_unfair_lock_unlock(&_advanceLock)

        if let cached {
            return cached
        }

        // ここでCTLine生成
        let string = String(character)
        let utf16Length = string.utf16.count
        let attr = NSAttributedString(string: string, attributes: [.font: _font])
        let line = CTLineCreateWithAttributedString(attr)
        let advance = CTLineGetOffsetForStringIndex(line, utf16Length, nil)

        // 書き込み時だけロック
        os_unfair_lock_lock(&_advanceLock)
        _advanceCache[character] = advance
        os_unfair_lock_unlock(&_advanceLock)

        return advance
    }
    
    
    func advances(for characters: [Character], in range: Range<Int>) -> [CGFloat] {
        guard range.lowerBound >= 0, range.upperBound <= characters.count else {
            log("range is out of bounds", from:self)
                return []
        }
        
        
        return characters[range].map { advance(for: $0) }
        
        
        /* まったく処理速度が上がらなかったため削除。
        let count = range.count
        var result: [CGFloat] = []
        result.reserveCapacity(count)

        characters.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress! + range.lowerBound
            for i in 0..<count {
                let ch = base[i]
                result.append(advance(for: ch))
            }
        }
        return result
         */
    }
    
    func width(for characters: [Character], in range: Range<Int>) -> CGFloat {
        guard !characters.isEmpty else { return 0 }

        os_unfair_lock_lock(&_advanceLock)
        defer { os_unfair_lock_unlock(&_advanceLock) }
        
        var total: CGFloat = 0

        for i in range {
            if i >= 0 && i < characters.count {
                total += advance(for: characters[i])
            }
        }

        return total
    }
    
    /*
    func register(characters: [Character]) {
        let unknown = characters.filter { _advanceCache[$0] == nil }
        let attrString = NSAttributedString(
            string: String(unknown),
            attributes: [.font: _font]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        var previousOffset: CGFloat = 0

        for (i, character) in unknown.enumerated() {
            let offset = CTLineGetOffsetForStringIndex(line, i + 1, nil)
            let advance = offset - previousOffset
            _advanceCache[character] = advance
            previousOffset = offset
        }
    }*/
    func register(characters: [Character]) {
        //let newChars = characters.filter { _advanceCache[$0] == nil }
        // 1670ms -> 67ms
        let newChars = Array(Set(characters.filter { _advanceCache[$0] == nil }))
        guard !newChars.isEmpty else { return }

        let joined = String(newChars)
        let attrStr = NSAttributedString(string: joined, attributes: [.font: _font])
        let ctLine = CTLineCreateWithAttributedString(attrStr)

        // UTF16 offsetを追跡
        var currentUTF16Offset = 0
        for char in newChars {
            let str = String(char)
            let utf16Length = str.utf16.count

            let startOffset = CTLineGetOffsetForStringIndex(ctLine, currentUTF16Offset, nil)
            let endOffset = CTLineGetOffsetForStringIndex(ctLine, currentUTF16Offset + utf16Length, nil)
            let advance = endOffset - startOffset

            _advanceCache[char] = advance
            currentUTF16Offset += utf16Length
        }
    }
    
    func setParticularCache(_ advance: CGFloat, for character: Character) {
        _advanceCache[character] = advance
    }

    
    private func preload() {
        register(characters: Self._defaultCharacters)
    }
}
