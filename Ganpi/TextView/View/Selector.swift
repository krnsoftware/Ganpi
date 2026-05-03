//
//  Selector.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2025/10/29,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Foundation

extension Selector {
    var isVerticalAction: Bool {
        return self == #selector(KTextView.moveUp(_:)) ||
        self == #selector(KTextView.moveDown(_:)) ||
        self == #selector(KTextView.moveUpAndModifySelection(_:)) ||
        self == #selector(KTextView.moveDownAndModifySelection(_:)) ||
        self == #selector(KTextView.pageUp(_:)) ||
        self == #selector(KTextView.pageDown(_:))// ||
        //self == #selector(KTextView.pageUpAndModifySelection(_:)) ||
        //self == #selector(KTextView.pageDownAndModifySelection(_:))
    }
    
    var isVerticalActionWithModifierSelection: Bool {
        return self == #selector(KTextView.moveUpAndModifySelection(_:)) ||
        self == #selector(KTextView.moveDownAndModifySelection(_:))// ||
        //self == #selector(KTextView.pageUpAndModifySelection(_:)) ||
        //self == #selector(KTextView.pageDownAndModifySelection(_:))
    }
    
    var isHorizontalAction: Bool {
        return self == #selector(KTextView.moveLeft(_:)) ||
        self == #selector(KTextView.moveRight(_:)) ||
        self == #selector(KTextView.moveLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordLeft(_:)) ||
        self == #selector(KTextView.moveWordRight(_:)) ||
        self == #selector(KTextView.moveWordProximalLeft(_:)) ||
        self == #selector(KTextView.moveWordProximalRight(_:)) ||
        self == #selector(KTextView.moveWordProximalLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordProximalRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenLeft(_:)) ||
        self == #selector(KTextView.moveTokenRight(_:)) ||
        self == #selector(KTextView.moveTokenLeft(_:)) ||
        self == #selector(KTextView.moveTokenRight(_:)) ||
        self == #selector(KTextView.moveTokenLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenProximalLeft(_:)) ||
        self == #selector(KTextView.moveTokenProximalRight(_:)) ||
        self == #selector(KTextView.moveTokenProximalLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenProximalRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfLine(_:)) ||
        self == #selector(KTextView.moveToEndOfLine(_:)) ||
        self == #selector(KTextView.moveToBeginningOfLineAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfLineAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfParagraph(_:)) ||
        self == #selector(KTextView.moveToEndOfParagraph(_:)) ||
        self == #selector(KTextView.moveToBeginningOfParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfDocument(_:)) ||
        self == #selector(KTextView.moveToEndOfDocument(_:)) ||
        self == #selector(KTextView.moveToBeginningOfDocumentAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfDocumentAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToFirstPrintableCharacterInParagraph(_:)) ||
        self == #selector(KTextView.moveToFirstPrintableCharacterInParagraphAndModifySelection(_:))
    }
    
    var isHorizontalActionWithModifierSelection: Bool {
        return self == #selector(KTextView.moveLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordProximalLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordProximalRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenProximalLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveTokenProximalRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfLineAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfLineAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfDocumentAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfDocumentAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToFirstPrintableCharacterInParagraphAndModifySelection(_:))
    }
    
    var isYankFamilyAction: Bool {
        return self == #selector(KTextView.yank(_:)) ||
        self == #selector(KTextView.yankPop(_:)) ||
        self == #selector(KTextView.yankPopReverse(_:)) ||
        self == #selector(KTextView.paste(_:))
    }
    
    var isDeleteAction: Bool {
        return self == #selector(KTextView.deleteBackward(_:)) ||
        self == #selector(KTextView.deleteForward(_:)) ||
        self == #selector(KTextView.deleteWordBackward(_:)) ||
        self == #selector(KTextView.deleteWordForward(_:)) ||
        self == #selector(KTextView.deleteToBeginningOfLine(_:)) ||
        self == #selector(KTextView.deleteToEndOfLine(_:)) ||
        self == #selector(KTextView.deleteToBeginningOfParagraph(_:)) ||
        self == #selector(KTextView.deleteToEndOfParagraph(_:))
    }
    
    var isModifySelectionAction: Bool {
        return self == #selector(KTextView.moveUpAndModifySelection(_:)) ||
        self == #selector(KTextView.moveDownAndModifySelection(_:)) ||
        //self == #selector(KTextView.pageUpAndModifySelection(_:)) ||
        //self == #selector(KTextView.pageDownAndModifySelection(_:)) ||
        self == #selector(KTextView.moveLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordLeftAndModifySelection(_:)) ||
        self == #selector(KTextView.moveWordRightAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfLineAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfLineAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToBeginningOfDocumentAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToEndOfDocumentAndModifySelection(_:)) ||
        self == #selector(KTextView.moveToFirstPrintableCharacterInParagraph(_:)) ||
        self == #selector(KTextView.moveToFirstPrintableCharacterInParagraphAndModifySelection(_:)) ||
        self == #selector(KTextView.selectWord(_:)) ||
        self == #selector(KTextView.selectLine(_:)) ||
        self == #selector(KTextView.selectParagraph(_:)) ||
        self == #selector(KTextView.selectAll(_:))
    }
    
    var isCopyPasteAction: Bool {
        return self == #selector(KTextView.yank(_:)) ||
        self == #selector(KTextView.cut(_:)) ||
        self == #selector(KTextView.copy(_:)) ||
        self == #selector(KTextView.paste(_:))
    }
    
    var isCapitalizeAction: Bool {
        return self == #selector(KTextView.transpose(_:)) ||
        self == #selector(KTextView.capitalizeWord(_:)) ||
        self == #selector(KTextView.lowercaseWord(_:)) ||
        self == #selector(KTextView.uppercaseWord(_:))
    }
    
    var isRecordable: Bool {
        return self.isDeleteAction ||
        self.isModifySelectionAction ||
        self.isCopyPasteAction ||
        self.isCapitalizeAction
    }
}
