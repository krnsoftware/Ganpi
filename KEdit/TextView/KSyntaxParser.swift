//
//  KSyntaxParser.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Foundation
import AppKit
import TreeSitterBridge

typealias TSLanguage = OpaquePointer

@_silgen_name("tree_sitter_ruby")
func tree_sitter_ruby() -> UnsafePointer<TSLanguage>

final class KSyntaxParser {

    // MARK: - Enum and Struct

    enum KSyntaxType: String, CaseIterable {
        case ruby = "ruby"
        case html = "html"
        case plain = "plain"
    }

    enum KSyntaxColorType {
        case `default`  // 地の色
        case comment
        case string
        case keyword

        var color: NSColor {
            switch self {
            case .default:
                return NSColor.black
            case .comment:
                return NSColor.systemGreen
            case .string:
                return NSColor.systemRed
            case .keyword:
                return NSColor.systemBlue
            }
        }
    }
    
    /// 構文要素の種類を表す列挙体
    /// Tree-sitter の node type に対応させやすい文字列 rawValue を持つ
    enum KSyntaxElementKind {
        case comment, string, keyword

        init?(nodeType: UnsafePointer<CChar>) {
            switch String(cString: nodeType) {
            case "comment": self = .comment
            case "string", "string_literal", "regex": self = .string
            case "keyword": self = .keyword
            default: return nil
            }
        }

        var colorType: KSyntaxColorType {
            switch self {
            case .comment: return .comment
            case .string: return .string
            case .keyword: return .keyword
            }
        }
    }

    /// 構文ハイライトの対象となる範囲とその種類を保持する構造体
    struct KSyntaxHighlightSpan {
        let range: Range<Int>
        let kind: KSyntaxElementKind
    }

    // MARK: - Properties

    private let _textStorageRef: KTextStorageReadable
    private var _syntaxType: KSyntaxType = .plain
    private var _parser: OpaquePointer? = ts_parser_new()
    private var _tree: OpaquePointer?
    private var _highlightSpans: [KSyntaxHighlightSpan] = []
    private var _lock = os_unfair_lock_s()

    var type: KSyntaxType {
        get { _syntaxType }
        set { _syntaxType = newValue; resetParserForType() }
    }

    // MARK: - Init

    init(textStorage: KTextStorageReadable, type: KSyntaxType = .plain) {
        _textStorageRef = textStorage
        _syntaxType = type
        setupParser()
    }

    deinit {
        if let tree = _tree {
            ts_tree_delete(tree)
        }
        if let parser = _parser {
            ts_parser_delete(parser)
        }
    }

    // MARK: - Public methods

    func parse(_ range: Range<Int>) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        let source = makeASCIICompatibleUTF8(from: range)
        log("range = \(range), source.count = \(source.count)",from:self)
        
        guard let parser = _parser else { log("parser is nil.",from:self); return }
        
        //guard let tree = ts_parser_parse_string(parser, _tree, source, UInt32(source.count)) else { log("tree is nil.",from:self); return }
        if let oldTree = _tree { ts_tree_delete(oldTree) }
        guard let tree = ts_parser_parse_string(parser, nil, source, UInt32(source.count)) else { log("tree is nil.",from:self); return }

        _tree = tree
        
        _highlightSpans.removeAll()
        walkTree(from: ts_tree_root_node(tree), into: &_highlightSpans)
        log("_highlightSpans.count = \(_highlightSpans.count)",from:self)
        
    }
    
    func highlightSpans(in range: Range<Int>) -> [KSyntaxHighlightSpan] {
        _highlightSpans.filter { $0.range.overlaps(range) }
    }

    // MARK: - Private methods

    private func setupParser() {
        resetParserForType()
    }

    private func resetParserForType() {
        guard let parser = _parser else { return }

        let language: OpaquePointer?
        switch _syntaxType {
        case .ruby:
            language = tree_sitter_ruby()
            //print("tree_sitter_ruby() ->", language)
        case .html:
            language = nil // TODO: 対応後変更
        case .plain:
            language = nil
        }

        let ok = ts_parser_set_language(parser, language)
        if ts_parser_language(_parser) == nil {
            print("❌ _parser.language が nil です")
        }
        print("✅ set_language result: \(ok)")  // 0 = 失敗, 1 = 成功
    }

    private func makeASCIICompatibleUTF8(from range: Range<Int>) -> [UInt8] {
        guard !range.isEmpty else { log("range is empty.",from:self); return [] }
        log("range: \(range)",from:self)
        
        let asciiString = _textStorageRef.characterSlice[range].map { char -> Character in
            return char.isSingleByteCharacterInUTF8 ? char : Character("a")
        }
        //log("asciiString: = \(asciiString)",from:self)
        //return String(asciiString).utf8.map { $0 }
        let stringWithNewline = String(asciiString) + "\n"
        return stringWithNewline.utf8.map { $0 }
    }

    private func collectColorableNodes(in node: TSNode, into results: inout [(Range<Int>, KSyntaxColorType)]) {
        // 無効ノードは無視
        guard ts_node_is_null(node) == false else { return }

        let type = String(cString: ts_node_type(node))
        let start = Int(ts_node_start_byte(node))
        let end = Int(ts_node_end_byte(node))
        let range = start..<end

        // 特定の型にマッチした場合、色分け情報として保存
        switch type {
        case "string", "string_literal", "heredoc", "regex":
            results.append((range, .string))
        case "comment":
            results.append((range, .comment))
        case "identifier":
            // Rubyでは定義名などもidentifierだが、キーワードと重なることもあるため今回は除外
            break
        case "keyword", "modifier", "control":
            results.append((range, .keyword))
        default:
            break
        }

        // 子ノードを再帰的に走査
        let childCount = ts_node_child_count(node)
        for i in 0..<childCount {
            let child = ts_node_child(node, i)
            collectColorableNodes(in: child, into: &results)
        }
    }

    private func isKeywordType(_ type: String) -> Bool {
        // 一般的なRubyキーワードの例。必要に応じて拡張。
        let keywords = ["def", "end", "if", "else", "elsif", "while", "do", "class", "module", "begin", "rescue"]
        return keywords.contains(type)
    }
    
    private func walkTree(from node: TSNode, into result: inout [KSyntaxHighlightSpan]) {
        // 対象ノードタイプか判定
        if let kind = KSyntaxElementKind(nodeType: ts_node_type(node)) {
            log(String(cString: ts_node_type(node)),from:self)
            let start = Int(ts_node_start_byte(node))
            let end = Int(ts_node_end_byte(node))
            result.append(KSyntaxHighlightSpan(range: start..<end, kind: kind))
        }

        // 再帰的に子ノードを走査
        let childCount = ts_node_child_count(node)
        for i in 0..<childCount {
            let child = ts_node_child(node, i)
            walkTree(from: child, into: &result)
        }
    }
}


