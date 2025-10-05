//
//  KSyntaxParser.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import AppKit

// MARK: - Shared models



struct KAttributedSpan {
    let range: Range<Int>
    let attributes: [NSAttributedString.Key: Any]
}

enum KSyntaxType: String, CaseIterable, CustomStringConvertible {
    case plain = "public.plain-text"
    case ruby  = "public.ruby-script"
    case html  = "public.html"
    
    // 拡張子 → SyntaxType マップ
    private static let _extMap: [String: KSyntaxType] = [
            /* plain */ "txt": .plain, "text": .plain, "md": .plain,
            /* ruby */  "rb": .ruby, "rake": .ruby, "ru": .ruby, "erb": .ruby,
            /* html */  "html": .html, "htm": .html
        ]
    
    // KSyntaxType.plain.makeParser(storage:self)...といった形で生成する。
    func makeParser(storage:KTextStorageReadable) -> KSyntaxParserProtocol {
        switch self {
        case .plain: return KSyntaxParserPlain(storage: storage)
        case .ruby: return KSyntaxParserRuby(storage: storage)
        default: return KSyntaxParserPlain(storage: storage) // 暫定。
        }
    }
    
    static func detect(fromTypeName typeName: String?, orExtension ext: String?) -> KSyntaxType {
        // 1) typeName が UTI として一致するか
        if let type = typeName, let knownType = KSyntaxType(rawValue: type) {
            return knownType
        }
        
        // 2) 拡張子から推定
        if let fileExtionsion = ext?.lowercased() {
            if let mapped = _extMap[fileExtionsion] {
                return mapped
            }
        }
        
        // 3) デフォルトはプレーンテキスト
        return .plain
    }
    
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
struct KOutlineItem {
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

// MARK: - Completion Common Types

/// 候補の種類（共通）
enum KCompletionKind {
    case keyword
    case typeClass
    case typeModule
    case methodInstance
    case methodClass
    case constant
    case variableLocal
    case variableInstance
    case variableClass
    case variableGlobal
    case symbol
}

/// 1件の候補
struct KCompletionEntry {
    let text: String          // 挿入文字列（例: "to_i"）
    let kind: KCompletionKind
    let detail: String?       // 表示用ラベル（例: "String · #to_i"）
    let score: Int            // 並べ替え用（ポリシーがアルファベットなら 0 のままでOK）
}

/// 並べ替えポリシー（拡張用）。現段階では .alphabetical のみ使用
enum KCompletionPolicy {
    case alphabetical
    case heuristic(KCompletionWeights) // 今回は未使用（将来用）
}

/// 重み（将来のヒューリスティック用）
struct KCompletionWeights {
    var baseByKind: [KCompletionKind: Int] = [:]
    var nearBoostMax: Int = 0
    var scopeBoost: Int = 0
    var freqUnit: Int = 0
    var recentHit: Int = 0
}




// MARK: - Parser protocol

protocol KSyntaxParserProtocol: AnyObject {
    // 対象とするKTextStorageの参照。
    var storage: KTextStorageReadable { get }
    
    // パース用メソッド TextStorageから呼び出す。
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)
    
    // Optional: 必要時に全体パース
    func parse(range: Range<Int>)
    
    // 現在のテキストの範囲rangeについてattributesを取り出す。
    // Painter hook: attribute spans (font is applied by TextStorage)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan]
    
    // caretのindex:iに於いてそれに属すると思われる単語の領域。
    func wordRange(at index: Int) -> Range<Int>?
    
    // 文書の構造をパースする。
    func outline(in range: Range<Int>?) -> [KOutlineItem]     // if nil, in whole text.
    func currentContext(at index: Int) -> [KOutlineItem]      // outer -> inner.
    
    // Word Completionに関するメソッド。
    func rebuildCompletionsIfNeeded(dirtyRange: Range<Int>?)
    func completionEntries(prefix: String,
                           around index: Int,
                           limit: Int,
                           policy: KCompletionPolicy) -> [KCompletionEntry]
    
    
}



