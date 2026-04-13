//
//  KApplicationState.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/04/13,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



import Foundation

final class KApplicationState {
    
    static let shared = KApplicationState()
    
    var sortLinesAscending: Bool = true
    var sortLinesCaseSensitive: Bool = false
    var sortLinesNumeric: Bool = false
    
    private init() {
        loadFromPreference()
    }
    
    func loadFromPreference() {
        let prefs = KPreference.shared
        
        sortLinesAscending = prefs.bool(.editorSortLinesAscending)
        sortLinesCaseSensitive = prefs.bool(.editorSortLinesCasesensitive)
        sortLinesNumeric = prefs.bool(.editorSortLinesNumeric)
    }
}
