//
//  Document.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import Cocoa
import CryptoKit

class Document: NSDocument {
    private static var lastCascadeTopLeft: NSPoint?
    private let _defaultWindowSize = NSSize(width: 600, height: 600)
    private let _windowMinimumSize = NSSize(width: 480, height: 320)
    
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
        
        textStorage.replaceParser(for: syntaxType)
        
    }
    
    override class var autosavesInPlace: Bool {
        return false
    }
    
    override var windowNibName: NSNib.Name? {
        // Returns the nib file name of the document
        // If you need to use a subclass of NSWindowController or if your document supports multiple NSWindowControllers, you should remove this property and override -makeWindowControllers instead.
        return NSNib.Name("Document")
    }
    
    override func makeWindowControllers() {
        // ---- 1) NIBロード & Content VC ----
        let wc = NSWindowController(windowNibName: "Document")
        addWindowController(wc)
        _ = wc.window
        wc.contentViewController = KViewController()
        wc.window?.contentMinSize = _windowMinimumSize
        wc.window?.isRestorable = false
        
        // Document参照をVCに渡す
        if let vc = wc.contentViewController as? KViewController { vc.document = self }
        
        // ---- 2) ハッシュ化 autosave 名（ネスト関数）----
        func windowAutosaveKey(for url: URL) -> String {
            let data = Data(url.path.utf8)
            let digest = SHA256.hash(data: data)
            let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
            return "GanpiWindow:\(hex)"
        }
        func hasSavedFrame(for autosaveName: String) -> Bool {
            UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
        }
        
        guard let window = wc.window else { return }
        
        // ---- 3) 既存ファイル：保存済みフレームがあれば復元 ----
        if let url = fileURL {
            let name = windowAutosaveKey(for: url)
            if hasSavedFrame(for: name) {
                wc.windowFrameAutosaveName = name     // ここで自動復元
                return
            } else {
                // 初回オープン：左上からカスケード配置 → 以後この autosave 名で保存される
                window.setContentSize(_defaultWindowSize)
                let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
                var seedTopLeft = Document.lastCascadeTopLeft ?? NSPoint(x: screenFrame.minX, y: screenFrame.maxY)
                // 最初の1枚目が中央に寄らないよう、明示的にフレームを作ってからカスケード
                let baseOrigin = NSPoint(x: seedTopLeft.x,
                                         y: seedTopLeft.y - _defaultWindowSize.height)
                window.setFrame(NSRect(origin: baseOrigin, size: _defaultWindowSize), display: false)
                seedTopLeft = window.cascadeTopLeft(from: seedTopLeft)
                Document.lastCascadeTopLeft = seedTopLeft
                
                wc.windowFrameAutosaveName = name
                return
            }
        }
        
        // ---- 4) 新規書類：左上からカスケード ----
        window.setContentSize(_defaultWindowSize)
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        var topLeft = Document.lastCascadeTopLeft ?? NSPoint(x: screenFrame.minX + 20, y: screenFrame.maxY + 20)
        
        // 1枚目用に基準フレームを置いてからカスケードさせると、左上スタックが安定します
        let firstOrigin = NSPoint(x: topLeft.x,
                                  y: topLeft.y - _defaultWindowSize.height)
        window.setFrame(NSRect(origin: firstOrigin, size: _defaultWindowSize), display: false)
        
        topLeft = window.cascadeTopLeft(from: topLeft)
        Document.lastCascadeTopLeft = topLeft
    }
    
    /*
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
        
        // test
        /*
         for (i, scalar) in decodedString.unicodeScalars.enumerated() {
         if scalar.value < 0x20 || scalar.value == 0xFEFF {
         log("index \(i): U+\(String(format: "%04X", scalar.value))",from:self)
         }
         if i > 100 { break }
         }*/
        
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

