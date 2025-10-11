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
    
    
    // MARK: - Delete Lines / Duplicate Lines
    
    @IBAction func deleteLines(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        guard let indexRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !indexRange.isEmpty else { log("1", from: self); return }

        // 段落本体の文字範囲（[lower, upper)）
        var deleteRange = snapshot.paragraphRange(indexRange: indexRange)

        // 最終段落を含まない場合は、後続の改行（1文字）も一緒に削除して繰り上げる
        if indexRange.upperBound < snapshot.paragraphs.count {
            if deleteRange.upperBound < textStorage.count {
                deleteRange = deleteRange.lowerBound ..< (deleteRange.upperBound + 1)
            }
        }

        textStorage.replaceString(in: deleteRange, with: "")
        // 削除開始位置にキャレットを置く
        selectionRange = deleteRange.lowerBound ..< deleteRange.lowerBound
    }
    
    @IBAction func duplicateLines(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        guard let indexRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !indexRange.isEmpty else { log("1", from: self); return }

        // 対象段落の文字範囲と内容（段落はLFを含まない仕様）
        let totalRange = snapshot.paragraphRange(indexRange: indexRange)
        let block = textStorage.string(in: totalRange)

        // 直下に複製する：挿入位置は対象ブロックの末尾
        let insertPosition = totalRange.upperBound
        let insertString = "\n" + block

        textStorage.replaceString(in: insertPosition..<insertPosition, with: insertString)

        // 複製された行群（先頭の改行は除外）を新たに選択
        let newStart = insertPosition + 1
        let newEnd = newStart + block.count
        selectionRange = newStart..<newEnd
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

        guard var paraRange = snapshot.paragraphIndexRange(containing: sel),
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
    
    // 先勝ち：最初の出現を残して重複行を削除
    @IBAction func uniqueLinesKeepFirst(_ sender: Any?) {
        uniqueSelectedLines(keepLast: false)
    }

    // 後勝ち：最後の出現を残して重複行を削除
    @IBAction func uniqueLinesKeepLast(_ sender: Any?) {
        uniqueSelectedLines(keepLast: true)
    }

    // 選択範囲にかかる段落の重複を削除する（順序は維持）
    // - Parameter keepLast: true で最後の出現を残す（後勝ち）、false で最初（先勝ち）
    func uniqueSelectedLines(keepLast: Bool) {
        let snapshot = textStorage.snapshot
        let sel = selectionRange
        
        // 空選択は全文対象／それ以外は選択にかかる段落範囲
        let paraRange: Range<Int>
        if sel.isEmpty {
            paraRange = 0 ..< snapshot.paragraphs.count
        } else {
            guard let r = snapshot.paragraphIndexRange(containing: sel), !r.isEmpty else { return }
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
        var parts: [String] = []
        parts.reserveCapacity(keptRanges.count)
        for r in keptRanges {
            parts.append(textStorage.string(in: r))
        }
        let newBlock = parts.joined(separator: "\n")
        
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }
    
    
    // MARK: - Join Lines
    
    @IBAction func joinLines(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        let idxRange: Range<Int>

        if selectionRange.isEmpty {
            idxRange = 0..<snapshot.paragraphs.count
        } else {
            guard let r = snapshot.paragraphIndexRange(containing: selectionRange),
                  !r.isEmpty else { return }
            idxRange = r
        }
        if idxRange.count <= 1 { return }

        let totalRange = snapshot.paragraphRange(indexRange: idxRange)

        var parts: [String] = []
        parts.reserveCapacity(idxRange.count)
        for i in idxRange {
            parts.append(snapshot.paragraphs[i].string)
        }
        let joined = parts.joined()

        textStorage.replaceString(in: totalRange, with: joined)
        selectionRange = totalRange.lowerBound ..< (totalRange.lowerBound + joined.count)
        
    }
    
    
    // MARK: - Trim Lines
    
    @IBAction func trimTrailingSpaces(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        let sel = selectionRange

        // 対象段落を決定
        guard let idxRange = snapshot.paragraphIndexRange(containing: sel) else {
            log("idx nil",from:self)
            return
        }
           

        // 各段落を末尾トリム
        var resultLines: [String] = []
        resultLines.reserveCapacity(idxRange.count)

        for i in idxRange {
            let para = snapshot.paragraphs[i]
            if para.range.isEmpty {
                // 空行はそのまま
                resultLines.append("")
                continue
            }

            // 末尾の空白とタブを削除
            let s = para.string
            let trimmed = s.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            resultLines.append(trimmed)
        }

        // 置換範囲を確定
        let totalRange = snapshot.paragraphRange(indexRange: idxRange)
        let newBlock = resultLines.joined(separator: "\n")

        textStorage.replaceString(in: totalRange, with: newBlock)
        selectionRange = totalRange.lowerBound ..< (totalRange.lowerBound + newBlock.count)
    }
    
    
    // MARK: - Collapse Empty Lines / Remove Empty Lines
    
    @IBAction func collapseEmptyLines(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        guard let idxRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !idxRange.isEmpty else { return }

        var result: [String] = []
        result.reserveCapacity(idxRange.count)
        var prevEmpty = false

        for i in idxRange {
            let p = snapshot.paragraphs[i]
            if p.range.isEmpty {
                if !prevEmpty { result.append("") }   // 連続空行を1行に圧縮
                prevEmpty = true
            } else {
                result.append(p.string)
                prevEmpty = false
            }
        }

        let total = snapshot.paragraphRange(indexRange: idxRange)
        var newBlock = result.joined(separator: "\n")

        // 末尾まで選択が届いており、最後が空行なら LF を1つ保持
        if idxRange.upperBound == snapshot.paragraphs.count, result.last == "" {
            newBlock.append("\n")
        }

        textStorage.replaceString(in: total, with: newBlock)
        selectionRange = total.lowerBound ..< (total.lowerBound + newBlock.count)
    }
    
    @IBAction func removeEmptyLines(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        guard let indexRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !indexRange.isEmpty else {
            log("1", from: self)
            return
        }

        var result: [String] = []
        result.reserveCapacity(indexRange.count)

        for i in indexRange {
            let paragraph = snapshot.paragraphs[i]
            // 空行でなければ残す（Collapseの逆）
            if !paragraph.range.isEmpty {
                result.append(paragraph.string)
            }
        }

        let totalRange = snapshot.paragraphRange(indexRange: indexRange)
        var newBlock = result.joined(separator: "\n")

        // 文末まで選択されている場合は、末尾LFを調整（必要なら付ける）
        if indexRange.upperBound == snapshot.paragraphs.count {
            newBlock.append("\n")
        }

        textStorage.replaceString(in: totalRange, with: newBlock)
        selectionRange = totalRange.lowerBound ..< (totalRange.lowerBound + newBlock.count)
    }
    
    // MARK: - Comment
    
    @IBAction func toggleLineComment(_ sender: Any?) {
        let snapshot = textStorage.snapshot
        guard let indexRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !indexRange.isEmpty else { log("1", from: self); return }
        guard let head = textStorage.parser.lineCommentPrefix, !head.isEmpty else { log("2", from: self); return }

        // 対象段落を取得
        var lines: [String] = []
        lines.reserveCapacity(indexRange.count)
        for i in indexRange {
            lines.append(snapshot.paragraphs[i].string)
        }

        // 非空行がすべてコメント済みなら「解除」、そうでなければ「付与」
        let headWithSpace = head + " "
        let isCommentedLine: (String) -> Bool = { line in
            guard !line.isEmpty else { return false }
            return line.hasPrefix(headWithSpace) || line.hasPrefix(head)
        }
        let nonEmpty = lines.filter { !$0.isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy(isCommentedLine)

        var result: [String] = []
        result.reserveCapacity(lines.count)

        if allCommented {
            // 解除：行頭の head を外し、続く 1 スペースがあれば外す
            for line in lines {
                guard !line.isEmpty else { result.append(""); continue }
                if line.hasPrefix(headWithSpace) {
                    let start = headWithSpace.count
                    result.append(String(line.dropFirst(start)))
                } else if line.hasPrefix(head) {
                    let afterHead = line.index(line.startIndex, offsetBy: head.count)
                    // 直後のスペースは 1 つだけ落とす
                    if afterHead < line.endIndex, line[afterHead] == " " {
                        result.append(String(line.dropFirst(head.count + 1)))
                    } else {
                        result.append(String(line.dropFirst(head.count)))
                    }
                } else {
                    result.append(line)
                }
            }
        } else {
            // 付与：非空行の行頭に head+" " を追加（空行はそのまま）
            for line in lines {
                if line.isEmpty {
                    result.append("")
                } else {
                    result.append(headWithSpace + line)
                }
            }
        }

        // 一括置換（Undo 1 回）
        let replaceRange = snapshot.paragraphRange(indexRange: indexRange)
        let newBlock = result.joined(separator: "\n")
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }
    
    
    // MARK: - Reflow Paragraph (column wrap by display width)

    @IBAction func reflowParagraph72(_ sender: Any?) { reflowSelectedParagraphs(columnLimit: 72) }
    @IBAction func reflowParagraph80(_ sender: Any?) { reflowSelectedParagraphs(columnLimit: 80) }
    @IBAction func reflowParagraph100(_ sender: Any?) { reflowSelectedParagraphs(columnLimit: 100) }

    /// 選択中の段落ブロックを Reflow（幅指定で折り直し）
    /// - columnLimit: 列の上限（72/80/100 など）
    /// - tabWidth: タブ幅（Ganpi 既定に合わせる）
    private func reflowSelectedParagraphs(columnLimit: Int, tabWidth: Int = 8) {
        let snapshot = textStorage.snapshot
        guard let indexRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !indexRange.isEmpty else { log("1", from: self); return }
        
        // 段落ブロック全体の置換範囲（[lower, upper)）
        let replaceRange = snapshot.paragraphRange(indexRange: indexRange)
        
        // 「空行で段落を区切る」：非空行の塊ごとに reflow し、空行はそのまま出力
        var outLines: [String] = []
        outLines.reserveCapacity(indexRange.count)
        
        var buffer = "" // 非空行の塊を 1 行（英語: 空白1で連結 / 日本語: そのまま連結）に畳む
        for i in indexRange {
            let para = snapshot.paragraphs[i]
            if para.range.isEmpty {
                // 空行に遭遇：直前の塊をフラッシュして空行を出力
                if !buffer.isEmpty {
                    outLines.append(contentsOf: wrapToColumns(buffer, limit: columnLimit, tabWidth: tabWidth))
                    buffer.removeAll(keepingCapacity: true)
                }
                outLines.append("")
            } else {
                let s = para.string
                if buffer.isEmpty {
                    buffer = normalizeWhitespaces(s)
                } else {
                    // 英語は空白 1 で接続、日本語は normalizeWhitespaces 内で空白が潰れるため結果は自然
                    buffer += " " + normalizeWhitespaces(s)
                }
            }
        }
        // 末尾に塊が残っていればフラッシュ
        if !buffer.isEmpty {
            outLines.append(contentsOf: wrapToColumns(buffer, limit: columnLimit, tabWidth: tabWidth))
        }
        
        let newBlock = outLines.joined(separator: "\n")
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }


    /// 与えられたテキストを列幅で折り直す。
    /// CJK（ひらがな/カタカナ/漢字）を含む場合は CJK モード＝文字幅のみで改行（空白挿入なし）
    private func wrapToColumns(_ text: String, limit: Int, tabWidth: Int) -> [String] {
        let containsCJK = text.contains { $0._jpScript != nil }
        if containsCJK {
            return wrapCJKToColumns(text, limit: limit)
        } else {
            return wrapLatinToColumns(text, limit: limit, tabWidth: tabWidth)
        }
    }

    /// 英語（空白区切り）用：トークン単位で折り返し。トークン間には半角スペース 1 を入れる。
    /// 長大トークン（URLなど）は行頭にそのまま置いてはみ出し許容。
    private func wrapLatinToColumns(_ text: String, limit: Int, tabWidth: Int) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(max(1, text.count / max(1, limit)))
        
        var line = ""
        var col = 0
        
        var i = text.startIndex
        while i < text.endIndex {
            // 先頭空白（space/tab）は正規化済みだが念のため読み飛ばし
            while i < text.endIndex, text[i] == " " || text[i] == "\t" {
                i = text.index(after: i)
            }
            if i >= text.endIndex { break }
            
            // 非空白トークン抽出
            let start = i
            while i < text.endIndex, text[i] != " " && text[i] != "\t" {
                i = text.index(after: i)
            }
            let token = text[start..<i]
            let tokenCols = token.displayColumns(startColumn: 0, tabWidth: tabWidth)
            
            if line.isEmpty {
                // 行頭：そのまま置く（はみ出し許容）
                line = String(token)
                col = tokenCols
            } else if col + 1 + tokenCols <= limit {
                line.append(" ")
                line.append(contentsOf: token)
                col += 1 + tokenCols
            } else {
                lines.append(line)
                line = String(token)
                col = tokenCols
            }
        }
        
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// 日本語（CJK）用：文字幅の合計で折り返し。結合記号は幅 0。空白は挿入しない。
    // ASCII の「語っぽい」文字（英数と一部記号）だけを true にする
    private func isAsciiWordChar(_ ch: Character) -> Bool {
        guard ch.isAllASCII else { return false }
        switch ch {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-", ".", "/", ":":
            return true
        default:
            return false
        }
    }

    /// 日本語（CJK）用：文字幅の合計で折り返しつつ、ASCII の語連続は1トークンとして扱う
    private func wrapCJKToColumns(_ text: String, limit: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        var col = 0

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]

            // 1) ASCII の語連続をまとめて1トークンにする
            if isAsciiWordChar(ch) {
                let start = i
                var j = text.index(after: i)
                while j < text.endIndex, isAsciiWordChar(text[j]) {
                    j = text.index(after: j)
                }
                let token = text[start..<j]
                let w = token.displayColumns(startColumn: 0, tabWidth: 8) // タブは来ない想定だが念のため

                if col + w > limit, !line.isEmpty {
                    lines.append(line)
                    line.removeAll(keepingCapacity: true)
                    col = 0
                }
                line.append(contentsOf: token)
                col += w
                i = j
                continue
            }

            // 2) それ以外は1文字ずつ扱う（CJK/絵文字/句読点など）
            if ch == "\n" { // 念のため無視（段落単位で来る想定）
                i = text.index(after: i)
                continue
            }
            let w = ch.displayWidth
            if col + w > limit, !line.isEmpty {
                lines.append(line)
                line.removeAll(keepingCapacity: true)
                col = 0
            }
            line.append(ch)
            col += w
            i = text.index(after: i)
        }

        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// 連続空白（space/tab）を単一スペースに正規化（LF は Ganpi 仕様で来ない前提）
    private func normalizeWhitespaces(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var wasSpace = false
        for ch in s {
            if ch == " " || ch == "\t" {
                if !wasSpace {
                    out.append(" ")
                    wasSpace = true
                }
            } else {
                out.append(ch)
                wasSpace = false
            }
        }
        return out
    }
    
    
    // MARK: - Align Assignment (=, :)
    
    @IBAction func alignAssignmentEquals(_ sender: Any?) { alignOperator("=") }
    @IBAction func alignAssignmentColons(_ sender: Any?) { alignOperator(":") }

    private func alignOperator(_ symbol: Character) {
        let snapshot = textStorage.snapshot
        guard let indexRange = snapshot.paragraphIndexRange(containing: selectionRange),
              !indexRange.isEmpty else { log("1", from: self); return }
        
        let tabWidth = layoutManager.tabWidth
        
        // 1) 左側の見かけカラムの最大値を測る
        var leftWidths: [Int?] = Array(repeating: nil, count: indexRange.count)
        var maxLeft = 0
        
        for (offset, i) in indexRange.enumerated() {
            let line = snapshot.paragraphs[i].string
            guard let opIdx = line.firstIndex(of: symbol) else { continue }
            
            let leftRaw = line[..<opIdx]
            let leftTrimmed = trimTrailingSpacesTabs(leftRaw)     // ← ここが変更点
            let w = leftTrimmed.displayColumns(startColumn: 0, tabWidth: tabWidth)
            leftWidths[offset] = w
            if w > maxLeft { maxLeft = w }
        }
        
        if !leftWidths.contains(where: { $0 != nil }) { return }
        
        // 2) 行を再構成
        var out: [String] = []
        out.reserveCapacity(indexRange.count)
        
        for (offset, i) in indexRange.enumerated() {
            let line = snapshot.paragraphs[i].string

            // 記号なし行 or 計測対象外はそのまま
            if line.firstIndex(of: symbol) == nil || leftWidths[offset] == nil {
                out.append(line)
                continue
            }

            // ここから整形
            let opIdx = line.firstIndex(of: symbol)!        // 上で nil を弾いているので安全
            let leftRaw  = line[..<opIdx]
            let rightRaw = line[line.index(after: opIdx)...]

            let leftTrimmed  = trimTrailingSpacesTabs(leftRaw)
            let rightTrimmed = trimLeadingSpacesTabs(rightRaw)

            let currentLeftCols = leftTrimmed.displayColumns(startColumn: 0, tabWidth: layoutManager.tabWidth)

            // “演算子の前に最低1スペース” を確保して整列
            let minLeftGap = 1
            let targetOpCol = maxLeft + minLeftGap
            let padSpaces = max(0, targetOpCol - currentLeftCols)

            var newLine = String(leftTrimmed)
            if padSpaces > 0 { newLine += String(repeating: " ", count: padSpaces) }
            newLine.append(symbol)
            newLine.append(" ")
            newLine.append(contentsOf: rightTrimmed)

            out.append(newLine)
        }
        
        // 3) 一括置換
        let replaceRange = snapshot.paragraphRange(indexRange: indexRange)
        let newBlock = out.joined(separator: "\n")
        textStorage.replaceString(in: replaceRange, with: newBlock)
        selectionRange = replaceRange.lowerBound ..< (replaceRange.lowerBound + newBlock.count)
    }

        // MARK: - 小さなトリム関数（Substringを返す）

    private func trimTrailingSpacesTabs(_ s: Substring) -> Substring {
        var end = s.endIndex
        while end > s.startIndex {
            let p = s.index(before: end)
            let ch = s[p]
            if ch == " " || ch == "\t" {
                end = p
            } else {
                break
            }
        }
        return s[..<end]
    }

    private func trimLeadingSpacesTabs(_ s: Substring) -> Substring {
        var i = s.startIndex
        while i < s.endIndex, (s[i] == " " || s[i] == "\t") {
            i = s.index(after: i)
        }
        return s[i...]
    }
    
    // MARK: - Color treatment
    
    // Show Color Panel.
    // If you press down a option key in calling this function, show alpha value.
    @IBAction func showColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        let selection = selectionRange
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
