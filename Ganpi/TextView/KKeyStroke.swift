//
//  KKeyStroke.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/20,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Cocoa

// 1つのキー入力を表す構造体。
// 1つの文字とキー修飾子から構成される。
// 修飾子は.option, .control, .shift の3種類に限定される。

struct KKeyStroke: Equatable, Hashable {
    private static let _allowedModifiers: NSEvent.ModifierFlags = [.option, .control, .shift]
    
    let character: String
    let modifiers: NSEvent.ModifierFlags
    
    init(_ character: String, modifiers: NSEvent.ModifierFlags = []) {
        self.character = character.uppercased()
        self.modifiers = modifiers.intersection(Self._allowedModifiers)
    }
    
    // short initializer.
    init(_ character: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.init(character, modifiers: modifiers)
    }
    
    init(event: NSEvent) {
        if let character = event.charactersIgnoringModifiers {
            self.init(character, event.modifierFlags)
            return
        }
        self.init("")
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(character)
        hasher.combine(modifiers.rawValue)
    }
}
