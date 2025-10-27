//
//  KCaretLayer.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/26,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import AppKit

/// 単一レイヤでキャレット矩形群を描画する最小実装
/// 規約: `caretRectsPrimaryFirst[0]` が primary（代表）、以降は secondary。
/// 座標系: 変換は行わない。必要に応じて呼び出し側で `isGeometryFlipped` を設定すること。
final class KCaretLayer: CALayer {

    // MARK: - Public

    /// 先頭が primary のキャレット矩形群（レイヤ座標）
    /// 更新時に自動で再描画要求を出す。
    var caretRectsPrimaryFirst: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    /// primary の色
    //var primaryColor: CGColor = NSColor.keyboardFocusIndicatorColor.cgColor
    var primaryColor: CGColor = NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.7).cgColor

    /// secondary の色
    var secondaryColor: CGColor = NSColor.systemGreen.cgColor

    /// Iタイプ用の線幅（参考値。矩形側に幅を反映済みなら未使用）
    var caretWidth: CGFloat = 2.0
    
    

    // MARK: - Init

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        // `contentsScale` は呼び出し側（window確定後）で上書き推奨
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
    }

    /// Core Animation が複製時に呼ぶコンストラクタ。
    /// カスタムプロパティを安全に引き継ぐ。
    override init(layer: Any) {
        super.init(layer: layer)
        if let src = layer as? KCaretLayer {
            caretRectsPrimaryFirst = src.caretRectsPrimaryFirst
            primaryColor = src.primaryColor
            secondaryColor = src.secondaryColor
            caretWidth = src.caretWidth
        }
        isOpaque = false
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? contentsScale
        actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
    }

    // MARK: - Drawing

    /// 受け取った矩形を塗るだけ。座標変換は行わない。
    override func draw(in ctx: CGContext) {
        guard !caretRectsPrimaryFirst.isEmpty else { return }

        // アンチエイリアスを切って芯を立てる
        ctx.setShouldAntialias(false)

        if var first = caretRectsPrimaryFirst.first {
            first = pixelSnap(first)
            ctx.setFillColor(primaryColor)
            ctx.fill(first)
        }
        if caretRectsPrimaryFirst.count > 1 {
            ctx.setFillColor(secondaryColor)
            for var r in caretRectsPrimaryFirst.dropFirst() {
                r = pixelSnap(r)
                ctx.fill(r)
            }
        }
    }
    
    // MARK: - Blink

    // 1) ハードな点滅（フェードではなく離散）
    func startBlinking(duration: CFTimeInterval = 1.0) {
        removeAnimation(forKey: "blink")
        let kf = CAKeyframeAnimation(keyPath: "opacity")
        kf.values = [1.0, 1.0, 0.0, 0.0]            // ON→ON→OFF→OFF
        kf.keyTimes = [0.0, 0.5, 0.5, 1.0]          // 50%点灯/50%消灯
        kf.calculationMode = .discrete              // ★補間しない
        kf.duration = duration
        kf.repeatCount = .infinity
        add(kf, forKey: "blink")
    }

    // 2) 物理ピクセルにスナップ（バーのx/width用）
    private func pixelSnap(_ r: CGRect) -> CGRect {
        let s = contentsScale > 0 ? contentsScale : (NSScreen.main?.backingScaleFactor ?? 2.0)
        // xを0.5px境界に、幅は最低1px
        let snappedX = floor(r.origin.x * s) / s + (1.0 / (2.0 * s))
        let minW = max(r.size.width, 1.0 / s)
        return CGRect(x: snappedX, y: r.origin.y, width: minW, height: r.size.height)
    }

    /// ブリンク停止（不透明度を戻す）
    func stopBlinking() {
        removeAnimation(forKey: "blink")
        opacity = 1.0
    }
}

