//
//  KTextCompatibility.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/02,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Foundation

enum KTextEncoding: String, CaseIterable, CustomStringConvertible {
    case utf8  = "utf8"
    case utf16 = "utf16"
    case utf32 = "utf32"
    case jis   = "jis"
    case sjis  = "sjis"
    case euc   = "euc"
    
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
    
    static func fromSetting(_ raw: String) -> KTextEncoding? {
        return KTextEncoding(rawValue: raw)
    }
    
    func stringEncoding() -> String.Encoding {
        switch self {
        case .utf8:  return .utf8
        case .utf16: return .utf16
        case .utf32: return .utf32
        case .jis:   return .iso2022JP
        case .sjis:  return .shiftJIS
        case .euc:   return .japaneseEUC
        }
    }

    
    var description: String {
        return "KTextEncoding: \(self.string)"
    }
    
    var string: String {
        switch self {
        case .utf8:  return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf32: return "UTF-32"
        case .jis:   return "JIS"
        case .sjis:  return "SJIS"
        case .euc:   return "EUC"
        }
    }
    
}


//MARK: - Return Character

extension String {
    enum ReturnCharacter : String, CaseIterable, CustomStringConvertible {
        case lf = "\n"
        case cr = "\r"
        case crlf = "\r\n"
        
        static func fromSetting(_ raw: String) -> ReturnCharacter? {
            switch raw {
            case "lf": return .lf
            case "cr": return .cr
            case "crlf": return .crlf
            default: return nil
            }
        }
        
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


//MARK: - AppleScript

extension KTextEncoding {
    
    var appleScriptCode: FourCharCode {
        switch self {
        case .utf8:
            return "Guf8".fourCharCode
        case .utf16:
            return "Gu16".fourCharCode
        case .utf32:
            return "Gu32".fourCharCode
        case .jis:
            return "Gjis".fourCharCode
        case .sjis:
            return "Gsjs".fourCharCode
        case .euc:
            return "Geuc".fourCharCode
        }
    }
    
    init?(appleScriptCode: FourCharCode) {
        switch appleScriptCode {
        case "Guf8".fourCharCode:
            self = .utf8
        case "Gu16".fourCharCode:
            self = .utf16
        case "Gu32".fourCharCode:
            self = .utf32
        case "Gjis".fourCharCode:
            self = .jis
        case "Gsjs".fourCharCode:
            self = .sjis
        case "Geuc".fourCharCode:
            self = .euc
        default:
            return nil
        }
    }
}

extension String.ReturnCharacter {
    
    var appleScriptCode: FourCharCode {
        switch self {
        case .lf:
            return "Grlf".fourCharCode
        case .cr:
            return "Grcr".fourCharCode
        case .crlf:
            return "Gcrl".fourCharCode
        }
    }
    
    init?(appleScriptCode: FourCharCode) {
        switch appleScriptCode {
        case "Grlf".fourCharCode:
            self = .lf
        case "Grcr".fourCharCode:
            self = .cr
        case "Gcrl".fourCharCode:
            self = .crlf
        default:
            return nil
        }
    }
}
