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
        // Add your subclass-specific initialization here.
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
        let wc = NSWindowController(windowNibName: "Document")
        addWindowController(wc)

        _ = wc.window                                // NIB をここでロード
        wc.contentViewController = KViewController() // 中身はここで決定

        // ① フレームの自動保存名（次回からはこのサイズで開く）
        wc.windowFrameAutosaveName = "KEditDocumentWindow"

        // ② 初回だけのデフォルトサイズ（自動保存がまだ無い場合）
        if UserDefaults.standard.string(forKey: "NSWindow Frame KEditDocumentWindow") == nil {
            wc.window?.setContentSize(NSSize(width: 720, height: 520))
            wc.window?.center()
        }

        // ③ これ以下に縮まない下限（“豆粒ウインドウ”防止）
        wc.window?.contentMinSize = NSSize(width: 480, height: 320)

        wc.window?.isRestorable = false             // 復元は引き続き無効
        
        if let vc = wc.contentViewController as? KViewController {
            vc.document = self
        }
    }
    
    
    

    override func data(ofType typeName: String) throws -> Data {
        // Insert code here to write your document to data of the specified type, throwing an error in case of failure.
        // Alternatively, you could remove this method and override fileWrapper(ofType:), write(to:ofType:), or write(to:ofType:for:originalContentsURL:) instead.
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }

    
    
    override func read(from data: Data, ofType typeName: String) throws {
        
        // 1) 文字コードの推定 → 文字列化
        let encoding = String.estimateCharacterCode(from: data) ?? .utf8
        guard let decoded = String(bytes: data, encoding: encoding) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadUnknownStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding"])
        }

        // 2) 改行の正規化（内部は常に LF）、最初に見つかった外部改行を記録
        let norm = decoded.normalizeNewlinesAndDetect()
        _characterCode = encoding
        _returnCode = norm.detected ?? .lf   // 改行が無い場合は LF を既定

        // 3) 本文を TextStorage へ投入（全文置換）
        _textStorage.replaceString(in: 0..<_textStorage.count, with: norm.normalized)

        // 4) 読み込み完了（未変更状態へ）
        updateChangeCount(.changeCleared)

        // （必要ならここで _syntaxType を typeName / 拡張子から推定して設定）
        
        //log("return code: \(_returnCode), character code: \(_characterCode)",from:self)
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

