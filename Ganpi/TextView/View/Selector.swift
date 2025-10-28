//
//  Selector.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/29,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Foundation

extension Selector {
    var isVerticalAction: Bool {
        return self == #selector(KTextView.moveUp(_:)) ||
        self == #selector(KTextView.moveDown(_:)) ||
        self == #selector(KTextView.moveUpAndModifySelection(_:)) ||
        self == #selector(KTextView.moveDownAndModifySelection(_:))
    }
    
    var isVerticalActionWithModifierSelection: Bool {
        return self == #selector(KTextView.moveUpAndModifySelection(_:)) ||
        self == #selector(KTextView.moveDownAndModifySelection(_:))
    }
    
    var isHorizontalActionWithModifierSelection: Bool {
        return self == #selector(KTextView.moveLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveRightAndModifySelection(_:))
    }
    
    var isYankFamilyAction: Bool {
        return self == #selector(KTextView.yank(_:)) ||
        self == #selector(KTextView.yankPop(_:)) ||
        self == #selector(KTextView.yankPopReverse(_:)) ||
        self == #selector(KTextView.paste(_:))
    }
    
    // 上記のselectorに含まれているか否かを返す。
    var isTargetSelector: Bool {
        return self.isVerticalAction || self.isHorizontalActionWithModifierSelection || self.isYankFamilyAction
    }
}
