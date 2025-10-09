//
//  KTextView+Actions.swift
//  Ganpi
//
//  Created by KARINO Masatugu on 2025/08/15.
//

import AppKit
import CryptoKit

extension KTextView {
    
    // MARK: - Search actions
    
    @IBAction func setSearchStringWithSelectedString(_ sender: Any?) {
        if selectionRange.isEmpty { NSSound.beep(); return }
        KSearchPanel.shared.searchString = String( textStorage[selectionRange] ?? [])
    }
    
    @IBAction func searchNextAction(_ sender: Any?) {
        KSearchPanel.shared.close()
        search(for: .forward)
    }
    
    @IBAction func searchPrevAction(_ sender: Any?) {
        search(for: .backward)
    }
    
    @IBAction func replaceAllAction(_ sender: Any?) {
        replaceAll()
    }
    
    @IBAction func replaceAction(_ sender: Any?) {
        replace()
    }
    
    @IBAction func replaceAndFindeAgainAction(_ sender: Any?) {
        replace()
        search(for: .forward)
    }
    
    
    
    // MARK: - Undo actions
    
    @IBAction func undo(_ sender: Any?) {
        textStorage.undo()
    }
    
    @IBAction func redo(_ sender: Any?) {
        textStorage.redo()
    }
    
    
    // MARK: - Indent Shift.
    
    @IBAction func shiftLeft(_ sender: Any?) {
        shiftIndentedString(direction: .backward)
    }
    
    @IBAction func shiftRight(_ sender: Any?) {
        shiftIndentedString(direction: .forward)
    }
    
    // 行頭インデントを左/右シフト（tabはtabWidth換算でspace化）
    private func shiftIndentedString(direction: KDirection) {
        guard let range = textStorage.lineRange(in: selectionRange) else { log("out of range.", from: self); return }
        if range.isEmpty { return }

        let skeleton = textStorage.skeletonString
        let tabWidth = layoutManager.tabWidth

        var headSpaces = 0         // 見た目幅（tabはtabWidth換算）
        var headChars  = 0         // 実際に行頭で消費した“文字数”
        var lineStart  = range.lowerBound
        var inHead     = true
        var repArray: [String] = []

        for i in range {
            let ch = skeleton[i]

            if inHead, ch == FuncChar.tab {
                headSpaces += tabWidth
                headChars  += 1
                continue
            } else if inHead, ch == FuncChar.space {
                headSpaces += 1
                headChars  += 1
                continue
            } else if ch == FuncChar.lf {
                // 本文は“行頭インデントの文字数”をスキップして切り出す
                let contentStart = lineStart + headChars
                let newWidth = max(headSpaces + tabWidth * direction.rawValue, 0)
                let header = String(repeating: " ", count: newWidth)
                repArray.append(header + textStorage.string(in: contentStart..<i))

                // 次の行の初期化
                lineStart  = i + 1
                headSpaces = 0
                headChars  = 0
                inHead     = true
                continue
            }

            if inHead {
                // はじめて非インデント文字に到達
                inHead = false
            }
        }

        // 最終行（改行で終わらない行）
        let contentStart = lineStart + headChars
        let newWidth = max(headSpaces + tabWidth * direction.rawValue, 0)
        let header = String(repeating: " ", count: newWidth)
        repArray.append(header + textStorage.string(in: contentStart..<range.upperBound))

        // ドキュメントの改行コードで結合（LF固定にしない）
        let res = repArray.joined(separator: "\n")

        textStorage.replaceString(in: range, with: res)
        selectionRange = range.lowerBound ..< (range.lowerBound + res.count)
    }
    
    // MARK: - Move Line Up / Down
    
    @IBAction func moveLineUp(_ sender: Any?) {
        moveLineVertically(direction: .backward)
    }
    
    @IBAction func moveLineDown(_ sender: Any?) {
        moveLineVertically(direction: .forward)
    }
    
    private func moveLineVertically(direction: KDirection) {
        guard let range = textStorage.lineRange(in: selectionRange) else { log("out of range.", from: self); return }
        if range.isEmpty { return }
        if direction == .backward && range.lowerBound == 0 { return }
        if direction == .forward && range.upperBound == textStorage.count { return }

        var rangeA:Range<Int>
        var rangeB:Range<Int>
        var newSelectionRange:Range<Int>
        switch direction {
        case .backward:
            guard let lineRange = textStorage.lineRange(at: range.lowerBound - 1) else { return }
            rangeA = lineRange
            rangeB = range
            newSelectionRange = rangeA.lowerBound..<rangeA.lowerBound + range.count
        case .forward:
            guard let lineRange = textStorage.lineRange(at: range.upperBound + 1) else { return }
            rangeA = range
            rangeB = lineRange
            newSelectionRange = rangeA.lowerBound + rangeB.count + 1..<rangeB.upperBound
        }
        let newString = textStorage.string(in:rangeB) + "\n" + textStorage.string(in: rangeA)
        textStorage.replaceString(in: rangeA.lowerBound..<rangeB.upperBound, with: newString)
        selectionRange = newSelectionRange
    }
    
    
    // MARK: - Sort Lines
    
    
    @IBAction func sortLines(_ sender: Any?) {
        //sortSelectedLines(caseInsensitive: false, numeric: false, descending: false)
        sortSelectedLines()
    }
    
    @IBAction func sortSelectedLines_AscT_CaseT_NumT(_ sender: Any?) {
        sortSelectedLines(options: [.caseInsensitive, .numeric], ascending: true)
    }
    @IBAction func sortSelectedLines_AscT_CaseT_NumN(_ sender: Any?) {
        sortSelectedLines(options: [.caseInsensitive], ascending: true)
    }
    @IBAction func sortSelectedLines_AscT_CaseN_NumT(_ sender: Any?) {
        sortSelectedLines(options: [.numeric], ascending: true)
    }
    @IBAction func sortSelectedLines_AscT_CaseN_NumN(_ sender: Any?) {
        sortSelectedLines(options: [], ascending: true)
    }
    @IBAction func sortSelectedLines_AscN_CaseT_NumT(_ sender: Any?) {
        sortSelectedLines(options: [.caseInsensitive, .numeric], ascending: false)
    }
    @IBAction func sortSelectedLines_AscN_CaseT_NumN(_ sender: Any?) {
        sortSelectedLines(options: [.caseInsensitive], ascending: false)
    }
    @IBAction func sortSelectedLines_AscN_CaseN_NumT(_ sender: Any?) {
        sortSelectedLines(options: [.numeric], ascending: false)
    }
    @IBAction func sortSelectedLines_AscN_CaseN_NumN(_ sender: Any?) {
        sortSelectedLines(options: [], ascending: false)
    }
    
    func sortSelectedLines(options: String.CompareOptions = [], ascending: Bool = true) {
        let snapshot = textStorage.snapshot
        let sel = selectionRange

        guard var paraRange = snapshot.paragraphRange(containing: sel),
              !paraRange.isEmpty else { return }

        // 全文選択で末尾LFがあるなら、空段落を含める
        if sel.lowerBound == 0, sel.upperBound == textStorage.count,
           let last = snapshot.paragraphs.last, last.range.isEmpty {
            paraRange = paraRange.lowerBound ..< (paraRange.upperBound + 1)
        }

        var lines: [String] = []
        lines.reserveCapacity(paraRange.count)
        for i in paraRange { lines.append(snapshot.paragraphs[i].string) }

        let locale = Locale.current
        lines.sort {
            let cmp = $0.compare($1, options: options, range: nil, locale: locale)
            return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }

        let lower = snapshot.paragraphs[paraRange.lowerBound].range.lowerBound
        let upper = snapshot.paragraphs[paraRange.upperBound - 1].range.upperBound
        let replaceRange = lower..<upper

        let newBlock = lines.joined(separator: "\n")
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }
    
    /*
    func sortSelectedLines(options: String.CompareOptions = [], ascending: Bool = true) {
        let snapshot = textStorage.snapshot
        let selection = selectionRange
        guard let paraRange = snapshot.paragraphRange(containing: selection),
              !paraRange.isEmpty else { return }

        var lines: [String] = []
        for i in paraRange {
            lines.append(snapshot.paragraphs[i].string)
        }
        
        let locale = Locale.current
        lines.sort {
            let cmp = $0.compare($1,
                                 options: options,
                                 range: nil,
                                 locale: locale)
            return ascending
                ? (cmp == .orderedAscending)
                : (cmp == .orderedDescending)
        }

        let lower = snapshot.paragraphs[paraRange.lowerBound].range.lowerBound
        let upper = snapshot.paragraphs[paraRange.upperBound - 1].range.upperBound
        let replaceRange = lower..<upper

        let newBlock = lines.joined(separator: "\n")
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }*/
    
    
    // MARK: - Unique Lines
    
    /// 先勝ち：最初の出現を残して重複行を削除
        @IBAction func uniqueLinesKeepFirst(_ sender: Any?) {
            uniqueSelectedLines(keepLast: false)
        }

        /// 後勝ち：最後の出現を残して重複行を削除
        @IBAction func uniqueLinesKeepLast(_ sender: Any?) {
            uniqueSelectedLines(keepLast: true)
        }

        /// 選択範囲にかかる段落の重複を削除する（順序は維持）
        /// - Parameter keepLast: true で最後の出現を残す（後勝ち）、false で最初（先勝ち）
    func uniqueSelectedLines(keepLast: Bool) {
        let snapshot = textStorage.snapshot
        let sel = selectionRange
        
        // 空選択は全文対象／それ以外は選択にかかる段落範囲
        let paraRange: Range<Int>
        if sel.isEmpty {
            paraRange = 0 ..< snapshot.paragraphs.count
        } else {
            guard let r = snapshot.paragraphRange(containing: sel), !r.isEmpty else { return }
            paraRange = r
        }
        
        // 範囲キー（ゼロコピー）でユニーク化
        var seen = Set<TextRangeRef>()
        var keptRanges: [Range<Int>] = []
        keptRanges.reserveCapacity(paraRange.count)
        
        if keepLast {
            // 後勝ち：逆順に走査して新規だけを前詰め
            for idx in paraRange.reversed() {
                let pr = snapshot.paragraphs[idx].range
                let key = TextRangeRef(storage: textStorage, range: pr)
                if seen.insert(key).inserted {
                    keptRanges.insert(pr, at: 0)
                }
            }
        } else {
            // 先勝ち：通常順に走査して新規だけを追加
            for idx in paraRange {
                let pr = snapshot.paragraphs[idx].range
                let key = TextRangeRef(storage: textStorage, range: pr)
                if seen.insert(key).inserted {
                    keptRanges.append(pr)
                }
            }
        }
        
        // 置換範囲（文字範囲）を構成
        let lower = snapshot.paragraphs[paraRange.lowerBound].range.lowerBound
        let upper = snapshot.paragraphs[paraRange.upperBound - 1].range.upperBound
        let replaceRange = lower ..< upper
        
        // 最後にだけ文字列化（コピーはここ1回）
        // paragraph.string は末尾LFを含まない想定なので "\n" で結合
        var parts: [String] = []
        parts.reserveCapacity(keptRanges.count)
        for r in keptRanges {
            parts.append(textStorage.string(in: r))
        }
        let newBlock = parts.joined(separator: "\n")
        
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }
    
    
    // MARK: - Color treatment
    
    // Show Color Panel.
    // If you press down a option key in calling this function, show alpha value.
    @IBAction func showColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        let selection = selectionRange
        //let string = textStorage[string: selection]
        let string = textStorage.string(in: selection)
        let isOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        panel.showsAlpha = isOption ? true : false
        
        if  let color = NSColor(hexString: string) {
            panel.color = color
        }
        
        panel.isContinuous = true
        panel.orderFront(self)
    }
    
    // insert the color string to selection. Basically #RRGGBB, if show panel.showAlpha, #RRGGBBAA.
    @IBAction func changeColor(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { log("sender is not NSColorPanel.", from:self); return }
        guard let string = panel.color.toHexString(includeAlpha: panel.showsAlpha) else { log("string is nil.", from:self); return }
        //guard let storage = textStorage as? KTextStorageProtocol else { log("textstorage is not writable.", from:self); return }

        let selection = selectionRange
        textStorage.replaceString(in: selection, with: string)
        selectionRange = selection.lowerBound..<selection.lowerBound + string.count
    }
    
    // MARK: - Unicode Normalization.
    
    @IBAction func doNFC(_ sender: Any?) {
        selectedString = selectedString.precomposedStringWithCanonicalMapping
    }
    
    @IBAction func doNFKC(_ sender: Any?) {
        selectedString = selectedString.precomposedStringWithCompatibilityMapping
    }
    
    // MARK: - Surround Selection.
    
    @IBAction func surroundSelectionWithDoubleQuote(_ sender: Any?) {
        surroundSelection(left: "\"", right: "\"")
    }
    
    @IBAction func surroundSelectionWithSingleQuote(_ sender: Any?) {
        surroundSelection(left: "'", right: "'")
    }
    
    @IBAction func surroundSelectionWithParen(_ sender: Any?) {
        surroundSelection(left:"(", right:")")
    }
    
    @IBAction func surroundSelectionWithBlacket(_ sender: Any?) {
        surroundSelection(left:"[", right:"]")
    }
    
    @IBAction func surroundSelectionWithBrace(_ sender: Any?) {
        surroundSelection(left:"{", right:"}")
    }
    
    private func surroundSelection(left:String, right:String) {
        selectedString = left + selectedString + right
    }
    
    // MARK: - URL Encode/Decode
    
    @IBAction func urlEncode(_ sender: Any?) {
        if let encoded = selectedString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            selectedString = encoded
            return
        }
        NSSound.beep()
    }
    
    @IBAction func urlDecode(_ sender: Any?) {
        if let encoded = selectedString.removingPercentEncoding {
            selectedString = encoded
            return
        }
        NSSound.beep()
    }
    
    // MARK: - Base64 Encode/Decode
    
    @IBAction func base64Encode(_ sender: Any?) {
        if let data = selectedString.data(using: .utf8) {
            selectedString = data.base64EncodedString()
            return
        }
        NSSound.beep()
    }
    
    @IBAction func base64Decode(_ sender: Any?) {
        if let data = Data(base64Encoded: selectedString),
           let decoded = String(data: data, encoding: .utf8) {
            selectedString = decoded
            return
        }
        NSSound.beep()
    }
    
    // MARK: - Hiragana <-> Katakana
    
    @IBAction func hiraganaToKatakana(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.hiraganaToKatakana, reverse: false) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    @IBAction func katakanaToHiragana(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.hiraganaToKatakana, reverse: true) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    @IBAction func fullWidthToHalfWidth(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.fullwidthToHalfwidth, reverse: false) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    @IBAction func halfWidthToFullWidth(_ sender: Any?) {
        if let string = selectedString.applyingTransform(.fullwidthToHalfwidth, reverse: true) {
            selectedString = string
            return
        }
        NSSound.beep()
    }
    
    //MARK: - Encrypt.
    
    @IBAction func rot13(_ sender: Any?) {
        let text = selectedString
        let transform: (Character) -> Character = {
            guard let ascii = $0.asciiValue else { return $0 }
            switch ascii {
            case 65...90:  return Character(UnicodeScalar(65 + (ascii - 65 + 13) % 26))
            case 97...122: return Character(UnicodeScalar(97 + (ascii - 97 + 13) % 26))
            default:       return $0
            }
        }
        selectedString = String(text.map(transform))
    }
    
    
    @IBAction func sha256(_ sender: Any?) {
        let text = selectedString
        guard let data = text.data(using: .utf8) else { log("data is nil.", from:self); return }
        
        let digest = SHA256.hash(data: data)
        selectedString = digest.compactMap { String(format: "%02x", $0)}.joined()
    }
    
    // 文字列の MD5(UTF-8) を 16進小文字で返す
    @IBAction func md5Hex(_ sender: Any?) {
        let data = Data(selectedString.utf8)
        let digest = Insecure.MD5.hash(data: data)
        selectedString = digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // 文字列の MD5(UTF-8) を Base64 で返す
    @IBAction func md5Base64(_ sender: Any?) {
        let data = Data(selectedString.utf8)
        let digest = Insecure.MD5.hash(data: data)
        selectedString = Data(digest).base64EncodedString()
    }
    
    
    
     
}
