//
//  KTimeChecker.swift
//  KEdit
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Foundation

final class KTimeChecker {

    // MARK: - Static Utility
    
    @discardableResult
    static func measure<T>(name: String, block: () -> T) -> T {
        let start = DispatchTime.now()
        let result = block()
        let end = DispatchTime.now()
        let elapsed = elapsedTime(from: start, to: end)
        print(String(format: "[%@] elapsed: %.3f ms", name, elapsed))
        return result
    }
    
    // MARK: - Instance-based Timer

    private let _name: String
    private var _startTime: DispatchTime
    private var _message: String = ""

    init(name: String = "") {
        _name = name
        _startTime = DispatchTime.now()
    }

    func start(message: String = "") {
        _message = message
        _startTime = DispatchTime.now()
    }

    func stop() {
        let end = DispatchTime.now()
        let elapsed = Self.elapsedTime(from: _startTime, to: end)
        print(String(format: "[%@:%@] elapsed: %.3f ms", _name, _message, elapsed))
    }
    
    func stopAndGo(message: String = "") {
        stop()
        start(message: message)
    }
    
    private static func elapsedTime(from: DispatchTime, to: DispatchTime) -> Double {
        return Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000.0
    }
}
