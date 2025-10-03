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

/// アウトライン用の小バッジ画像を生成（白字・角丸・色つき）
/// すべてのパーサから使い回し可能。描画結果は簡易キャッシュする。
final class KOutlineBadgeFactory {
    static let shared = KOutlineBadgeFactory()
    private init() {}

    // キャッシュキー（色は16進表記で正規化）
    private struct _Key: Hashable {
        let letter: String
        let hex: String
        let size: CGFloat
        let corner: CGFloat
        let weight: NSFont.Weight
    }
    private var _cache: [_Key: NSImage] = [:]

    /// バッジ画像を生成
    /// - Parameters:
    ///   - letter: 表示する1文字（"C" / "M" / "F" など）※先頭1文字のみ使用
    ///   - color: 背景色（sRGB 推奨）
    ///   - size: 一辺のポイントサイズ（14〜16が無難）
    ///   - cornerRadius: 角丸半径
    ///   - weight: 文字のウェイト（.semibold 推奨）
    func badge(letter: String,
               color: NSColor,
               size: CGFloat = 14,
               cornerRadius: CGFloat = 3,
               weight: NSFont.Weight = .semibold) -> NSImage
    {
        let ch = String(letter.prefix(1)).uppercased()
        let hex = color.toHexString() ?? color.description
        let key = _Key(letter: ch, hex: hex, size: size, corner: cornerRadius, weight: weight)
        if let cached = _cache[key] { return cached }

        let imgSize = NSSize(width: size, height: size)
        let img = NSImage(size: imgSize)
        img.isTemplate = false

        img.lockFocusFlipped(false)
        defer { img.unlockFocus() }

        // 背景（角丸）
        let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: imgSize),
                                  xRadius: cornerRadius, yRadius: cornerRadius)
        color.setFill()
        bgPath.fill()

        // 中央に白字1文字
        let font = NSFont.systemFont(ofSize: size * 0.68, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: ch, attributes: attrs)
        let s = str.size()
        let r = NSRect(x: (imgSize.width - s.width) * 0.5,
                       y: (imgSize.height - s.height) * 0.5,
                       width: s.width, height: s.height).integral
        str.draw(in: r)

        _cache[key] = img
        return img
    }

    /// 種別に応じた既定色のバッジを返す（色は必要に応じて後で差し替え可）
    func badge(for kind: OutlineItem.Kind, size: CGFloat = 14) -> NSImage {
        switch kind {
        case .class:
            return badge(letter: "C", color: NSColor.systemBlue, size: size)
        case .module:
            return badge(letter: "M", color: NSColor.systemPurple, size: size)
        case .method:
            return badge(letter: "F", color: NSColor.systemGreen, size: size) // Function
        }
    }
}
