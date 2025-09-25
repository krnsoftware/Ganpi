//
//  KClipBoardBuffer.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/09/25,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit

class KClipBoardBuffer {
    static let shared: KClipBoardBuffer = .init()
    
    private var _buffer: KRingBuffer<String> = .init(capacity: 60)
    
    private var _cursor: Int = 0
    private var _fixDuringCycle = true
    private var _isInCycle = false
    private var _pasteboardSnap: String?
    
    // その時点でのpasteboardの中身を返す。
    private var _livePasteboard: String {
        let pasteboard = NSPasteboard.general
        guard let string = pasteboard.string(forType: .string) else { log("pastebord.string is nil.",from:self); return "" }
        return string.normalizedString
    }
    
    // yank中の初期バッファーを返す。_fixDuringCycle==trueでは開始時のバッファー、falseでは現在のバッファーを返す。
    private var _currentPasteboard: String {
        if _isInCycle, _fixDuringCycle {
            if let snap = _pasteboardSnap { return snap }
            let snap = _livePasteboard
            _pasteboardSnap = snap
            return snap
        }
        return _livePasteboard
    }
    
    var isInCycle: Bool { _isInCycle }
    
    var currentBuffer: String {
        if _cursor == 0 {
            return _currentPasteboard
        } else {
            guard let string = _buffer.element(at: _cursor - 1) else { log("string is nil.",from:self); return "" }
            return string
        }
    }
    
    func setFixDuringCycle(_ flag: Bool) {
        _fixDuringCycle = flag
        endCycle()
    }
    
    func beginCycle() {
        _isInCycle = true
        _cursor = 0
    }
    
    func endCycle() {
        _isInCycle = false
        
        _cursor = 0
        _pasteboardSnap = nil
    }
    
    
    func append() {
        let newString = currentBuffer
        if _buffer.element(at: 0) != newString {
            _buffer.append(newString)
        }
        endCycle()
    }
    
    func pop() {
        guard _isInCycle else { NSSound.beep(); return }
        _cursor = (_cursor + 1) % (_buffer.count + 1)
    }
    
    func popReverse() {
        guard _isInCycle else { NSSound.beep(); return }
        _cursor = (_cursor + _buffer.count) % (_buffer.count + 1)
    }
    
    func reset() {
        endCycle()
        _buffer.reset()
    }
    
    
}
