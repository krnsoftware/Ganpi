//
//  Document.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import Cocoa

class Document: NSDocument {
    
    private var _characterCode: String.Encoding = .utf32
    private var _returnCode: String.ReturnCharacter = .lf
    private var _syntaxType: KSyntaxType = .plain
    
    private var _textStorage: KTextStorage = .init()
    
    var characterCode: String.Encoding {
        get { _characterCode }
        set { _characterCode = newValue; notifyStatusBarNeedsUpdate()  }
    }
    
    var returnCode: String.ReturnCharacter {
        get { _returnCode }
        set { _returnCode = newValue; notifyStatusBarNeedsUpdate()  }
    }
    
    var syntaxType: KSyntaxType {
        get { _syntaxType }
        set { _syntaxType = newValue; notifyStatusBarNeedsUpdate()  }
    }
    
    var textStorage: KTextStorage {
        _textStorage
    }
    
    
    override init() {
        super.init()
        
        textStorage.replaceParser(for: _syntaxType)
        
    }

    override class var autosavesInPlace: Bool {
        return true
    }

    override var windowNibName: NSNib.Name? {
        // Returns the nib file name of the document
        // If you need to use a subclass of NSWindowController or if your document supports multiple NSWindowControllers, you should remove this property and override -makeWindowControllers instead.
        return NSNib.Name("Document")
    }
    
    
    override func makeWindowControllers() {
        let windowController = NSWindowController(windowNibName: "Document")
        addWindowController(windowController)

        _ = windowController.window                                // NIB をここでロード
        windowController.contentViewController = KViewController() // 中身はここで決定

        // ① フレームの自動保存名（次回からはこのサイズで開く）
        windowController.windowFrameAutosaveName = "KEditDocumentWindow"

        // ② 初回だけのデフォルトサイズ（自動保存がまだ無い場合）
        if UserDefaults.standard.string(forKey: "NSWindow Frame KEditDocumentWindow") == nil {
            windowController.window?.setContentSize(NSSize(width: 720, height: 520))
            windowController.window?.center()
        }

        // ③ これ以下に縮まない下限（“豆粒ウインドウ”防止）
        windowController.window?.contentMinSize = NSSize(width: 480, height: 320)

        windowController.window?.isRestorable = false             // 復元は引き続き無効
        
        if let viewController = windowController.contentViewController as? KViewController {
            viewController.document = self
        }
    }
    
    
    
/*
    override func data(ofType typeName: String) throws -> Data {
        let string = _textStorage.string
        
        let converted: String
        switch returnCode {
        case .lf:
            converted = string
        case .crlf:
            converted = string.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr:
            converted = string.replacingOccurrences(of: "\n", with: "\r")
        }
        
        if let data = converted.data(using: characterCode) {
            return data
        }
        
        let err = NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteInapplicableStringEncodingError,
                userInfo: [
                    NSLocalizedDescriptionKey: "選択された文字コードでは保存できません。",
                    NSLocalizedRecoverySuggestionErrorKey: "別の文字コードを選んで再度保存してください。"
                ]
            )
        throw err
        
        
    }
*/
    
    override func write(to url:URL, ofType typeName: String) throws {
        let string = textStorage.string
        
        let convertedString: String
        switch returnCode {
        case .lf:
            convertedString = string
        case .cr:
            convertedString = string.replacingOccurrences(of: "\n", with: "\r")
        case .crlf:
            convertedString = string.replacingOccurrences(of: "\n", with: "\r\n")
        }
        
        if let data = convertedString.data(using: characterCode, allowLossyConversion: false) {
            try data.write(to:url, options: .atomic)
            return
        }
        
        if let first = convertedString.unicodeScalars.first {
            log("First char U+\(String(format: "%04X", first.value))",from:self)
        }
        
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The selected encoding cannot represent some characters in this document."
        alert.informativeText = "If you choose to save with substitution, characters that cannot be converted will be replaced with alternative symbols."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save with Substitution")
        
        let res = alert.runModal()
        if res == .alertSecondButtonReturn {
            guard let lossyData = convertedString.data(using: characterCode, allowLossyConversion: true) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError, userInfo: [NSLocalizedDescriptionKey: "Failed to save with substitution."])
            }
            try lossyData.write(to:url, options: .atomic)
            return
        } else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        }
        
    }
    
    
    override func read(from data: Data, ofType typeName: String) throws {
        
        // 文字コードの推定 → 文字列化
        let encoding = String.estimateCharacterCode(from: data) ?? .utf8
        guard var decodedString = String(bytes: data, encoding: encoding) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadUnknownStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding"])
        }
        
        // 先頭にBOM(FEFF)がある場合は先頭一文字を落とす。
        if decodedString.unicodeScalars.first == "\u{FEFF}" {
            decodedString.removeFirst()
            //log("BOM!",from:self)
        }
        
        // 改行の正規化（内部は常に LF）、最初に見つかった外部改行を記録
        let normalizedInfo = decodedString.normalizeNewlinesAndDetect()
        characterCode = encoding
        returnCode = normalizedInfo.detected ?? .lf   // 改行が無い場合は LF を既定
        
        let normalizedString = normalizedInfo.normalized
        // 本文を TextStorage へ投入（全文置換）
        textStorage.replaceString(in: 0..<_textStorage.count, with: normalizedString)
        
        
        // シンタックスタイプを推定
        let fileExt = fileURL?.pathExtension
        syntaxType = KSyntaxType.detect(fromTypeName: typeName, orExtension: fileExt)
        textStorage.replaceParser(for: syntaxType)

        // 読み込み完了（未変更状態へ）
        updateChangeCount(.changeCleared)

    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(save(_:)) {
                return isDocumentEdited // 編集されている時だけ有効
            }
            return super.validateUserInterfaceItem(item)
        }

}

extension Document {
    /// 自分のウインドウ群だけ確実に更新（レスポンダチェーンに頼らない）
    func notifyStatusBarNeedsUpdate() {
        for wc in windowControllers {
            (wc.contentViewController as? KViewController)?.updateStatusBar()
        }
    }
}


@objc protocol KTextStorageAction {
    @objc func textStorageDidEdit(_ sender: Any?)
}

extension Document: KTextStorageAction {
    @IBAction func textStorageDidEdit(_ sender: Any?) {
        updateChangeCount(.changeDone)
    }
}

