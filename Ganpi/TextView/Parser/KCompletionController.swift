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
    private var _entries: [String] = []
    private var _entryIndex: Int = 0
    private var _caretIndex: Int = 0
    private var _currentPrefix: String = ""
    private weak var _textView: KTextView?

    var currentWordTail: NSAttributedString?

    var isInCompletionMode: Bool = false {
        didSet {
            if !isInCompletionMode {
                reset()
            }
            sendStatusBarUpdateAction()
        }
    }

    var nowCompleting: Bool { currentWordTail != nil }

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
        if _entries.isEmpty { return }
        guard _entryIndex >= 0, _entryIndex < _entries.count else {
            log("_entryIndex: out of range. \(_entryIndex)", from: self)
            return
        }

        let word = _entries[_entryIndex]
        let wordArray = Array(word)

        guard _currentPrefix.count < wordArray.count else {
            currentWordTail = nil
            return
        }

        let tail = String(wordArray[_currentPrefix.count..<wordArray.count])
        currentWordTail = NSAttributedString(string: tail)
    }

    init(textView: KTextView) {
        _textView = textView
    }

    // 選択範囲が変更された際に呼び出す（KTextView.selectionRange setter）。
    func update() {
        guard isInCompletionMode else { return }

        reset()
        guard let textView = _textView else { log("textView is nil.", from: self); return }

        _caretIndex = textView.caretIndex
        let storage = textView.textStorage
        let parser = storage.parser

        // キャレットの位置が単語の最後である場合のみ動作する。
        if let range = parser.wordRange(at: _caretIndex), range.upperBound == _caretIndex {
            let prefix = storage.string(in: range)

            guard prefix.count >= parser.completionMinPrefixLength else { return }

            _entries = parser.completionEntries(prefix: prefix)
            guard !_entries.isEmpty else { return }

            _currentPrefix = prefix
            _entryIndex = 0
            setCurrentWordTail()
        }
    }

    // 現在選択されている候補より上(前)の候補を選択する（端で停止）。
    func selectPrevious() {
        if _entryIndex > 0 { _entryIndex -= 1 }
        setCurrentWordTail()
    }

    // 現在選択されている候補より下(後)の候補を選択する（端で停止）。
    func selectNext() {
        if _entryIndex < _entries.count - 1 { _entryIndex += 1 }
        setCurrentWordTail()
    }

    // 選択されている候補を挿入した後 reset() する。
    func fix() {
        guard let textView = _textView else { log("textView is nil.", from: self); return }
        guard let tail = currentWordTail else { log("tail is nil.", from: self); return }

        let caretIndex = textView.caretIndex
        let storage = textView.textStorage
        storage.replaceString(in: caretIndex..<caretIndex, with: tail.string)
        reset()
    }

    // KTextView.keyDown()で呼び出す。
    // キーイベントが内部で消費されれば true, 放流する場合は false。
    func estimate(event: NSEvent) -> Bool {
        let code = event.keyCode
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let noflag = flags == []

        if !isInCompletionMode {
            // F5キーまたはopt+escの場合はcompletion開始（開始直後に update する）
            if code == KC.f5 || (code == KC.escape && flags == [.option]) {
                isInCompletionMode = true
                update()
                return true
            }
            return false
        }

        // これ以降は isInCompletionMode == true の場合。

        // escapeキー：候補があればreset、なければモード終了
        if code == KC.escape && noflag {
            if nowCompleting {
                reset()
            } else {
                isInCompletionMode = false
            }
            return true
        }

        // return：候補があれば「補完を無視して改行」する（候補だけ消してイベントは放流）
        if code == KC.returnKey && noflag {
            if nowCompleting {
                reset()
                return false
            }
            return false
        }

        // tab：候補がある時だけ確定（無ければ通常のtab動作へ）
        if code == KC.tab && noflag {
            if nowCompleting {
                fix()
                return true
            }
            return false
        }

        // 上下キーで候補移動（端で停止）
        if code == KC.arrowUp && noflag {
            if nowCompleting {
                selectPrevious()
                return true
            }
            return false
        }

        if code == KC.arrowDown && noflag {
            if nowCompleting {
                selectNext()
                return true
            }
            return false
        }

        return false
    }
}
