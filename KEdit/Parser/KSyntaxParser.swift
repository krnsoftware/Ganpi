//
//  KSyntaxParser.swift
//  KEdit
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

enum KSyntaxType: String, CaseIterable {
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
}

typealias FC = FuncChar


// MARK: - Parser protocol

protocol KSyntaxParserProtocol: AnyObject {
    // TextStorage -> Parser
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)
    
    // Optional: full parse when needed
    func parse(range: Range<Int>)
    
    // Painter hook: attribute spans (font is applied by TextStorage)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [AttributedSpan]
    
    var storage: KTextStorageReadable { get }
    func wordRange(at index: Int) -> Range<Int>?
    
    //static func makeParser(for type:KSyntaxType) -> KSyntaxParserProtocol?
    
}

/*
extension KSyntaxParserProtocol {
    // 既定の“単語”= [A-Za-z0-9_]+
    @inline(__always)
    private func _isIdent(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == FC.underscore
    }

    public func wordRange(at index: Int) -> Range<Int> {
        let count = storage.count
        if count == 0 { return 0..<0 }

        // 1 回の呼び出し内でスナップショット固定
        let skeleton = storage.skeletonString
        let bytes = skeleton.bytes(in: 0..<count)

        // caret が末尾なら一つ戻って観察
        var i = max(0, min(index, count))
        if i == count { i = max(0, count - 1) }

        let c = bytes[i]
        guard _isIdent(c) else { return i..<i } // 空白や記号は“空選択”にする

        var start = i
        while start > 0, _isIdent(bytes[start - 1]) { start &-= 1 }
        var end = i &+ 1
        while end < count, _isIdent(bytes[end]) { end &+= 1 }

        return start..<end
    }
}*/



