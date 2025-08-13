//
//  Document.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/05/25.
//

import Cocoa

class Document: NSDocument {
    
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
    /*
    override func makeWindowControllers() {
        /*
        let viewController = KViewController()

        let window = NSWindow(
            contentRect: NSMakeRect(0, 0, 800, 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled"
        window.contentViewController = viewController
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true

        let windowController = NSWindowController(window: window)
        self.addWindowController(windowController)

        // 🌙 表示を遅延させることで描画タイミングを明確化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            window.makeKeyAndOrderFront(nil)
            window.display()
        }*/
        
        Swift.print("Document.makeWindowControllers")
        
        let wc = NSWindowController(windowNibName: "Document")
        self.addWindowController(wc)
        
        guard let w = wc.window else { return }
        
        // Document.swift : makeWindowControllers() で window を取得した直後に
        #if DEBUG
        DispatchQueue.main.async { [weak w = wc.window] in
            guard let w = w,
                  let titlebar = w.standardWindowButton(.closeButton)?.superview,
                  let contentSuper = w.contentView?.superview else { return }

            let titlebarFrame = titlebar.convert(titlebar.bounds, to: nil) // ウインドウ座標
            // contentSuper 配下で titlebar と交差する「白の可能性がある」ビューを拾う
            func scan(_ v: NSView) {
                let f = v.convert(v.bounds, to: nil)
                if f.intersects(titlebarFrame) && (v.wantsLayer && (v.layer?.backgroundColor != nil)) {
                    Swift.print("[TitlebarOverlap] \(type(of: v)) frame=\(NSStringFromRect(f)) bg=\(String(describing: v.layer?.backgroundColor))")
                }
                v.subviews.forEach(scan)
            }
            scan(contentSuper)
            Swift.print("contentLayoutRect=\(NSStringFromRect(w.contentLayoutRect))")
        }
        #endif
        
        Swift.print("— Window Info —")
        Swift.print("styleMask=\(w.styleMask.rawValue)")
        Swift.print("titlebarAppearsTransparent=\(w.titlebarAppearsTransparent) titleVisibility=\(w.titleVisibility)")
        Swift.print("isOpaque=\(w.isOpaque) bg=\(String(describing: w.backgroundColor))")
        Swift.print("frame=\(NSStringFromRect(w.frame))")
        Swift.print("contentRect(for:frame)=\(NSStringFromRect(NSWindow.contentRect(forFrameRect: w.frame, styleMask: w.styleMask)))")
        Swift.print("contentLayoutRect=\(NSStringFromRect(w.contentLayoutRect))")
        
        
        
    }*/
    
    
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
    }
    
    
    

    override func data(ofType typeName: String) throws -> Data {
        // Insert code here to write your document to data of the specified type, throwing an error in case of failure.
        // Alternatively, you could remove this method and override fileWrapper(ofType:), write(to:ofType:), or write(to:ofType:for:originalContentsURL:) instead.
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // Insert code here to read your document from the given data of the specified type, throwing an error in case of failure.
        // Alternatively, you could remove this method and override read(from:ofType:) instead.
        // If you do, you should also override isEntireFileLoaded to return false if the contents are lazily loaded.
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }


}

