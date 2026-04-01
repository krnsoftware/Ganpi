//
//  KEditMenuDelegate.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/04/01,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//



import AppKit

// Editメニューに自動的に追加されるWriting ToolsメニューとAutoFillメニューを削除するためのdelegateクラス。
// いずれもTextView側に対応する実装がなければ動作しないため、メニューを削除するのみとする。

final class KEditMenuDelegate: NSObject, NSMenuDelegate {

    private let _removingMenuTitles: Set<String> = [
        "Writing Tools",
        "AutoFill"
    ]

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeUnwantedItems(from: menu)
        removeRedundantSeparators(from: menu)
    }

    private func removeUnwantedItems(from menu: NSMenu) {
        let removingItems = menu.items.filter { item in
            _removingMenuTitles.contains(item.title)
        }

        for item in removingItems {
            menu.removeItem(item)
        }
    }

    private func removeRedundantSeparators(from menu: NSMenu) {
        while let firstItem = menu.items.first, firstItem.isSeparatorItem {
            menu.removeItem(firstItem)
        }

        while let lastItem = menu.items.last, lastItem.isSeparatorItem {
            menu.removeItem(lastItem)
        }

        var index = menu.items.count - 1
        while index > 0 {
            let currentItem = menu.items[index]
            let previousItem = menu.items[index - 1]

            if currentItem.isSeparatorItem && previousItem.isSeparatorItem {
                menu.removeItem(currentItem)
            }

            index -= 1
        }
    }
}
