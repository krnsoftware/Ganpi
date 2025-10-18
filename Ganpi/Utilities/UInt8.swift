//
//  UInt8.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/18,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import Foundation

extension UInt8 {
    var isAsciiDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isAsciiUpper: Bool { self >= 0x41 && self <= 0x5A }
    var isAsciiLower: Bool { self >= 0x61 && self <= 0x7A }
    var isAsciiAlpha: Bool { isAsciiUpper || isAsciiLower }
    
    var isIdentStartAZ_: Bool { self.isAsciiAlpha || self == FuncChar.underscore }
    var isIdentPartAZ09_: Bool { self.isIdentStartAZ_ || self.isAsciiDigit }
    
}
