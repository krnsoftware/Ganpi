//
//  KCompletionController.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/05,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//


import AppKit


final class KCompletionController {
    private let _characterLimit: Int
    private var _entries:[KCompletionEntry] = []
    private var _entryIndex:Int = 0
    private var _caretIndex:Int = 0
    private var _currentPrefix:String = ""
    private weak var _textView: KTextView?
    
    var currentWordTail: NSAttributedString?
    
    var isInCompletion:Bool = false {
        didSet {
            if !isInCompletion {
                reset()
            }
        }
    }
    
    private func reset() {
        _entries.removeAll()
        _entryIndex = 0
        _caretIndex = 0
        _currentPrefix = ""
        currentWordTail = nil
    }
    
    private func setCurrentWordTail() {
        if _entries.count == 0 { log("count == 0",from:self); return }
        guard _entryIndex >= 0, _entryIndex < _entries.count else {log("_entryIndex: out of range. \(_entryIndex)",from:self); return }
        let word = _entries[_entryIndex].text

        // risky.
        let wordArray = Array(word)
        //log("array:\(String(wordArray[_currentPrefix.count..<wordArray.count]))")
        currentWordTail = NSAttributedString(string: String(wordArray[_currentPrefix.count..<wordArray.count]))
        
    }
    
    
    init(textView: KTextView, characterLimit:Int = 3) {
        _textView = textView
        _characterLimit = characterLimit
    }
    
    func update() {
        reset()
        guard let textView = _textView else { log("textView is nil.",from:self); return }
        _caretIndex = textView.caretIndex
        let storage = textView.textStorage
        let parser = storage.parser
        
        // キャレットの位置が単語の最後である場合のみ動作する。
        if let range = parser.wordRange(at: _caretIndex), range.upperBound == _caretIndex {
            let prefix = storage[string: range]
            
            parser.rebuildCompletionsIfNeeded(dirtyRange:nil)
            _entries.append(contentsOf: parser.completionEntries(prefix: prefix, around: _caretIndex,
                                                                 limit: 100, policy: .alphabetical))
            _currentPrefix = prefix
            setCurrentWordTail()
            
            for (i, ent) in _entries.enumerated() {
                log("\(i)- ent:\(ent.text)",from:self)
            }
        }
        
        
    }
    
    func selectPrevious() {
        log("pre",from:self)
        if _entryIndex > 0 { _entryIndex -= 1 }
        log("post",from:self)
        setCurrentWordTail()
    }
    
    func selectNext() {
        log("pre",from:self)
        if _entryIndex < _entries.count - 1 { _entryIndex += 1 }
        log("post",from:self)
        setCurrentWordTail()
    }
    
    func fix() {
        guard let textView = _textView else { log("textView is nil.",from:self); return }
        guard let tail = currentWordTail else { log("tail is nil.",from:self); return }
        let caretIndex = textView.caretIndex
        let storage = textView.textStorage as! KTextStorage
        
        storage.replaceString(in: caretIndex..<caretIndex, with: tail.string)
        log("caretIndex:\(caretIndex), tail:\(tail.string)", from:self)
        reset()
    }
    
    // キーイベントが内部で消費されればtrue, 放流する場合はfalse。
    func estimate(event:NSEvent) -> Bool {
        if !isInCompletion { return false }
        
        let code = event.keyCode

        //log("code: \(code)",from:self)

        if code == KC.f5 {
            isInCompletion = true
            return true
        }
        
        if code == KC.escape {
            isInCompletion = false
            return true
        }
        
        if code == KC.tab || code == KC.returnKey {
            fix()
            return true
        }
        
        if code == KC.arrowUp {
            log("code: \(code)",from:self)
            selectPrevious()
            return true
        }
        
        if code == KC.arrowDown {
            log("code: \(code)",from:self)
            selectNext()
            return true
        }
        
        return false
    }
    
}
