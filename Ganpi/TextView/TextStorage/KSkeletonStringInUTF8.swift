//
//  KSkeletonStringInUTF8.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
//  Created by KARINO Masatugu on 2025/08/07.
//


import Cocoa
import Darwin

// KTextStorageに於いて、_characters:[Characters]の代わりに用いられる[UInt8]のwrapper。
// 主にテキスト内の制御文字等を検出するために使用される。

final class KSkeletonStringInUTF8 {
    // MARK: - Enum and Struct.
    
   
    
    
    // MARK: - Properties.
    private var _bytes: [UInt8] = []
    private var _newlineCache: [Int]? = nil
    
    var bytes:[UInt8]  { _bytes }
    var count: Int { _bytes.count }
    
    // 改行コード("\n")のoffsetを全て返す。昇順。
    var newlineIndices: [Int] {
        if let cache = _newlineCache { return cache }
        
        let res = Self.indicesOfCharacter(in: _bytes, range: 0..<_bytes.count, target: FuncChar.lf)
        _newlineCache = res
        return res
    }
    
    // 行頭のインデックスを全て返す。昇順。
    // キャッシュされないため頻繁に呼び出す場合はnewlineIndicesを使用すること。
    var lineStartIndices: [Int] {
        [0] + newlineIndices.map { $0 + 1 }
    }
    
    // MARK: - Static functions
    
    // [Character]をUTF-8実装のUnicodeに変換するが、その際、複数バイトになる文字については"a"を代替文字とする。
    // 元の[Character]と文字の位置が一致するためRange<Int>をそのまま使用できるが、生成した文字列から元の文字列は復元できない。
    static func convertCharactersToApproximateUTF8(_ characters: [Character]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(characters.count) // 出力は必ず等長

        for ch in characters {
            // ASCII: 単一スカラ かつ < 0x80
            if ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first, s.value < 0x80 {
                result.append(UInt8(truncatingIfNeeded: s.value))
            } else {
                result.append(0x61) // 'a'
            }
        }
        return result
    }
    


    static func indicesOfCharacter(in buffer: [UInt8], range: Range<Int>, target: UInt8) -> [Int] {
        guard range.lowerBound >= 0,
              range.upperBound <= buffer.count,
              range.lowerBound < range.upperBound else { return [] }

        let n = range.count
        var out: [Int] = []
        out.reserveCapacity(min(n / 8, 1 << 15))

        buffer.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) -> Void in
            guard let base: UnsafePointer<UInt8> = buf.baseAddress else { return }

            var p: UnsafePointer<UInt8> = base.advanced(by: range.lowerBound)
            let end: UnsafePointer<UInt8> = base.advanced(by: range.upperBound)

            while p < end {
                
                let remaining: Int = end - p
                let foundRaw: UnsafeMutableRawPointer? = Darwin.memchr(
                    UnsafeRawPointer(p),
                    CInt(target),
                    remaining
                )
                guard let qRaw = foundRaw else { break }
                
                // Swift+C APIの関連で一旦mutableにする必要がある。
                let qMut: UnsafeMutablePointer<UInt8> = qRaw.assumingMemoryBound(to: UInt8.self)
                let q: UnsafePointer<UInt8> = UnsafePointer(qMut)

                out.append(range.lowerBound + (q - base))
                p = q.advanced(by: 1)
            }
        }

        return out
    }
    
    init() {
        
    }
    
    //MARK: - Internal functions. (for the limited use)
    
    // KTextStorage.replaceCharacters()内に於いてreplaceSubrange()の後に呼ばれる。
    // それ以外の状況では呼んではならない。
    func replaceCharacters(_ range: Range<Int>, with newCharacters: [Character]) {
        let addition = Self.convertCharactersToApproximateUTF8(newCharacters)
        
        _bytes.replaceSubrange(range, with: addition)
        
        _newlineCache = nil
    }
    
    
    
    
    // MARK: - Internal functions.
    
    // 読み取り専用：範囲外は 0 を返し、ログに記録
    subscript(_ index: Int) -> UInt8 {
    #if DEBUG
        precondition(index >= 0 && index < _bytes.count,
                     "Index \(index) out of range (count: \(_bytes.count))")
        return _bytes[index]
    #else
        if index < 0 || index >= _bytes.count {
            log("Index \(index) out of range (count: \(_bytes.count))", from: self)
            return 0
        }
        return _bytes[index]
    #endif
    }

    // 範囲取得：Debugは即クラッシュ、Releaseは空スライス＋ログ
    func bytes(in range: Range<Int>) -> ArraySlice<UInt8> {
    #if DEBUG
        precondition(range.lowerBound >= 0 && range.upperBound <= _bytes.count,
                     "Range \(range) out of bounds (count: \(_bytes.count))")
        return _bytes[range]
    #else
        guard range.lowerBound >= 0, range.upperBound <= _bytes.count else {
            log("Range \(range) out of bounds (count: \(_bytes.count))", from: self)
            return []
        }
        return _bytes[range]
    #endif
    }

    
    // MARK: - Scan utilities
    
    // 字句走査などについての関数群
    // 指定range内で最初に見つかった byte の index を返す。見つからなければ nil。
    func firstIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
        let slice = bytes(in: range)   // Debug: 範囲外ならここで落ちる / Release: 範囲外なら空
        if slice.isEmpty { return nil }

        for i in slice.indices {
            if _bytes[i] == byte { return i }
        }
        return nil
    }

    // 指定range内で最後に見つかった byte の index を返す。見つからなければ nil。
    func lastIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
        let slice = bytes(in: range)
        if slice.isEmpty { return nil }

        var i = slice.endIndex
        while i > slice.startIndex {
            i -= 1
            if _bytes[i] == byte { return i }
        }
        return nil
    }

    // range 内で needle が最初に出現する index を返す。見つからなければ nil。
    func firstIndex(ofSequence needle: [UInt8], in range: Range<Int>) -> Int? {
        if needle.isEmpty { return range.lowerBound }

        let slice = bytes(in: range)
        if slice.isEmpty { return nil }
        if slice.count < needle.count { return nil }

        let lastStart = slice.endIndex - needle.count
        var i = slice.startIndex
        while i <= lastStart {
            if matchesPrefix(needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    // range 内に needle が含まれるか
    func containsSubsequence(_ needle: [UInt8], in range: Range<Int>) -> Bool {
        firstIndex(ofSequence: needle, in: range) != nil
    }
    
    // 指定range内で、エスケープを考慮しつつ target に到達するまで走査し、到達したら「次」のインデックスを返す。
    // stop が指定されている場合、stop に到達したらその位置で止めて stop 自身のインデックスを返す。
    // 見つからなければ range.upperBound を返す。
    func skip(
        from startIndex: Int,
        in range: Range<Int>,
        target: UInt8,
        escape: UInt8? = FuncChar.backSlash,
        stop: UInt8? = nil
    ) -> Int {
        if startIndex >= range.upperBound { return range.upperBound }

        let slice = bytes(in: startIndex..<range.upperBound)
        if slice.isEmpty { return range.upperBound }

        var isEscaped = false

        var i = slice.startIndex
        while i < slice.endIndex {
            let b = _bytes[i]

            if let stop, b == stop {
                return i
            }

            if isEscaped {
                isEscaped = false
                i += 1
                continue
            }

            if let escape, b == escape {
                isEscaped = true
                i += 1
                continue
            }

            if b == target {
                return i + 1
            }

            i += 1
        }

        return range.upperBound
    }
    
    // index から upperBound まで、space / tab を読み飛ばした位置を返す（upperBound は含まない）
    func skipSpaces(from index: Int, to upperBound: Int) -> Int {
        if index >= upperBound { return index }

        let slice = bytes(in: index..<upperBound)
        if slice.isEmpty { return index }

        var i = slice.startIndex
        while i < slice.endIndex {
            let b = _bytes[i]
            if b != FuncChar.space && b != FuncChar.tab { return i }
            i += 1
        }
        return upperBound
    }

    // opener から始まる区切りリテラルをスキップし、閉じ区切りの「次」のインデックスを返す。
    // 見つからない場合は range.upperBound または stop に到達した位置を返す。
    //
    // - Parameters:
    //   - startIndex: opener の位置（opener 自身を指す）
    //   - range: 走査範囲
    //   - opener: 開始区切り
    //   - allowNesting: opener/closer のネストを許可するか（括弧系向け）
    //   - escape: エスケープ文字（0 を渡すと無効）
    //   - stop: 指定があれば、そのバイトに到達したらそこで止める（例：LF）
    func skipDelimited(
        from startIndex: Int,
        in range: Range<Int>,
        opener: UInt8,
        allowNesting: Bool,
        escape: UInt8? = FuncChar.backSlash,
        stop: UInt8? = nil
    ) -> Int {
        let closer = FuncChar.paired(of: opener) ?? opener
        let canNest = allowNesting && opener != closer
        
        if startIndex + 1 >= range.upperBound { return range.upperBound }
        
        let slice = bytes(in: (startIndex + 1)..<range.upperBound)
        if slice.isEmpty { return range.upperBound }
        
        var isEscaped = false
        
        if opener == closer {
            // opener == closer（例：" ' / など）: ネストなし、closer を見つけたら終了
            var i = slice.startIndex
            while i < slice.endIndex {
                let b = _bytes[i]
                
                if let stopByte = stop, b == stopByte {
                    return i
                }
                
                if isEscaped {
                    isEscaped = false
                    i += 1
                    continue
                }
                
                if let escape, b == escape {
                    isEscaped = true
                    i += 1
                    continue
                }
                
                if b == closer {
                    return i + 1
                }
                
                i += 1
            }
            
            return range.upperBound
        }
        
        // opener != closer（括弧系）
        var depth = 1
        
        var i = slice.startIndex
        while i < slice.endIndex {
            let b = _bytes[i]
            
            if let stopByte = stop, b == stopByte {
                return i
            }
            
            if isEscaped {
                isEscaped = false
                i += 1
                continue
            }
            
            if escape != 0 && b == escape {
                isEscaped = true
                i += 1
                continue
            }
            
            if canNest && b == opener {
                depth += 1
                i += 1
                continue
            }
            
            if b == closer {
                depth -= 1
                i += 1
                if depth == 0 { return i }
                continue
            }
            
            i += 1
        }
        
        return range.upperBound
    }
    
    // 1行内専用：LF に到達したら打ち切る版（内部的には skipDelimited を呼ぶだけ）
    func skipDelimitedInLine(from startIndex: Int, in range: Range<Int>, opener: UInt8,
            allowNesting: Bool, escape: UInt8 = FuncChar.backSlash) -> Int {
        skipDelimited(from: startIndex, in: range, opener: opener, allowNesting: allowNesting, escape: escape, stop: FuncChar.lf)
    }
    
    // quote（' や "）から始まるクォート文字列をスキップし、閉じクォートの「次」のインデックスを返す。
    // 見つからない場合は range.upperBound または stop に到達した位置を返す。
    func skipQuoted(from startIndex: Int, in range: Range<Int>, quote: UInt8,
            escape: UInt8 = FuncChar.backSlash, stop: UInt8? = nil) -> Int {
        skipDelimited(from: startIndex, in: range, opener: quote, allowNesting: false, escape: escape, stop: stop)
    }
    
    // 1行内専用：LF に到達したら打ち切る版
    func skipQuotedInLine(from startIndex: Int, in range: Range<Int>, quote: UInt8, escape: UInt8 = FuncChar.backSlash) -> Int {
        skipQuoted(from: startIndex, in: range, quote: quote, escape: escape, stop: FuncChar.lf)
    }

    // MARK: - Quote wrappers
    
    func skipSingleQuoted(from startIndex: Int, in range: Range<Int> ) -> Int {
        skipQuoted(from: startIndex, in: range, quote: FuncChar.singleQuote)
    }
    
    func skipDoubleQuoted(from startIndex: Int, in range: Range<Int>) -> Int {
        skipQuoted(from: startIndex, in: range, quote: FuncChar.doubleQuote)
    }
    
    func skipSingleQuotedInLine(from startIndex: Int, in range: Range<Int>) -> Int {
        skipQuotedInLine(from: startIndex, in: range, quote: FuncChar.singleQuote)
    }
    
    func skipDoubleQuotedInLine(from startIndex: Int, in range: Range<Int>) -> Int {
        skipQuotedInLine(from: startIndex, in: range, quote: FuncChar.doubleQuote)
    }

    
    //MARK: - Matching utilities
    
    // 渡されたwordがskeletonのrangeの文字列と一致するか否かを返す。
    func matches(word: [UInt8], in range:Range<Int>) -> Bool {
        let len = range.count
        if word.count != len { return false }
        if range.upperBound > count { log("out of range.", from:self); return false }
        
        return _bytes[range].elementsEqual(word)
    }
    
    // 渡されたwordのリストにskeletonのrangeの文字列と一致するものがあるか否かを返す。
    func matches(words:[[UInt8]], in range: Range<Int>) -> Bool {
        var lo = 0
        var hi = words.count

        while lo < hi {
            let mid = (lo + hi) >> 1
            let w = words[mid]

            //let cmp = compare(range: range, word: w)
            let cmp = compare(word: w, in: range)
            if cmp == 0 {
                return true
            } else if cmp < 0 {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return false
    }

    // index位置から word が前方一致するか否かを返す。
    func matchesPrefix(_ word: [UInt8], at index: Int) -> Bool {
        if word.isEmpty { return true }
        if index < 0 { return false }
        if index + word.count > _bytes.count { return false }

        var i = 0
        while i < word.count {
            if _bytes[index + i] != word[i] { return false }
            i += 1
        }
        return true
    }
    
    // return <0 : range < word
    //         0 : equal
    //        >0 : range > word
    private func compare(word: [UInt8], in range: Range<Int>) -> Int {
        let rlen = range.count
        let wlen = word.count
        let minLen = (rlen < wlen) ? rlen : wlen

        var i = 0
        while i < minLen {
            let a = _bytes[range.lowerBound + i]
            let b = word[i]
            if a != b {
                return Int(a) - Int(b)
            }
            i += 1
        }

        // prefix が一致している場合は長さで決定
        return rlen - wlen
    }
    
    // 指定された文字インデックスの含まれる物理行の行番号を返す。0開始。
    func lineIndex(at characterIndex: Int) -> Int {
        var lo = 0, hi = newlineIndices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if newlineIndices[mid] < characterIndex { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    
    // 指定された行インデックスの行のRangeを返す。末尾の改行を含まない。
    func lineRange(at lineIndex: Int) -> Range<Int> {
        let start: Int
        if lineIndex == 0 {
            start = 0
        } else {
            start = newlineIndices[lineIndex - 1] + 1
        }

        let end: Int
        if lineIndex < newlineIndices.count {
            end = newlineIndices[lineIndex]
        } else {
            end = bytes.count
        }

        return start..<end
    }
    
    // 指定されたLFの場所を返す。
    func newlineIndex(after lineIndex: Int) -> Int? {
        guard lineIndex < newlineIndices.count else { return nil }
        return newlineIndices[lineIndex]
    }
    
    // rangeで指定された領域を含む行の行頭から行末までを返す。末尾の改行を含まない。
    func lineRange(contains range: Range<Int>) -> Range<Int> {
        let startIndex = range.lowerBound
        let endIndex = (range.upperBound > startIndex) ? range.upperBound - 1 : startIndex

        let firstLine = lineIndex(at: startIndex)
        let lastLine  = lineIndex(at: endIndex)

        let start: Int
        if firstLine == 0 {
            start = 0
        } else {
            start = newlineIndices[firstLine - 1] + 1
        }

        let end: Int
        if lastLine < newlineIndices.count {
            end = newlineIndices[lastLine]
        } else {
            end = count
        }

        return start..<end
    }

}




