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
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        print(String(format: "[%@] elapsed: %.3f ms", name, elapsed))
        return result
    }
    
    // MARK: - Instance-based Timer

    private let name: String
    private var startTime: DispatchTime?

    init(name: String) {
        self.name = name
    }

    func start() {
        startTime = DispatchTime.now()
    }

    func stop() {
        guard let start = startTime else {
            print("[\(name)] Error: start() must be called before stop()")
            return
        }
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        print(String(format: "[%@] elapsed: %.3f ms", name, elapsed))
    }
}
