//
//  KKeyCode.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/05,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Carbon.HIToolbox

typealias KC = KKeyCode

struct KKeyCode {

    // MARK: - 数字キー
    static let n0: UInt16 = UInt16(kVK_ANSI_0)
    static let n1: UInt16 = UInt16(kVK_ANSI_1)
    static let n2: UInt16 = UInt16(kVK_ANSI_2)
    static let n3: UInt16 = UInt16(kVK_ANSI_3)
    static let n4: UInt16 = UInt16(kVK_ANSI_4)
    static let n5: UInt16 = UInt16(kVK_ANSI_5)
    static let n6: UInt16 = UInt16(kVK_ANSI_6)
    static let n7: UInt16 = UInt16(kVK_ANSI_7)
    static let n8: UInt16 = UInt16(kVK_ANSI_8)
    static let n9: UInt16 = UInt16(kVK_ANSI_9)

    // MARK: - アルファベットキー
    static let a: UInt16 = UInt16(kVK_ANSI_A)
    static let b: UInt16 = UInt16(kVK_ANSI_B)
    static let c: UInt16 = UInt16(kVK_ANSI_C)
    static let d: UInt16 = UInt16(kVK_ANSI_D)
    static let e: UInt16 = UInt16(kVK_ANSI_E)
    static let f: UInt16 = UInt16(kVK_ANSI_F)
    static let g: UInt16 = UInt16(kVK_ANSI_G)
    static let h: UInt16 = UInt16(kVK_ANSI_H)
    static let i: UInt16 = UInt16(kVK_ANSI_I)
    static let j: UInt16 = UInt16(kVK_ANSI_J)
    static let k: UInt16 = UInt16(kVK_ANSI_K)
    static let l: UInt16 = UInt16(kVK_ANSI_L)
    static let m: UInt16 = UInt16(kVK_ANSI_M)
    static let n: UInt16 = UInt16(kVK_ANSI_N)
    static let o: UInt16 = UInt16(kVK_ANSI_O)
    static let p: UInt16 = UInt16(kVK_ANSI_P)
    static let q: UInt16 = UInt16(kVK_ANSI_Q)
    static let r: UInt16 = UInt16(kVK_ANSI_R)
    static let s: UInt16 = UInt16(kVK_ANSI_S)
    static let t: UInt16 = UInt16(kVK_ANSI_T)
    static let u: UInt16 = UInt16(kVK_ANSI_U)
    static let v: UInt16 = UInt16(kVK_ANSI_V)
    static let w: UInt16 = UInt16(kVK_ANSI_W)
    static let x: UInt16 = UInt16(kVK_ANSI_X)
    static let y: UInt16 = UInt16(kVK_ANSI_Y)
    static let z: UInt16 = UInt16(kVK_ANSI_Z)

    // MARK: - 記号キー
    static let minus: UInt16 = UInt16(kVK_ANSI_Minus)
    static let equal: UInt16 = UInt16(kVK_ANSI_Equal)
    static let leftBracket: UInt16 = UInt16(kVK_ANSI_LeftBracket)
    static let rightBracket: UInt16 = UInt16(kVK_ANSI_RightBracket)
    static let semicolon: UInt16 = UInt16(kVK_ANSI_Semicolon)
    static let quote: UInt16 = UInt16(kVK_ANSI_Quote)
    static let comma: UInt16 = UInt16(kVK_ANSI_Comma)
    static let period: UInt16 = UInt16(kVK_ANSI_Period)
    static let slash: UInt16 = UInt16(kVK_ANSI_Slash)
    static let backslash: UInt16 = UInt16(kVK_ANSI_Backslash)
    static let grave: UInt16 = UInt16(kVK_ANSI_Grave)

    // MARK: - スペシャルキー
    static let tab: UInt16           = UInt16(kVK_Tab)
    static let space: UInt16         = UInt16(kVK_Space)
    static let returnKey: UInt16     = UInt16(kVK_Return)
    static let enterKey: UInt16      = UInt16(kVK_ANSI_KeypadEnter)
    static let delete: UInt16        = UInt16(kVK_Delete)         // Backspace
    static let forwardDelete: UInt16 = UInt16(kVK_ForwardDelete)
    static let escape: UInt16        = UInt16(kVK_Escape)
    static let capsLock: UInt16      = UInt16(kVK_CapsLock)
    static let function: UInt16      = UInt16(kVK_Function)

    // MARK: - 修飾キー
    static let commandLeft: UInt16  = UInt16(kVK_Command)
    static let commandRight: UInt16 = UInt16(kVK_RightCommand)
    static let shiftLeft: UInt16    = UInt16(kVK_Shift)
    static let shiftRight: UInt16   = UInt16(kVK_RightShift)
    static let optionLeft: UInt16   = UInt16(kVK_Option)
    static let optionRight: UInt16  = UInt16(kVK_RightOption)
    static let controlLeft: UInt16  = UInt16(kVK_Control)
    static let controlRight: UInt16 = UInt16(kVK_RightControl)

    // MARK: - 矢印キー
    static let arrowUp: UInt16    = UInt16(kVK_UpArrow)
    static let arrowDown: UInt16  = UInt16(kVK_DownArrow)
    static let arrowLeft: UInt16  = UInt16(kVK_LeftArrow)
    static let arrowRight: UInt16 = UInt16(kVK_RightArrow)

    // MARK: - ファンクションキー
    static let f1:  UInt16 = UInt16(kVK_F1)
    static let f2:  UInt16 = UInt16(kVK_F2)
    static let f3:  UInt16 = UInt16(kVK_F3)
    static let f4:  UInt16 = UInt16(kVK_F4)
    static let f5:  UInt16 = UInt16(kVK_F5)
    static let f6:  UInt16 = UInt16(kVK_F6)
    static let f7:  UInt16 = UInt16(kVK_F7)
    static let f8:  UInt16 = UInt16(kVK_F8)
    static let f9:  UInt16 = UInt16(kVK_F9)
    static let f10: UInt16 = UInt16(kVK_F10)
    static let f11: UInt16 = UInt16(kVK_F11)
    static let f12: UInt16 = UInt16(kVK_F12)
    static let f13: UInt16 = UInt16(kVK_F13)
    static let f14: UInt16 = UInt16(kVK_F14)
    static let f15: UInt16 = UInt16(kVK_F15)
    static let f16: UInt16 = UInt16(kVK_F16)
    static let f17: UInt16 = UInt16(kVK_F17)
    static let f18: UInt16 = UInt16(kVK_F18)
    static let f19: UInt16 = UInt16(kVK_F19)
    static let f20: UInt16 = UInt16(kVK_F20)
}

