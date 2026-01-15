//
//  String.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/06/01.
//

import Cocoa

// MARK: - String extionsion for estimating character codes.

extension String {
    /// 文字コードを推定する（BOM 優先。BOMなし UTF-16/32 は非対応）
    static func estimateCharacterCode(from data: Data) -> String.Encoding? {
        let count = data.count
        if count == 0 { return .utf8 } // 空は UTF-8 扱い

        // --- 1) BOM 判定（必ず BE/LE を明示して返す） ---
        if count >= 4 {
            // UTF-32 BE: 00 00 FE FF
            if data[0] == 0x00, data[1] == 0x00, data[2] == 0xFE, data[3] == 0xFF {
                return .utf32BigEndian
            }
            // UTF-32 LE: FF FE 00 00
            if data[0] == 0xFF, data[1] == 0xFE, data[2] == 0x00, data[3] == 0x00 {
                return .utf32LittleEndian
            }
        }
        if count >= 2 {
            // UTF-16 BE: FE FF
            if data[0] == 0xFE, data[1] == 0xFF { return .utf16BigEndian }
            // UTF-16 LE: FF FE
            if data[0] == 0xFF, data[1] == 0xFE { return .utf16LittleEndian }
        }
        if count >= 3 {
            // UTF-8 BOM: EF BB BF
            if data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { return .utf8 }
        }

        // --- 2) ラウンドトリップ（UTF-8 / SJIS / JIS / EUC のみ） ---
        // ※ UTF-16/32 は BOM なし非対応のため候補に含めない
        let candidates: [String.Encoding] = [.utf8, .shiftJIS, .iso2022JP, .japaneseEUC]
        var roundTripHits: [String.Encoding] = []
        for enc in candidates {
            if let s = String(bytes: data, encoding: enc), s.data(using: enc) == data {
                roundTripHits.append(enc)
            }
        }
        if roundTripHits == [.utf8] {
            // UTF-8 だけが往復一致
            return .utf8
        }

        // --- 3) S-JIS / JIS / EUC のヒューリスティック ---
        enum StrEnc { case newType, oldType, necType, eucType, sjisType, eucOrSJISType, asciiType }
        struct JISChar {
            static let esc:  UInt8 = 27
            static let ss2:  UInt8 = 142
        }

        var codeType: StrEnc = .asciiType
        var i = 0
        while (codeType == .eucOrSJISType || codeType == .asciiType), i < count {
            var c = data[i]; i += 1
            if c == 0 { continue }

            if c == JISChar.esc {               // ESC
                guard i < count else { break }
                c = data[i]; i += 1
                if c == 0x24 {                  // '$'
                    guard i < count else { break }
                    c = data[i]; i += 1
                    if c == 0x42 { codeType = .newType }     // 'B'
                    else if c == 0x40 { codeType = .oldType } // '@'
                } else if c == 0x4B {            // 'K'
                    codeType = .necType
                }
            } else if (129...141).contains(c) || (143...159).contains(c) {
                codeType = .sjisType
            } else if c == JISChar.ss2 {
                guard i < count else { break }
                c = data[i]; i += 1
                if (64...126).contains(c) || (128...160).contains(c) || (224...252).contains(c) {
                    codeType = .sjisType
                } else if (161...223).contains(c) {
                    codeType = .eucOrSJISType
                }
            } else if (161...223).contains(c) {
                guard i < count else { break }
                c = data[i]; i += 1
                if (240...254).contains(c) {
                    codeType = .eucType
                } else if (161...223).contains(c) {
                    codeType = .eucOrSJISType
                } else if (224...239).contains(c) {
                    codeType = .eucOrSJISType
                    while c >= 64, c != 0, codeType == .eucOrSJISType, i < count {
                        if c >= 129 {
                            if (c <= 141) || (143...159).contains(c) { codeType = .sjisType }
                            else if (253...254).contains(c)          { codeType = .eucType  }
                        }
                        c = data[i]; i += 1
                    }
                } else if c <= 159 {
                    codeType = .sjisType
                }
            } else if (240...254).contains(c) {
                codeType = .eucType
            } else if (224...239).contains(c) {
                guard i < count else { break }
                c = data[i]; i += 1
                if (64...126).contains(c) || (128...160).contains(c) { codeType = .sjisType }
                else if (253...254).contains(c)                      { codeType = .eucType  }
                else if (161...252).contains(c)                      { codeType = .eucOrSJISType }
            }
        }

        if codeType == .newType || codeType == .oldType { return .iso2022JP }
        if codeType == .eucType || codeType == .eucOrSJISType { return .japaneseEUC }

        // --- 4) BOMなし UTF-8 のビットパターン検査 ---
        var trailingBytesNeeded = 0
        var looksLikeUTF8 = true
        for b in data {
            if trailingBytesNeeded > 0 {
                if (b & 0xC0) == 0x80 { trailingBytesNeeded -= 1 }
                else { looksLikeUTF8 = false; break }
                continue
            }
            if (b & 0x80) == 0x00 { continue }           // 0xxxxxxx
            if (b & 0xE0) == 0xC0 { trailingBytesNeeded = 1 } // 110xxxxx
            else if (b & 0xF0) == 0xE0 { trailingBytesNeeded = 2 } // 1110xxxx
            else if (b & 0xF8) == 0xF0 { trailingBytesNeeded = 3 } // 11110xxx
            else { looksLikeUTF8 = false; break }
        }
        if looksLikeUTF8 { return .utf8 }

        // --- 5) 最後に SJIS を確定 ---
        if codeType == .sjisType { return .shiftJIS }

        // ここまでで確定しなければ不明（BOMなし UTF-16/32 は非対応）
        print(#function + " - Can't estimate the character code of this document.")
        return nil
    }
}

//MARK: - String Extension for Integer Subscripts

extension String {
    func index(at pos: Int) -> String.Index {
              return index((pos >= 0 ? startIndex : endIndex), offsetBy: pos)
    }
    
    // string[i]
    subscript(pos: Int) -> String {
        return String(self[index(at: pos)])
    }
    
    // string[a..<b]
    subscript(bounds: CountableRange<Int>) -> Substring {
        return self[index(at: bounds.lowerBound)..<index(at: bounds.upperBound)]
    }
    
}

// MARK: - Conversion of String.Index

extension StringProtocol {
    
    // String.IndexからInt、あるいはRange<String.Index>からRange<Int>に変換する。
    func integerRange(from stringRange: Range<String.Index>) -> Range<Int>? {
        // 1) 範囲が self に属しているか検証
        guard stringRange.lowerBound >= startIndex,
              stringRange.upperBound <= endIndex,
              stringRange.lowerBound <= stringRange.upperBound
        else { print("StringProtocol::integerRange] out of range.") ; return nil }

        // 2) 正常系
        let lower = distance(from: startIndex, to: stringRange.lowerBound)
        let upper = distance(from: startIndex, to: stringRange.upperBound)
        return lower..<upper
    }

    func integerIndex(of index: String.Index) -> Int? {
        guard index >= startIndex, index <= endIndex else {
            print("StringProtocol::integerIndex] out of range.")
            return nil
        }
        return distance(from: startIndex, to: index)
    }
    
    // IntからString.Index、あるいはRange<Int>からRange<String.Index>に変換する。
    func stringIndexRange(from intRange: Range<Int>) -> Range<String.Index>? {
        guard let lower = stringIndexIndex(of: intRange.lowerBound),
              let upper = stringIndexIndex(of: intRange.upperBound),
              lower <= upper else {
            print("StringProtocol::stringIndexRange] out of range.")
            return nil
        }
        return lower..<upper
    }

    func stringIndexIndex(of index: Int) -> String.Index? {
        guard index >= 0, index <= self.count else {
            print("StringProtocol::stringIndexIndex] out of range.")
            return nil
        }
        return self.index(startIndex, offsetBy: index)
    }
    
    
    
    
}

//MARK: - Normalizing, Treat Return Codes.

extension String {
    
    // 簡易的に
    var normalizedString: String {
        return self.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .filter { !$0.isControl || $0 == "\n" || $0 == "\t" }
    }
    
    /// 最初に見つかった改行種別（CRLF/CR/LF）を返しつつ、本文は LF 正規化して返す
        /// Unicode の改行（NEL/LS/PS）も LF に畳み込みます
    
    func normalizeNewlinesAndDetect() -> (normalized: String, detected: String.ReturnCharacter?) {
        
        let utf8Bytes = self.utf8
        var outputBytes: [UInt8] = []
        outputBytes.reserveCapacity(utf8Bytes.count)
        
        var detected: String.ReturnCharacter? = nil
        var i = utf8Bytes.startIndex
        
        while i != utf8Bytes.endIndex {
            let b0 = utf8Bytes[i]
            
            // LF
            if b0 == KFuncChar.lf {
                if detected == nil { detected = .lf }
                outputBytes.append(KFuncChar.lf)
                utf8Bytes.formIndex(after: &i)
                continue
            }
            
            // CR / CRLF
            if b0 == KFuncChar.cr {
                let next = utf8Bytes.index(after: i)
                if next != utf8Bytes.endIndex, utf8Bytes[next] == KFuncChar.lf {
                    if detected == nil { detected = .crlf }
                    outputBytes.append(KFuncChar.lf)          // CRLF → LF
                    i = utf8Bytes.index(after: next)          // 2 バイト進める
                } else {
                    if detected == nil { detected = .cr }
                    outputBytes.append(KFuncChar.lf)          // CR → LF
                    utf8Bytes.formIndex(after: &i)
                }
                continue
            }
            
            // NEL (U+0085) = 0xC2 0x85
            if b0 == 0xC2 {
                let i1 = utf8Bytes.index(after: i)
                if i1 != utf8Bytes.endIndex, utf8Bytes[i1] == 0x85 {
                    outputBytes.append(KFuncChar.lf)
                    i = utf8Bytes.index(after: i1)
                    continue
                }
            }
            
            // LINE SEPARATOR / PARAGRAPH SEPARATOR (U+2028/U+2029) = 0xE2 0x80 0xA8 / 0xA9
            if b0 == 0xE2 {
                let i1 = utf8Bytes.index(after: i)
                if i1 != utf8Bytes.endIndex, utf8Bytes[i1] == 0x80 {
                    let i2 = utf8Bytes.index(after: i1)
                    if i2 != utf8Bytes.endIndex {
                        let b2 = utf8Bytes[i2]
                        if b2 == 0xA8 || b2 == 0xA9 {
                            outputBytes.append(KFuncChar.lf)
                            i = utf8Bytes.index(after: i2)
                            continue
                        }
                    }
                }
            }
            
            // それ以外はそのままコピー
            outputBytes.append(b0)
            utf8Bytes.formIndex(after: &i)
        }
        
        let normalized = String(decoding: outputBytes, as: UTF8.self)
        return (normalized, detected)
    }
    
    // Stringの改行コードのうち、CR/CRLF/LFの3種類の中で最も最初に出てきたものを返す。なければnil。
    func firstReturnCharacter() -> String.ReturnCharacter? {
        let scalars = self.unicodeScalars
        var i = scalars.startIndex
        while i != scalars.endIndex {
            let s = scalars[i]
            if s == "\n" {
                return .lf
            } else if s == "\r" {
                let next = scalars.index(after: i)
                if next != scalars.endIndex, scalars[next] == "\n" {
                    return .crlf
                } else {
                    return .cr
                }
            }
            i = scalars.index(after: i)
        }
        return nil
    }
}


//MARK: - String Extension for NSColor


extension String {
    func convertToColor() -> NSColor? {
        let pattern = "^#?([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        guard let match = regex.firstMatch(in: self, options: [], range: NSRange(location: 0, length: self.utf16.count)) else {
            return nil
        }
        
        func hexComponent(at index: Int) -> CGFloat? {
            guard let range = Range(match.range(at: index), in: self) else { return nil }
            return CGFloat(Int(self[range], radix: 16) ?? 0) / 255.0
        }
        
        guard let r = hexComponent(at: 1),
              let g = hexComponent(at: 2),
              let b = hexComponent(at: 3) else {
            return nil
        }
        
        let a = hexComponent(at: 4) ?? 1.0
        
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }
}


// MARK: - String.Encoding extionsion for estimating Ganpi can use the encoding.

extension String.Encoding {
    
    // Ganpiで扱うことのできるエンコーディングを定義する。
    static let characterCodeTypeArray: [String.Encoding] = [.shiftJIS, .iso2022JP, .japaneseEUC,
                                                            .utf8, .utf16, .utf32]
    
    // 与えられたString.EncodingがGanpiで扱えるものであるかチェックする。
    static func isValidType(_ code: String.Encoding) -> Bool {
        return characterCodeTypeArray.contains(code)
    }
}


// MARK: - StringProtocol: column width (LFのみ, tab対応)

extension StringProtocol {
    /// 文字列の表示カラム幅を返す（Ganpi仕様: 改行は \n のみ）
    func displayColumns(startColumn: Int = 0, tabWidth: Int = 8) -> Int {
        precondition(tabWidth > 0)
        var col = startColumn
        for ch in self {
            if ch == "\n" { continue }                         // LFのみ考慮
            if ch == "\t" {                                    // タブは次のタブストップへ
                col = ((col / tabWidth) + 1) * tabWidth
            } else {
                col += ch.displayWidth                         // ← 既存の Character.displayWidth を使用
            }
        }
        return col - startColumn
    }

    /// 先頭の空白（space/tab）の連続トークンとそのカラム幅を返す（行内のみ、LFで停止）
    func nextSpacesAndColumns(from index: Index,
                              startColumn: Int,
                              tabWidth: Int = 8)
        -> (spaces: Self.SubSequence, cols: Int, next: Index)
    {
        precondition(tabWidth > 0)
        var i = index
        var col = startColumn
        let start = i

        while i < endIndex {
            let ch = self[i]
            if ch == "\n" { break }
            if ch == " " {
                col += 1
                i = self.index(after: i)
                continue
            }
            if ch == "\t" {
                col = ((col / tabWidth) + 1) * tabWidth
                i = self.index(after: i)
                continue
            }
            break
        }
        return (self[start..<i], col - startColumn, i)
    }

    /// 次の「非空白トークン」（space/tab/\n で区切り）とそのカラム幅を返す
    func nextTokenAndColumns(from index: Index,
                             startColumn: Int,
                             tabWidth: Int = 8)
        -> (token: Self.SubSequence, cols: Int, next: Index)
    {
        var i = index
        if i < endIndex, self[i] == "\n" {
            return (self[i..<i], 0, i) // 空スライス
        }

        let start = i
        var col = startColumn
        while i < endIndex {
            let ch = self[i]
            if ch == "\n" || ch == " " || ch == "\t" { break }
            col += ch.displayWidth
            i = self.index(after: i)
        }
        return (self[start..<i], col - startColumn, i)
    }

}

//MARK: - C string escape/unescape property

extension StringProtocol {

    // 擬似C文字列のエスケープ表現を返す
    var cEscaped: String {
        var result = ""
        result.reserveCapacity(count)

        for c in self {
            switch c {
            case "\\": result.append("\\\\")
            case "\"": result.append("\\\"")
            case "\'": result.append("\\\'")
            case "\n": result.append("\\n")
            case "\r": result.append("\\r")
            case "\t": result.append("\\t")
            case "\0": result.append("\\0")
            case "\u{08}": result.append("\\b") // backspace
            case "\u{0C}": result.append("\\f") // formfeed
            case "\u{0B}": result.append("\\v") // vertical tab
            default:
                result.append(c)
            }
        }
        return result
    }

    // 擬似C文字列をアンエスケープして実文字列に戻す
    var cUnescaped: String {
        var result = ""
        var escaping = false

        for c in self {
            if escaping {
                switch c {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "0": result.append("\0")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "v": result.append("\u{0B}")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "\'": result.append("\'")
                default:
                    // 未定義シーケンスは "\" + c として残す
                    result.append("\\")
                    result.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                result.append(c)
            }
        }

        // 最後が '\' で終わった場合はそのまま残す
        if escaping { result.append("\\") }
        return result
    }
}
