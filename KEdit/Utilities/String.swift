//
//  String.swift
//  KEdit
//
//  Created by KARINO Masatugu on 2025/06/01.
//

import Cocoa


// MARK: - String Extension for Treating Character/Return codes

extension String {
    
    // MARK: - Enumerations, Structs and Classes
    
    
    
    //enum ReturnCharacter : Character, CaseIterable {
    enum ReturnCharacter : String, CaseIterable {
        case lf = "\n"
        case cr = "\r"
        case crlf = "\r\n"
    }
    
    enum FuncChar : Int {
        case tab = 0x09         // tab
        case space = 0x20       // space
        case doubleQuote = 0x22 // "
        case numeric = 0x23     // #
        case percent = 0x25     // %
        case ampersand = 0x26   // &
        case singleQuote = 0x27 // '
        case slash = 0x2f       // /
        case colon = 0x3a       // :
        case semicolon = 0x3b   // ;
        case lt = 0x3c          // <
        case gt = 0x3e          // >
        case backSlash = 0x5c   // back slash
        
        case leftParen = 0x28   // (
        case rightParen = 0x29  // )
        case leftBlacket = 0x5b // [
        case rightBlacket = 0x5d// ]
        case leftBrace = 0x7b   // {
        case rightBrace = 0x7d  // }
    }
    
    // MARK: - Type Methods
    
    // Stringインスタンスの文字コードを返す。検出不能の場合には.utf8を返す。
    static func estimateCharacterCode(from data: Data) -> String.Encoding? {
        /* Unicodeの判定
         BOMなしのUTF-16LE, UTF-16BE, UTF-32LE, UTF-32BEについては対応しない。
         BOMありのUTF-16/32については、BEもLEも等価であると考えて特に変換は考えない。
         BOMありのUTF-8については読み込みはサポートするが書き出しはBOMなしとする。
         */
        if data.count >= 2 {
            if data[0] == 0xFE && data[1] == 0xFF {
                return .utf16
            }
            if data[0] == 0xFF && data[1] == 0xFE {
                if data.count >= 4 && data[2] == 0x00 && data[3] == 0x00 {
                    return .utf32
                }
                return .utf16
            }
        }
        if data.count >= 3 {
            if data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
                print("UTF-8 with BOM")
                return .utf8
            }
            
        }
        if data.count >= 4 {
            if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0xFE && data[3] == 0xFF {
                return .utf32
            }
        }
        
        // DataからStringに変更した後、再度Dataに戻して正しいか確認する。
        // 絵文字が存在する場合にUTF8をSJISに誤判定する問題を回避。
        var encodings: [String.Encoding] = []
        for type in String.Encoding.characterCodeTypeArray {
            if let str = String(bytes: data, encoding: type) {
                if data == str.data(using: type){
                    //print(type)
                    encodings.append(type)
                }
            }
        }
        //dump(encodings)
        if encodings == [.utf8] {
            // utf8のみの判定であればそのまま通す。
            print("data-back estimation - UTF-8 (without BOM)")
            return .utf8
        }
        
        
        /* S-JIS, JIS, EUCの判定
         古い古いコードをSwiftで書き直してみた。35年ほど前のもの。元ネタはJISの緑本。
         UTF-8をshiftJISに誤判定する問題がある。
         逆にshiftJISのデータをUTF-8に誤判定する可能性はあまりないため、UTF-8ではないことを確認してからshiftJISを確定する。
         */
        struct FuncChar {
            static let nullChar = 0
            static let lfChar = 10
            static let crChar = 13
            static let escChar = 27
            static let ss2Char = 142
        }
        
        enum StrEnc {
            case newType
            case oldType
            case necType
            case eucType
            case sjisType
            case eucOrSJISType
            case asciiType
        }
        
        let dataLength = data.count
        var codeType = StrEnc.asciiType
        var c: UInt8
        var i: Int = 0
        
        while (codeType == .eucOrSJISType || codeType == .asciiType ) && i < dataLength {
            
            c = data[i]; i += 1
            if c != 0 {
                if c == FuncChar.escChar {
                    c = data[i]; i += 1
                    if c == 36 /*'$'*/ {
                        c = data[i]; i += 1
                        if c == 66 /*'B'*/ {
                            codeType = .newType
                        } else if c == 64 /*'@'*/ {
                            codeType = .oldType
                        }
                    } else if c == 75 /*'K'*/ {
                        codeType = .necType
                    }
                } else if (c >= 129 && c <= 141) || (c >= 143 && c <= 159) {
                    codeType = .sjisType
                } else if c == FuncChar.ss2Char {
                    c = data[i]; i += 1
                    if (c >= 64 && c <= 126) || (c >= 128 && c <= 160) || (c >= 224 && c <= 252) {
                        codeType = .sjisType
                    } else if c >= 161 && c <= 223 {
                        codeType = .eucOrSJISType
                    }
                } else if c >= 161 && c <= 223 {
                    c = data[i]; i += 1
                    if c >= 240 && c <= 254 {
                        codeType = .eucType
                    } else if c >= 161 && c <= 223 {
                        codeType = .eucOrSJISType
                    } else if c >= 224 && c <= 239 {
                        codeType = .eucOrSJISType
                        while c >= 64 && c != 0 && codeType == .eucOrSJISType {
                            if c >= 129 {
                                if c <= 141 || (c >= 143 && c <= 159) {
                                    codeType = .sjisType
                                } else if c >= 253 && c <= 254 {
                                    codeType = .eucType
                                }
                            }
                            c = data[i]; i += 1
                        }
                    } else if c <= 159 {
                        codeType = .sjisType
                    }
                } else if c >= 240 && c <= 254 {
                    codeType = .eucType
                } else if c >= 224 && c <= 239 {
                    c = data[i]; i += 1
                    if (c >= 64 && c <= 126) || (c >= 128 && c <= 160) {
                        codeType = .sjisType
                    } else if c >= 253 && c <= 254 {
                        codeType = .eucType
                    } else if c >= 161 && c <= 252 {
                        codeType = .eucOrSJISType
                    }
                }
            }
        }
        
        
        // shiftJISは最後の段階で判断する。
        if codeType == .newType || codeType == .oldType {
            return .iso2022JP
        } else if codeType == .eucType || codeType == .eucOrSJISType {
            return .japaneseEUC
        }
        
        
        // BOMなしUTF-8の判定
        /*
         先頭から、0...1バイト文字, 10...2バイト以上の2文字目以降, 110...2バイト, 1110...3バイト, 11110...4バイト
         [0b10000000(0x80), 0b11000000(0xc0), 0b11100000(0xe0), 0b11110000(0xf0), 0b11111000(0xf8)]
         JIS(ISO-2022-JP)は7bitコードでASCIIと誤認されてしまうため判定は最後になる。
         */
        
        var isUTF8 = true
        var children = 0
        for i in 0..<dataLength {
            if children > 0 {
                if data[i] & 0xC0 == 0x80 {
                    children -= 1
                    continue
                } else {
                    isUTF8 = false
                    break
                }
            }
            
            if data[i] & 0x80 == 0x00 { continue }
            if data[i] & 0xE0 == 0xC0 { children = 1 }
            else if data[i] & 0xF0 == 0xE0 { children = 2 }
            else if data[i] & 0xF8 == 0xF0 { children = 3 }
            else { isUTF8 = false; break }
            
        }
        
        if isUTF8 { print("bit-check estimation - UTF-8 (without BOM)"); return .utf8 }
        
        // UTF-8であることが否定されれば、shiftJISと判定する。
        if codeType == .sjisType { /*print("last sjis");*/ return .shiftJIS }
        
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

//MARK: - Normalizing

extension String {
    
    var normalizedString: String {
        return self.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .filter { !$0.isControl || $0 == "\n" || $0 == "\t" }
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

//MARK: - NSColor Extension for String

// Stringに関するNSColor extension

extension NSColor {
    /// NSColor を #RRGGBB または #RRGGBBAA 形式の16進数文字列として返す
    func toHexString(includeAlpha: Bool = false) -> String? {
        guard let rgbColor = usingColorSpace(.sRGB) else {
            return nil // sRGBへの変換失敗
        }

        func to255(_ component: CGFloat) -> Int {
            return Int(round(min(max(component, 0), 1) * 255))
        }

        let r = to255(rgbColor.redComponent)
        let g = to255(rgbColor.greenComponent)
        let b = to255(rgbColor.blueComponent)

        var hexString = String(format: "#%02X%02X%02X", r, g, b)

        if includeAlpha {
            let a = to255(rgbColor.alphaComponent)
            hexString += String(format: "%02X", a)
        }

        return hexString
    }
}


extension String.Encoding {
    
    // KEditで扱うことのできるエンコーディングを定義する。
    static let characterCodeTypeArray: [String.Encoding] = [.shiftJIS, .iso2022JP, .japaneseEUC,
                                                            .utf8, .utf16, .utf32]
    
    // 与えられたString.EncodingがKEditで扱えるものであるかチェックする。
    static func isValidType(_ code: String.Encoding) -> Bool {
        return characterCodeTypeArray.contains(code)
    }
}

/*
extension String {
    /// pattern を検索し、全一致の NSRange を返す（グループは返さない）
    func search(pattern: String,
                options: NSRegularExpression.Options = [],
                range: NSRange? = nil) -> [NSValue] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            print(#function + ": Regex - irregular pattern.")
            return []
        }
        // 範囲の正規化（UTF-16 基準）
        let full = NSRange(location: 0, length: (self as NSString).length)
        let r = range.map { NSIntersectionRange($0, full) }.flatMap { $0.length > 0 ? $0 : nil } ?? full

        return re.matches(in: self, options: [], range: r).map { NSValue(range: $0.range(at: 0)) }
    }
    
    /// pattern を template に置換（$1 等テンプレート可）
        /// 戻り値: (置換数, 置換後文字列)。pattern が不正なら (0, "")
        func replaceAll(pattern: String,
                        template: String,
                        options: NSRegularExpression.Options = [],
                        range: NSRange? = nil) -> (count: Int, string: String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
                print(#function + ": Regex - irregular pattern.")
                return (0, "")
            }
            let full = NSRange(location: 0, length: (self as NSString).length)
            let r = range.map { NSIntersectionRange($0, full) }.flatMap { $0.length > 0 ? $0 : nil } ?? full

            // 置換数（matches は高速）
            let count = re.numberOfMatches(in: self, options: [], range: r)
            // 実際の置換（テンプレート展開は Foundation に任せる）
            let out = re.stringByReplacingMatches(in: self, options: [], range: r, withTemplate: template)
            return (count, out)
        }
}*/
