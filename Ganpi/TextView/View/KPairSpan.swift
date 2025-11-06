//
//  KPairSpan.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/11/06,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//
//
//
//  KPairSpan.swift
//  Ganpi
//
//  行スライス（※絶対インデックス前提）から、括弧／クオートのスパン木を
//  単一走査・非再帰で構築する。範囲は常に外側レンジ [open, close) を保持。
//  - クオート内の括弧は無視
//  - 子→兄弟→叔父…の探索を補助するユーティリティを提供
//

import Foundation

struct KPairSpan {
    /// 文書全体に対する絶対範囲（右端は非包含）
    let range: Range<Int>
    /// 直下の子スパン（外側レンジで保持）
    var spans: [KPairSpan] = []

    // MARK: 構築（非再帰・単一走査・絶対座標）

    /// 行スライス（※ absolute index の ArraySlice<UInt8> 前提）から構築
    static func build(from slice: ArraySlice<UInt8>) -> KPairSpan {
        let pairs: [UInt8: UInt8] = [
            FC.leftParen:   FC.rightParen,
            FC.leftBracket: FC.rightBracket,
            FC.leftBrace:   FC.rightBrace,
            FC.lt:          FC.gt
        ]
        let quotes: Set<UInt8> = [FC.doubleQuote, FC.singleQuote, FC.backtick]

        struct Builder {
            let open: Int          // 絶対開始位置
            let char: UInt8        // 開いた文字（root は 0）
            var children: [KPairSpan] = []
        }

        var i = slice.startIndex
        let end = slice.endIndex

        // ルート（行全体、absolute）
        var stack: [Builder] = [Builder(open: slice.startIndex, char: 0, children: [])]

        // クオート状態（absolute）
        var inQuote: UInt8? = nil
        var inQuoteStartAbs: Int = 0

        while i < end {
            let c = slice[i]

            // --- クオート処理 ---
            if quotes.contains(c) {
                let escaped = (i > slice.startIndex && slice[i - 1] == FC.backSlash)
                if !escaped {
                    if let q = inQuote, q == c {
                        // クオート閉じ → 外側レンジでノード化（absolute）
                        let node = KPairSpan(range: inQuoteStartAbs..<(i + 1), spans: [])
                        stack[stack.count - 1].children.append(node)
                        inQuote = nil
                    } else if inQuote == nil {
                        inQuote = c
                        inQuoteStartAbs = i
                    }
                }
                i += 1
                continue
            }

            // クオート内はスキップ
            if inQuote != nil {
                i += 1
                continue
            }

            // --- 開き括弧 ---
            if let _ = pairs[c] {
                stack.append(Builder(open: i, char: c, children: []))
                i += 1
                continue
            }

            // --- 閉じ括弧 ---
            if let last = stack.last,
               last.char != 0,
               let expected = pairs[last.char],
               expected == c
            {
                let done = stack.removeLast()
                let node = KPairSpan(range: done.open..<(i + 1), spans: done.children)
                stack[stack.count - 1].children.append(node)
                i += 1
                continue
            }

            i += 1
        }

        // 未閉じは捨てる（root の children のみ採用）
        return KPairSpan(
            range: slice.startIndex..<slice.endIndex,
            spans: stack[0].children.sorted { $0.range.lowerBound < $1.range.lowerBound }
        )
    }

    // MARK: 探索ユーティリティ

    /// 指定 index を含む最小（最内）スパンを検索（探索時は upperBound も含める）
    func span(containing index: Int) -> KPairSpan? {
        for s in spans {
            if s.range.contains(index) || index == s.range.upperBound {
                return s.span(containing: index) ?? s
            }
        }
        return nil
    }

    /// 直下の子を開始位置昇順で返す
    func directChildren() -> [KPairSpan] {
        spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 行内の全スパンを「左→右の深さ優先順」でフラット化（root 自身は含めない）
    func flattenPreorder() -> [KPairSpan] {
        var out: [KPairSpan] = []
        func walk(_ n: KPairSpan) {
            out.append(n)
            for c in n.spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                walk(c)
            }
        }
        for c in directChildren() { walk(c) }
        return out
    }

    /// 右方向：index 以降で「最初に始まる」スパン（absolute）
    func nextSpan(startingAtOrAfter index: Int) -> KPairSpan? {
        flattenPreorder()
            .filter { $0.range.lowerBound >= index }
            .min { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 左方向：index 以前で「最後に終わる」スパン（absolute）
    func prevSpan(endingAtOrBefore index: Int) -> KPairSpan? {
        flattenPreorder()
            .filter { $0.range.upperBound <= index }
            .max { $0.range.upperBound < $1.range.upperBound }
    }

    /// needle（子孫）を直接ぶら下げている親と、その子インデックスを探す
    func findParent(of needle: KPairSpan) -> (parent: KPairSpan, index: Int)? {
        func walk(_ node: KPairSpan) -> (KPairSpan, Int)? {
            for (i, c) in node.spans.enumerated() {
                if c.range == needle.range { return (node, i) }
                if let hit = walk(c) { return hit }
            }
            return nil
        }
        return walk(self)
    }
}
