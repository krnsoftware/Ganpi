//
//  KLogger.swift
//  Ganpi
//
//  Created by KARINO Masatugu,
//  with architectural assistance by Sebastian, his loyal AI butler.
//

import Foundation

#if DEBUG

/// クラスインスタンスからログ出力（例: log("msg", from: self)）
func log(_ message: String,
         from object: AnyObject,
         function: String = #function,
         file: String = #fileID,
         line: Int = #line) {
    let className = String(describing: type(of: object))
    //print("[\(className)::\(function) @\(file):\(line)] \(message)")
    print("[\(className)::\(function)] \(message)")
}

/// 型からのログ出力（例: log("msg", from: MyClass.self)）
func log<T>(_ message: String,
            from type: T.Type,
            function: String = #function,
            file: String = #fileID,
            line: Int = #line) {
    let className = String(describing: type)
    print("[\(className)::\(function) @\(file):\(line)] \(message)")
}

/// 単純なログ出力（ファイル名 + 関数名付き）
func log(_ message: String,
         function: String = #function,
         file: String = #fileID,
         line: Int = #line) {
    print("[\(file):\(line)] \(function): \(message)")
}

#else

// DEBUGビルドでない場合はすべて無効
func log(_ message: String, from object: AnyObject,
         function: String = #function, file: String = #fileID, line: Int = #line) {}
func log<T>(_ message: String, from type: T.Type,
            function: String = #function, file: String = #fileID, line: Int = #line) {}
func log(_ message: String,
         function: String = #function, file: String = #fileID, line: Int = #line) {}

#endif
