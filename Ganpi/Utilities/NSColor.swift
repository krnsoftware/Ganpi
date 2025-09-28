//
//  NSColor.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/28,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Cocoa

extension NSColor {
    // #RRGGBB または #RRGGBBAA を解釈して NSColor を生成
    // - Returns: NSColor (sRGB)、不正な場合は nil
    convenience init?(hexString: String) {
        // #必須
        guard hexString.hasPrefix("#") else { return nil }
        
        let hexPart = String(hexString.dropFirst())
        let length = hexPart.count
        
        guard length == 6 || length == 8 else { return nil }
        
        var hexValue: UInt64 = 0
        guard Scanner(string: hexPart).scanHexInt64(&hexValue) else { return nil }
        
        if length == 6 {
            let r = CGFloat((hexValue & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((hexValue & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(hexValue & 0x0000FF) / 255.0
            self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
        } else { // 8桁
            let r = CGFloat((hexValue & 0xFF000000) >> 24) / 255.0
            let g = CGFloat((hexValue & 0x00FF0000) >> 16) / 255.0
            let b = CGFloat((hexValue & 0x0000FF00) >> 8) / 255.0
            let a = CGFloat(hexValue & 0x000000FF) / 255.0
            self.init(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }
    
    // NSColor を #RRGGBB または #RRGGBBAA 形式の16進数文字列として返す
    func toHexString(includeAlpha: Bool = false) -> String? {
        guard let rgbColor = usingColorSpace(.sRGB) else {
            return nil // sRGBへの変換失敗
        }
        
        func to255(_ component: CGFloat) -> Int {
            return Int(round(min(max(component, 0), 1) * 255))
        }
        
        let r = to255(rgbColor.redComponent)
        let g = to255(rgbColor.greenComponent)
        let b = to255(rgbColor.blueComponent)
        
        var hexString = String(format: "#%02X%02X%02X", r, g, b)
        
        if includeAlpha {
            let a = to255(rgbColor.alphaComponent)
            hexString += String(format: "%02X", a)
        }
        
        return hexString
    }
}
