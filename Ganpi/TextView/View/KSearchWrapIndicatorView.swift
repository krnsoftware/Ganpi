//
//  KSearchWrapIndicatorView.swift
//
//  Ganpi - macOS Text Editor
//
//  Created by KARINO Masatsugu for Ganpi Project on 2026/05/12,
//  with architectural assistance by Sebastian, his loyal AI butler.
//  All rights reserved.
//

import Cocoa

final class KSearchWrapIndicatorView: NSView {

    private let _label = NSTextField(labelWithString: "")
    
    private let _displayDuration: TimeInterval = 0.45
    private let _fadeOutDuration: TimeInterval = 0.25

    init(symbol: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 96))

        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.darkGray.withAlphaComponent(0.55).cgColor

        _label.stringValue = symbol
        _label.font = NSFont.systemFont(ofSize: 52, weight: .regular)
        _label.textColor = .white
        _label.alignment = .center
        _label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(_label)

        NSLayoutConstraint.activate([
            _label.centerXAnchor.constraint(equalTo: centerXAnchor),
            _label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        alphaValue = 0.0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    func showAndFadeOut(completion: @escaping () -> Void) {
        alphaValue = 1.0
        needsDisplay = true
        displayIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + _displayDuration) { [weak self] in
            guard let self else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = self._fadeOutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)

                self.animator().alphaValue = 0.0
            } completionHandler: {
                completion()
            }
        }
    }
}
