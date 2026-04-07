//
//  KJumpHistory.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/04/08,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Foundation

final class KJumpHistory {
    
    private let _textStorageRef: KTextStorageProtocol
        private var _backwardBuffer: KRingBuffer<Int> = .init(capacity: 16)
        private var _forwardBuffer: KRingBuffer<Int> = .init(capacity: 16)
        
        private let _minimumJumpLineDistance: Int = 10
        private let _omitNearLineDistance: Int = 2
        
        private var _isNavigating: Bool = false
        
        init(textStorageRef: KTextStorageProtocol) {
            _textStorageRef = textStorageRef
        }
    
    func recordJumpIfNeeded(from oldIndex: Int, to newIndex: Int) {
        guard !_isNavigating else { return }
        guard oldIndex != newIndex else { return }
        
        let oldLineIndex = lineIndex(at: oldIndex)
        let newLineIndex = lineIndex(at: newIndex)
        guard abs(newLineIndex - oldLineIndex) >= _minimumJumpLineDistance else { return }
        
        if shouldOmit(index: oldIndex) {
            return
        }
        
        _forwardBuffer.reset()
        _backwardBuffer.append(oldIndex)
    }
    
    func jumpBackward(from currentIndex: Int) -> Int? {
        guard let targetIndex = _backwardBuffer.element(at: 0) else { return nil }
        
        _backwardBuffer.discardLatest(1)
        _forwardBuffer.append(currentIndex)
        _isNavigating = true
        
        return targetIndex
    }
    
    func jumpForward(from currentIndex: Int) -> Int? {
        guard let targetIndex = _forwardBuffer.element(at: 0) else { return nil }
        
        _forwardBuffer.discardLatest(1)
        _backwardBuffer.append(currentIndex)
        _isNavigating = true
        
        return targetIndex
    }
    
    func finishNavigation() {
        _isNavigating = false
    }
    
    func adjust(for info: KStorageModifiedInfo) {
        _backwardBuffer = adjustedBuffer(_backwardBuffer, for: info)
        _forwardBuffer = adjustedBuffer(_forwardBuffer, for: info)
    }
    
    func reset() {
        _backwardBuffer.reset()
        _forwardBuffer.reset()
        _isNavigating = false
    }
    
    private func shouldOmit(index: Int) -> Bool {
        guard let latestIndex = _backwardBuffer.element(at: 0) else { return false }
        let latestLineIndex = lineIndex(at: latestIndex)
        let newLineIndex = lineIndex(at: index)
        return abs(newLineIndex - latestLineIndex) <= _omitNearLineDistance
    }
    
    private func adjustedBuffer(_ buffer: KRingBuffer<Int>, for info: KStorageModifiedInfo) -> KRingBuffer<Int> {
            let adjusted = elementsNewestFirst(in: buffer).map {
                adjust(index: $0, for: info)
            }
            
            return makeBuffer(fromNewestFirst: adjusted, capacity: buffer.capacity)
        }
    
    private func adjust(index: Int, for info: KStorageModifiedInfo) -> Int {
        let delta = info.insertedCount - info.range.count
        
        if index < info.range.lowerBound {
            return index
        } else if index > info.range.upperBound {
            return index + delta
        } else {
            return info.range.lowerBound
        }
    }
    
    private func lineIndex(at index: Int) -> Int {
        let clampedIndex = max(0, min(index, _textStorageRef.count))
        return _textStorageRef.skeletonString.lineIndex(at: clampedIndex)
    }
    
    private func elementsNewestFirst(in buffer: KRingBuffer<Int>) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(buffer.count)
        
        for i in 0..<buffer.count {
            if let element = buffer.element(at: i) {
                result.append(element)
            }
        }
        
        return result
    }
    
    private func makeBuffer(fromNewestFirst elements: [Int], capacity: Int) -> KRingBuffer<Int> {
        var buffer = KRingBuffer<Int>(capacity: capacity)
        
        let suffix = elements.suffix(capacity)
        for element in suffix.reversed() {
            buffer.append(element)
        }
        
        return buffer
    }
}
