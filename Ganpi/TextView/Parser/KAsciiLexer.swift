//
//  KAsciiLexer.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/12/07,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import Foundation

struct KAsciiLexer {

    private init() {}

    // MARK: - Escape 判定

    @inline(__always)
    static func isEscaped(_ base: UnsafePointer<UInt8>, at i: Int) -> Bool {
        var esc = 0
        var k = i - 1
        while k >= 0, base[k] == FC.backSlash {
            esc += 1
            k -= 1
        }
        return (esc % 2) == 1
    }

    // MARK: - クォート走査（scanQuotedNoInterpolation）

    static func scanQuotedNoInterpolation(
        _ base: UnsafePointer<UInt8>,
        _ n: Int,
        from: Int,
        quote: UInt8
    ) -> (closed: Bool, end: Int) {

        var i = from + 1
        while i < n {
            if base[i] == quote {
                if !isEscaped(base, at: i) {
                    return (true, i + 1)
                }
            }
            i += 1
        }
        return (false, n)
    }

    // MARK: - 一文字閉じデリミタまで読み飛ばす

    static func scanUntil(
        _ base: UnsafePointer<UInt8>,
        _ n: Int,
        from: Int,
        closing: UInt8
    ) -> (closed: Bool, end: Int) {

        var i = from
        while i < n {
            if base[i] == closing, !isEscaped(base, at: i) {
                return (true, i + 1)
            }
            i += 1
        }
        return (false, n)
    }

    // MARK: - Paired delimiter（括弧など）

    static func pairedClosing(of opener: UInt8) -> UInt8 {
        FC.paired(of: opener) ?? opener
    }

    // MARK: - /regex/ の走査

    static func scanRegexSlash(
        _ base: UnsafePointer<UInt8>,
        _ n: Int,
        from: Int
    ) -> (closed: Bool, end: Int) {

        var i = from + 1
        var inClass = 0

        while i < n {
            let c = base[i]

            // 文字クラス [
            if c == FC.leftBracket {
                if !isEscaped(base, at: i) { inClass += 1 }
                i += 1; continue
            }

            // 文字クラス ]
            if c == FC.rightBracket, inClass > 0 {
                if !isEscaped(base, at: i) { inClass -= 1 }
                i += 1; continue
            }

            // 終端 /
            if c == FC.slash, inClass == 0 {
                if !isEscaped(base, at: i) {
                    var j = i + 1
                    // フラグ文字 a-z を読み飛ばす
                    while j < n, base[j].isAsciiAlpha { j += 1 }
                    return (true, j)
                }
            }

            i += 1
        }

        return (false, n)
    }
}
