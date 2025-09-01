//
//  NSFont.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/06/20.
//

import AppKit

extension NSFont {
    var lineHeight: CGFloat {
        return ascender + abs(descender) + leading
    }
}


