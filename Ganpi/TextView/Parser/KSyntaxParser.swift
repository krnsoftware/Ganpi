//
//  KSyntaxParser.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

// MARK: - Shared models



struct AttributedSpan {
    let range: Range<Int>
    let attributes: [NSAttributedString.Key: Any]
}

enum KSyntaxType: String, CaseIterable, CustomStringConvertible {
    case plain = "public.plain-text"
    case ruby  = "public.ruby-script"
    case html  = "public.html"
    
    func makeParser(storage:KTextStorageReadable) -> KSyntaxParserProtocol {
        switch self {
        case .plain: return KSyntaxParserPlain(storage: storage)
        case .ruby: return KSyntaxParserRuby(storage: storage)
        default: return KSyntaxParserPlain(storage: storage) // 暫定。
        }
    }
    
    static func detect(fromTypeName typeName: String?, orExtension ext: String?) -> KSyntaxType {
        // 1) typeName が UTI として一致するか
        if let t = typeName, let known = KSyntaxType(rawValue: t) {
            return known
        }
        
        // 2) 拡張子から推定
        if let e = ext?.lowercased() {
            if let mapped = _extMap[e] {
                return mapped
            }
        }
        
        // 3) デフォルトはプレーンテキスト
        return .plain
    }

        /// 拡張子 → SyntaxType マップ
    private static let _extMap: [String: KSyntaxType] = [
            "txt": .plain,
            "text": .plain,
            "md": .plain,
            "rb": .ruby,
            "rake": .ruby,
            "ru": .ruby,
            "erb": .ruby,
            "html": .html,
            "htm": .html
        ]
    
    var string: String {
        switch self {
        case .plain: return "Plain"
        case .ruby: return "Ruby"
        case .html: return "HTML"
        }
    }
    
    var description: String {
        return "KSyntaxType: \(self.string)"
    }
}

// MARK: - Outline API

/// 言語アウトライン1項目
struct OutlineItem {
    enum Kind { case `class`, module, method }
    let kind: Kind
    let name: String                 // 表示名（例: "Foo::Bar", "#empty?", ".new"）
    let containerPath: [String]      // 例: ["Foo","Bar"]
    let nameRange: Range<Int>        // 名前シンボルのみ
    let headerRange: Range<Int>      // "def foo ..."(行末まで)
    let bodyRange: Range<Int>?       // 対応 end の直前まで（未確定なら nil）
    let lineIndex: Int               // nameRange.lowerBound の行番号
    let level: Int                   // ネスト深さ（UI用）
    let isSingleton: Bool            // def self.foo / def Klass.bar
}



typealias FC = FuncChar


// MARK: - Parser protocol

protocol KSyntaxParserProtocol: AnyObject {
    // TextStorage -> Parser
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)
    
    func outline(in range: Range<Int>?) -> [OutlineItem]     // nilで全文
    func currentContext(at index: Int) -> [OutlineItem]      // 外側→内側の順
    
    // Optional: full parse when needed
    func parse(range: Range<Int>)
    
    // Painter hook: attribute spans (font is applied by TextStorage)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan]
    
    var storage: KTextStorageReadable { get }
    func wordRange(at index: Int) -> Range<Int>?
    
    //static func makeParser(for type:KSyntaxType) -> KSyntaxParserProtocol?
    
}



