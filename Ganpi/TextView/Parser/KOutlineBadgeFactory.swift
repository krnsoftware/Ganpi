//
//  OutlineBadgeFactory.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/03,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



import AppKit

// MARK: - 共通：アウトライン・バッジ

/// バッジ描画のテーマ（背景はダークグレー、前景は白にアクセントを少し混ぜる）
struct KBadgeTheme {
    var size: CGFloat = 14
    var corner: CGFloat = 3
    var fontWeight: NSFont.Weight = .bold //= .semibold
    var background: NSColor = NSColor(calibratedWhite: 0.4, alpha: 1.0)//NSColor(calibratedWhite: 0.22, alpha: 1.0) // 落ち着いた濃いグレー
    var foregroundBase: NSColor = .white                                 // 白字ベース
    var tintRatio: CGFloat = 0.50                                         // 前景に混ぜるアクセントの割合（0=真っ白）
    var borderColor: NSColor? = nil
    var borderWidth: CGFloat = 0
}

/// アクセント色（必要十分だけを用意。必要なら設定で差し替え可能）
enum KBadgeAccent: CaseIterable {
    case blue, red, green, yellow, purple, gray
}

/// コア描画用の仕様（プリセットからこれを作って描く）
struct KBadgeSpec: Hashable {
    var letter: String          // 先頭1文字のみ使用（"C","F","S" 等）
    var size: CGFloat
    var corner: CGFloat
    var fontWeight: NSFont.Weight
    var backgroundHex: String   // キャッシュキー用に色は hex で
    var foregroundHex: String
    var borderHex: String?
    var borderWidth: CGFloat

    // ハッシュ/等価は自動合成で OK
}

/// 共通ファクトリ：
/// - コア描画（矩形・文字・フォント・サイズ・色指定）
/// - 用途別プリセット（クラス/モジュール/メソッド）
/// - 簡易キャッシュ
final class KOutlineBadgeFactory {
    static let shared = KOutlineBadgeFactory()
    private init() {}

    // 設定（テーマとアクセントマップ）
    private var _theme = KBadgeTheme()
    private var _accentMap: [KBadgeAccent: NSColor] = [
        .blue:   NSColor.systemBlue,
        .red:    NSColor.systemRed,
        .green:  NSColor.systemGreen,
        .yellow: NSColor.systemYellow,
        .purple: NSColor.systemPurple,
        .gray:   NSColor.systemGray
    ]

    private var _cache: [KBadgeSpec: NSImage] = [:]

    // MARK: 設定 API

    func setTheme(_ theme: KBadgeTheme) {
        _theme = theme
        _cache.removeAll()
    }

    func setAccent(_ accent: KBadgeAccent, color: NSColor) {
        _accentMap[accent] = color
        _cache.removeAll()
    }

    // MARK: プリセット（用途別）

    /// クラス用（C）
    func classBadge(accent: KBadgeAccent = .blue, size: CGFloat? = nil) -> NSImage {
        let spec = spec(letter: "C", accent: accent, size: size)
        return badge(with: spec)
    }

    /// モジュール用（M）
    func moduleBadge(accent: KBadgeAccent = .purple, size: CGFloat? = nil) -> NSImage {
        let spec = spec(letter: "M", accent: accent, size: size)
        return badge(with: spec)
    }

    /// メソッド用（F / S）※ isSingleton=true なら S
    func methodBadge(isSingleton: Bool, accent: KBadgeAccent? = nil, size: CGFloat? = nil) -> NSImage {
        let letter = isSingleton ? "S" : "F"
        // 既定はインスタンス=green, シングルトン=red（落ち着いた白字に軽く混色）
        let fallback: KBadgeAccent = isSingleton ? .red : .green
        let spec = spec(letter: letter, accent: accent ?? fallback, size: size)
        return badge(with: spec)
    }
    
    /// HTMLのヘッディング用（H）
    func headingBadge(accent: KBadgeAccent = .blue, size: CGFloat? = nil) -> NSImage {
        let spec = spec(letter: "H", accent: accent, size: size)
        return badge(with: spec)
    }

    // MARK: コア描画（spec -> NSImage）

    /// 指定仕様で画像を返す（キャッシュあり）
    func badge(with spec: KBadgeSpec) -> NSImage {
        if let img = _cache[spec] { return img }

        let imgSize = NSSize(width: spec.size, height: spec.size)
        let img = NSImage(size: imgSize)
        img.isTemplate = false

        img.lockFocusFlipped(false)
        // 背景
        let bg = NSColor(hexString: spec.backgroundHex) ?? _theme.background
        let fg = NSColor(hexString: spec.foregroundHex) ?? _theme.foregroundBase
        let border = spec.borderHex.flatMap { NSColor(hexString: $0) }

        let rect = NSRect(origin: .zero, size: imgSize)
        let path = NSBezierPath(roundedRect: rect, xRadius: spec.corner, yRadius: spec.corner)
        bg.setFill(); path.fill()
        if let b = border, spec.borderWidth > 0 {
            b.setStroke(); path.lineWidth = spec.borderWidth; path.stroke()
        }

        // 文字
        let font = NSFont.systemFont(ofSize: spec.size * 0.68, weight: spec.fontWeight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let glyph = String(spec.letter.prefix(1)).uppercased()
        let str = NSAttributedString(string: glyph, attributes: attrs)
        let s = str.size()
        let r = NSRect(x: (imgSize.width - s.width) * 0.5,
                       y: (imgSize.height - s.height) * 0.5,
                       width: s.width, height: s.height).integral
        str.draw(in: r)
        img.unlockFocus()

        _cache[spec] = img
        return img
    }

    // MARK: 内部ユーティリティ

    /// プリセットからコア spec を生成（前景は白ベースにアクセントを少し混ぜる）
    private func spec(letter: String, accent: KBadgeAccent, size: CGFloat?) -> KBadgeSpec {
        let actualSize = size ?? _theme.size
        let bgHex = _theme.background.toHexString() ?? "#333333"
        // 前景色：白にアクセントを _theme.tintRatio だけブレンド
        let tint = _accentMap[accent] ?? NSColor.systemBlue
        let fg = blend(_theme.foregroundBase, tint, ratio: _theme.tintRatio)
        let fgHex = fg.toHexString() ?? "#FFFFFF"
        let borderHex = _theme.borderColor?.toHexString()

        return KBadgeSpec(letter: letter,
                          size: actualSize,
                          corner: _theme.corner,
                          fontWeight: _theme.fontWeight,
                          backgroundHex: bgHex,
                          foregroundHex: fgHex,
                          borderHex: borderHex,
                          borderWidth: _theme.borderWidth)
    }

    /// sRGB 前提で単純線形ブレンド
    private func blend(_ a: NSColor, _ b: NSColor, ratio: CGFloat) -> NSColor {
        let r = max(0, min(1, ratio))
        guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else { return a }
        let rr = ca.redComponent   * (1 - r) + cb.redComponent   * r
        let gg = ca.greenComponent * (1 - r) + cb.greenComponent * r
        let bb = ca.blueComponent  * (1 - r) + cb.blueComponent  * r
        let aa = ca.alphaComponent * (1 - r) + cb.alphaComponent * r
        return NSColor(srgbRed: rr, green: gg, blue: bb, alpha: aa)
    }
}
