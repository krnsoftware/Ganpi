//
//  KLine.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//
// 表示される行1行を表すクラス。ソフトラップの場合はハードラップの行が複数に分割されて見た目のままの行配列になる。

import Cocoa

final class KLine {
    private weak var _layoutManager: KLayoutManager?
    private var _ctLine: CTLine?
    private var _obsolete: Bool = false
    
    let range: Range<Int>
    let hardLineIndex: Int
    let softLineIndex: Int
    
    // キャッシュされているCTLineを返す。
    // attributeが変更された場合、表示は無効だがサイズなどは有効のため古いキャッシュをそのまま利用する。
    private var _cachedCTLine: CTLine? {
        if _ctLine == nil {
            _obsolete = false
            makeCTLine()
        }
        return _ctLine
    }
    
    // 有効なCTLineを返す。
    var ctLine: CTLine? {
        if _ctLine == nil || _obsolete {
            _obsolete = false
            //print("\(#function): KLine. build CTLine. hardLineIndex:\(hardLineIndex), softLineIndex:\(softLineIndex)")
            makeCTLine()
        }
        return _ctLine
    }
    
    // 行の幅をCGFloatで返す。
    var width: CGFloat {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return 0.0 }
        
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
    
    init(range: Range<Int>, hardLineIndex: Int, softLineIndex: Int, layoutManager: KLayoutManager){
        self.range = range
        self.hardLineIndex = hardLineIndex
        self.softLineIndex = softLineIndex
        self._layoutManager = layoutManager
    }
    
    func attributesChanged(){
        _obsolete = true
    }
    
    func charactersChanged(){
        _ctLine = nil
    }
    
    // この行における文字のオフセットを行の左端を0.0とした相対座標のx位置のリストで返す。
    func characterOffsets() -> [CGFloat] {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return [] }
        
        let stringRange = CTLineGetStringRange(line)
        let start = stringRange.location
        let length = stringRange.length
        var offsets: [CGFloat] = []
        
        for i in start..<(start + length) {
            let offset = CTLineGetOffsetForStringIndex(line, i, nil)
            offsets.append(offset)
        }
        return offsets
    }
    
    // この行におけるindex文字目の相対位置を返す。
    func characterOffset(at index:Int) -> CGFloat {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return 0.0 }
        
        return CTLineGetOffsetForStringIndex(line, index, nil)
    }
    
    // この行における相対座標のx位置を返す。
    func characterIndex(at x: CGFloat) -> Int {
        guard let line = _cachedCTLine else { print("\(#function): _cachedCTLine is nil"); return 0 }
        
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        
        return index < 0 ? 0 : index // 空行の場合に-1が返るため、その場合は0を返す。
    }
    
    // この行のCTLineを作成する。作成はlayoutManagerに依頼する。
    private func makeCTLine(){
        guard let line = _layoutManager?.ctLine(in: range) else {
            print("\(#function): faild to generate CTLine for range ");
            return
        }
        _ctLine = line
    }
    
    
    
    
}


final class KLines {
    private var _lines: [KLine] = []
    private weak var _layoutManagerRef: KLayoutManagerReadable?
    private weak var _textStorageRef: KTextStorageReadable?
    
    init(layoutManagerRef: KLayoutManagerReadable?, textStorageRef: KTextStorageReadable?) {
        _layoutManagerRef = layoutManagerRef
        _textStorageRef = textStorageRef
        
        constructLines()
    }
    
    private func constructLines(range: Range<Int>? = nil) {
        
    }
}
