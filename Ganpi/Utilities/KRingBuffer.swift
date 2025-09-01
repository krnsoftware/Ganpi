//
//  KRingBuffer.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Foundation

// 追加した<Element>を最後に追加したものから順にindexで取得するためのバッファ。
// Undoシステム用に設計されているが、単純に2回程度のバッファリングにも使用できる程度に軽い。
// 指定したindexに<Element>がない場合はnilが返される。

struct KRingBuffer<Element> {
    private let _capacity: Int
    private var _buffer: [Element?]
    private var _nextIndex: Int = 0
    private var _count: Int = 0

    init(capacity: Int) {
        precondition(capacity >= 1, "Capacity must be at least 1")
        _capacity = capacity
        _buffer = Array<Element?>(repeating: nil, count: capacity)
    }

    var count: Int {
        return _count
    }

    var capacity: Int {
        return _capacity
    }

    mutating func append(_ element: Element) {
        _buffer[_nextIndex] = element
        _nextIndex = (_nextIndex + 1) % _capacity
        if _count < _capacity {
            _count += 1
        }
    }

    func element(at index: Int) -> Element? {
        guard index >= 0 && index < _count else {
            return nil
        }
        let realIndex = (_nextIndex - index - 1 + _capacity) % _capacity
        return _buffer[realIndex]
    }

    mutating func removeNewerThan(index: Int) {
        precondition(index >= 0, "Index must be non-negative")
        guard index < _count else { return }

        let removeCount = _count - index
        for i in 0..<removeCount {
            let realIndex = (_nextIndex - 1 - i + _capacity) % _capacity
            _buffer[realIndex] = nil
        }
        _count = index
        _nextIndex = (_nextIndex - removeCount + _capacity) % _capacity
    }

    mutating func reset() {
        _buffer = Array<Element?>(repeating: nil, count: _capacity)
        _nextIndex = 0
        _count = 0
    }
}
