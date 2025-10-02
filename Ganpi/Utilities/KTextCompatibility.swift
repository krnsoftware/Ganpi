//
//  KTextCompatibility.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/02,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

enum KTextEncoding: CaseIterable, CustomStringConvertible {
    case utf8
    case utf16
    case utf32
    case jis
    case sjis
    case euc
    
    static func normalized(from code: String.Encoding) -> KTextEncoding? {
        switch code {
        case .utf8: return .utf8
        case .utf16, .utf16LittleEndian, .utf16BigEndian: return .utf16
        case .utf32, .utf32LittleEndian, .utf32BigEndian: return .utf32
        case .iso2022JP: return .jis
        case .japaneseEUC: return .euc
        case .shiftJIS: return .sjis
        default: return nil
        }
    }
    
    func stringEncoding() -> String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .utf32: return .utf32
        case .jis: return .iso2022JP
        case .sjis: return .shiftJIS
        case .euc: return .japaneseEUC
        }
    }

    
    var description: String {
        return "KTextEncoding: \(self.string)"
    }
    
    var string: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf32: return "UTF-32"
        case .jis: return "JIS"
        case .sjis: return "SJIS"
        case .euc: return "EUC"
        }
    }
    
}

extension String {
    enum ReturnCharacter : String, CaseIterable, CustomStringConvertible {
        case lf = "\n"
        case cr = "\r"
        case crlf = "\r\n"
        
        var description: String {
            return "KNewlineCharacter: \(self.string)"
        }
        
        var string: String {
            switch self {
            case .lf: return "LF"
            case .cr: return "CR"
            case .crlf: return "CRLF"
            }
        }
    }
}
