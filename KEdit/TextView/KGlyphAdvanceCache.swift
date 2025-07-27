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

final class KGlyphAdvanceCache {

    private let _font: NSFont
    private var _advanceCache: [Character: CGFloat] = [:]
    //private var _tabWidth: CGFloat
    private let _lock = NSLock()

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
        _lock.lock()
        defer { _lock.unlock() }
        return _advanceCache.count
    }
    

    init(font: NSFont) {
        self._font = font
        preload()
    }
    
    // CTLineからoffsetのリストを返す。
    // 行それぞれで形成されるCTLineでキャッシュではなく実測による補正を行う。
    /*static func offsets(of ctLine: CTLine) -> [CGFloat] {
        var offsets:[CGFloat] = []
        for i in 0..<
        return []
    }*/

    /*func advance(for character: Character) -> CGFloat {
        _lock.lock()
        defer { _lock.unlock() }

        if let cached = _advanceCache[character] {
            return cached
        }

        let attr = NSAttributedString(string: String(character), attributes: [.font: _font])
        let line = CTLineCreateWithAttributedString(attr)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        _advanceCache[character] = advance
        return advance
    }*/
    // CTLineGetTypographicBoundsでadvanceを計算すると、まとめてcacheしたCTLineCreateWithAttributedString由来のadvanceと誤差が出る。
    // 1文字ずつのものもCTLineCreateWithAttributedStringで計算することにして誤差は縮小したが、やはりずれる。
    func advance(for character: Character) -> CGFloat {
        _lock.lock()
        defer { _lock.unlock() }

        if let cached = _advanceCache[character] {
            return cached
        }

        let attr = NSAttributedString(string: String(character), attributes: [.font: _font])
        let line = CTLineCreateWithAttributedString(attr)

        // 1文字だけなので index = 1 で advance 相当の位置になる
        let advance = CTLineGetOffsetForStringIndex(line, 1, nil)

        _advanceCache[character] = advance
        return advance
    }
    
    func advances(for characters: [Character], in range: Range<Int>) -> [CGFloat] {
        guard range.lowerBound >= 0, range.upperBound <= characters.count else {
            log("range is out of bounds", from:self)
                return []
        }
        
        return characters[range].map { advance(for: $0) }
    }
    
    func width(for characters: [Character], in range: Range<Int>) -> CGFloat {
        guard !characters.isEmpty else { return 0 }

        var total: CGFloat = 0
        _lock.lock()
        defer { _lock.unlock() }

        for i in range {
            if i >= 0 && i < characters.count {
                total += advance(for: characters[i])
            }
        }

        return total
    }
    
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
    }

    
    private func preload() {
        register(characters: Self._defaultCharacters)
    }
}
