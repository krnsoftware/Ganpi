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

/// 言語共通で使う機能別カラー
enum KFunctionalColor: CaseIterable {
    case base
    case background
    case comment
    case string
    case keyword
    case number
    case variable
    case tag
    case attribute
    case selector
}

enum KSyntaxType: String, CaseIterable, CustomStringConvertible {
    case plain = "public.plain-text"
    case ruby  = "public.ruby-script"
    case html  = "public.html"
    case ini = "public.ini-text"
    
    // extensions for every type.
    var extensions: [String] {
        switch self {
        case .plain: return ["txt", "text", "md"]
        case .ruby:  return ["rb", "rake", "ru", "erb"]
        case .html:  return ["html", "htm"]
        case .ini:   return ["ini", "cfg", "conf"]
        }
    }
    
    // ext is extension only (without '.')
    static func fromExtension(_ ext: String) -> Self? {
        let key = ext.lowercased()
        
        for type in Self.allCases {
            if type.extensions.contains(key) { return type }
        }
        return nil
    }
    
    // メニュー表示用の文字列
    var string: String {
        switch self {
        case .plain: return "Plain"
        case .ruby: return "Ruby"
        case .html: return "HTML"
        case .ini: return "INI"
        }
    }
    
    // 設定ファイルに記述された文字列をenumに変換する。
    static func fromSetting(_ raw: String) -> Self? {
        let key = raw.lowercased()
        return KSyntaxMeta.reverse[key]
    }
    
    // enumを設定ファイルに記述される文字列に変換する。
    var settingName: String {
        return KSyntaxMeta.map[self]!
    }
    
    // enumと設定名の対応を示す構造体。
    private struct KSyntaxMeta {
        // enum → 設定名
        static let map: [KSyntaxType : String] = [
            .plain : "plain",
            .ruby  : "ruby",
            .html  : "html",
            .ini   : "ini"
        ]
        // 設定名 → enum
        static let reverse: [String : KSyntaxType] = {
            var r: [String : KSyntaxType] = [:]
            for (k, v) in map { r[v] = k }
            return r
        }()
    }
    
    // KSyntaxType.plain.makeParser(storage:self)...といった形で生成する。
    // 最終的にはdefault節なしとする。
    //func makeParser(storage:KTextStorageReadable) -> KSyntaxParserProtocol {
    func makeParser(storage:KTextStorageReadable) -> KSyntaxParser {
        switch self {
        case .plain: return KSyntaxParserPlain(storage: storage)
        case .ruby: return KSyntaxParserRuby(storage: storage)
        case .ini: return KSyntaxParserIni(storage: storage)
        default: return KSyntaxParserPlain(storage: storage)
        }
    }
    
    static func detect(fromTypeName typeName: String?, orExtension ext: String?) -> Self {
        // 1) typeName が UTI として一致するか
        if let type = typeName, let knownType = KSyntaxType(rawValue: type) {
            return knownType
        }
        
        // 2) 拡張子から推定
        if let fileExtensioin = ext?.lowercased() {
            if let type = Self.fromExtension(fileExtensioin) {
                return type
            }
        }
        
        // 3) デフォルトはプレーンテキスト
        return .plain
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


struct KCompletionEntry {
    let text: String
}
/*
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
*/



// MARK: - Parser protocol

/*
protocol KSyntaxParserProtocol: AnyObject {
    // 対象とするKTextStorageの参照。
    var storage: KTextStorageReadable { get }
    
    var type: KSyntaxType { get }
    
    // パース用メソッド TextStorageから呼び出す。
    func noteEdit(oldRange: Range<Int>, newCount: Int)
    func ensureUpToDate(for range: Range<Int>)
    
    // Optional: 必要時に全体パース
    func parse(range: Range<Int>)
    
    // 現在のテキストの範囲rangeについてattributesを取り出す。
    // Painter hook: attribute spans (font is applied by TextStorage)
    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan]
    
    // 文字色の設定など
    var baseTextColor: NSColor { get }
    var backgroundColor: NSColor { get }
    func setTheme(_ theme: [KFunctionalColor: NSColor])
    func reloadTheme() //reloading all colors.
    
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
    
    // コメント用のプロパティ
    var lineCommentPrefix: String? { get }
    
    // ランタイムでキーワードを差し替える（語彙は [String] で供給）
    func setKeywords(_ words: [String])
    
}
*/

class KSyntaxParser {
    // Properties
    let storage: KTextStorageReadable
    let type: KSyntaxType
    let keywords: [[UInt8]]
    private let _theme: [KFunctionalColor: NSColor]
    
    var baseTextColor: NSColor { return color(.base) }
    var backgroundColor: NSColor { return color(.background) }
    
    var lineCommentPrefix: String? { return nil }
    
    func noteEdit(oldRange: Range<Int>, newCount: Int) { /* no-op */ }
    
    // ensure internal state is valid for given range
    func ensureUpToDate(for range: Range<Int>) { /* no-op */ }
    
    // 'range' always doesn't contain LF.
    func attributes(in range: Range<Int>, tabWidth: Int) -> [KAttributedSpan] { return [] }
    
    func color(_ role: KFunctionalColor) -> NSColor {
        if let color = _theme[role] { return color }
        log("no such color.",from:self)
        return NSColor.textColor
    }
    
    // Additional functions.
    func wordRange(at index: Int) -> Range<Int>? { return nil }
    // where the caret is. Outer: class/struct, Inner: var/func.
    func currentContext(at index: Int) -> (outer: String?, inner: String?) { return (nil, nil) }
    // get outline of structures. for 'jump' menu.
    func outline(in range: Range<Int>?) -> [KOutlineItem] { return [] }
    // get completion words.
    func completionEntries(prefix: String) -> [String] { return [] }
    
    
    init(storage: KTextStorageReadable, type:KSyntaxType){
        self.storage = storage
        self.type = type
        
        // load keywords
        keywords = []
        
        // load theme.
        let prefs = KPreference.shared
        var theme: [KFunctionalColor: NSColor] = [:]
        
        for role in KFunctionalColor.allCases {
            if let key = Self.prefKey(for: role) {
                theme[role] = prefs.color(key, lang: type)
            }
        }
        _theme = theme
    }
    
    private static func prefKey(for role: KFunctionalColor) -> KPrefKey? {
        switch role {
        case .base:       return .parserColorText
        case .background: return .parserColorBackground
        case .comment:    return .parserColorComment
        case .string:     return .parserColorLiteral
        case .keyword:    return .parserColorKeyword
        case .number:     return .parserColorNumeric
        case .variable:   return .parserColorVariable
        case .tag:        return .parserColorTag
        case .attribute, .selector:
            return nil
        }
    }
    
    func makeSpan(range: Range<Int>, role: KFunctionalColor) -> KAttributedSpan {
        return KAttributedSpan(range: range, attributes: [.foregroundColor: color(role)])
    }

}


