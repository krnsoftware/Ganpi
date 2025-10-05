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
    
    var isInCompletionMode:Bool = false {
        didSet {
            if !isInCompletionMode {
                reset()
            }
            sendStatusBarUpdateAction()
        }
    }
    
    var nowCompleting:Bool {
        currentWordTail != nil
    }
    
    private func sendStatusBarUpdateAction() {
        NSApp.sendAction(#selector(KStatusBarUpdateAction.statusBarNeedsUpdate(_:)),
                                         to: nil, from: self)
    }
    
    private func reset() {
        _entries.removeAll()
        _entryIndex = 0
        _caretIndex = 0
        _currentPrefix = ""
        currentWordTail = nil
    }
    
    private func setCurrentWordTail() {
        if _entries.count == 0 { /*log("count == 0",from:self);*/ return }
        guard _entryIndex >= 0, _entryIndex < _entries.count else {
            log("_entryIndex: out of range. \(_entryIndex)",from:self)
            return
        }
        let word = _entries[_entryIndex].text

        
        let wordArray = Array(word)
        guard _currentPrefix.count < wordArray.count else {
            log("_currentPrefix.count is out of range.",from:self)
            return
        }
        currentWordTail = NSAttributedString(string: String(wordArray[_currentPrefix.count..<wordArray.count]))
        
    }
    
    
    init(textView: KTextView, characterLimit:Int = 3) {
        _textView = textView
        _characterLimit = characterLimit
    }
    
    // 選択範囲が変更された際に呼び出す。
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
        }
        
        
    }
    
    // 現在選択されている候補より上(前)の候補を選択する。
    // 呼び出し後にKTextView上でneedsDisplay=trueが必要。
    func selectPrevious() {
        if _entryIndex > 0 { _entryIndex -= 1 }
        setCurrentWordTail()
    }
    
    // 現在選択されている候補より下(後)の候補を選択する。
    // 呼び出し後にKTextView上でneedsDisplay=trueが必要。
    func selectNext() {
        if _entryIndex < _entries.count - 1 { _entryIndex += 1 }
        setCurrentWordTail()
    }
    
    // 選択されている候補を挿入した後reset()する。
    func fix() {
        guard let textView = _textView else { log("textView is nil.",from:self); return }
        guard let tail = currentWordTail else { log("tail is nil.",from:self); return }
        let caretIndex = textView.caretIndex
        let storage = textView.textStorage as! KTextStorage
        
        storage.replaceString(in: caretIndex..<caretIndex, with: tail.string)
        reset()
    }
    
    // KTextView.keyDown()で呼び出す。
    // キーイベントが内部で消費されればtrue, 放流する場合はfalse。
    func estimate(event:NSEvent) -> Bool {
        let code = event.keyCode
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let noflag = flags == []
        
        if !isInCompletionMode {
            // F5キーまたはopt+escの場合はcompletion開始
            if code == KC.f5 || (code == KC.escape && flags == [.option]) {
                isInCompletionMode = true
                return true
            }
            return false
        }
        
        // これ以降はisInCompletion == trueの場合。
        
        // escapeキーが押下された場合、currentWordTailがあればreset(), なければcompletionモードから抜ける。
        if code == KC.escape && noflag {
            if nowCompleting {
                reset()
            } else {
                isInCompletionMode = false
            }
            return true
        }
        
        // 改行キーが押された際、補完候補があれば中断する。なければ改行する。
        if code == KC.returnKey && noflag {
            if nowCompleting {
                fix()
                return true
            }
            return false
        }
        
        // tabキーが押されたら確定する。
        if code == KC.tab && noflag {
            fix()
            return true
        }
        
        // 上矢印で補完候補を上へ。
        if code == KC.arrowUp && noflag {
            selectPrevious()
            return true
        }
        
        // 下矢印で補完候補を下へ。
        if code == KC.arrowDown && noflag {
            selectNext()
            return true
        }
        
        return false
    }
    
}
