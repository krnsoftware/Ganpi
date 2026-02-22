import AppKit

extension NSAttributedString {

    /// 先頭 N 文字の attributes を要約して文字列で返す（log() 用）
    func debugAttributeSummary(firstN: Int = 1) -> String {
        if length == 0 { return "NSAttributedString: (empty)" }

        let n = max(1, min(firstN, length))
        let headString = String(string.prefix(n))

        var lines: [String] = []
        lines.append("NSAttributedString(len=\(length)) head=\"\(headString)\"")

        for i in 0..<n {
            let ch = String(string[string.index(string.startIndex, offsetBy: i)])
            let attrs = attributes(at: i, effectiveRange: nil)

            lines.append(" [\(i)] '\(ch)' attrs=\(attrs.count)")

            for key in attrs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let value = attrs[key] as Any
                lines.append("   \(key.rawValue): \(Self._debugValueString(value))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 指定 range の attributes runs（effectiveRange）を列挙して要約文字列で返す
    func debugAttributeRunsSummary(in range: NSRange? = nil, limitRuns: Int = 20) -> String {
        if length == 0 { return "NSAttributedString: (empty)" }

        let target = range ?? NSRange(location: 0, length: length)
        let clamped = NSIntersectionRange(target, NSRange(location: 0, length: length))
        if clamped.length <= 0 { return "NSAttributedString: (range empty)" }

        var lines: [String] = []
        lines.append("NSAttributedString(len=\(length)) runs in \(clamped.location)..<\(clamped.location + clamped.length)")

        var runCount = 0
        enumerateAttributes(in: clamped, options: []) { attrs, r, stop in
            runCount += 1
            if runCount > limitRuns { stop.pointee = true; return }

            let snippet = Self._safeSubstring(self.string, nsRange: r, maxLen: 20)
            lines.append(" run[\(runCount)] range=\(r.location)..<\(r.location + r.length) text=\"\(snippet)\" attrs=\(attrs.count)")

            for key in attrs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let value = attrs[key] as Any
                lines.append("   \(key.rawValue): \(Self._debugValueString(value))")
            }
        }

        if runCount > limitRuns {
            lines.append(" (truncated: over \(limitRuns) runs)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func _debugValueString(_ value: Any) -> String {
        if let c = value as? NSColor {
            // そのまま出すと長いので、可能ならRGBに落として出す
            if let rgb = c.usingColorSpace(.deviceRGB) {
                let r = String(format: "%.3f", rgb.redComponent)
                let g = String(format: "%.3f", rgb.greenComponent)
                let b = String(format: "%.3f", rgb.blueComponent)
                let a = String(format: "%.3f", rgb.alphaComponent)
                return "NSColor(r=\(r), g=\(g), b=\(b), a=\(a))"
            }
            return "NSColor(\(c))"
        }

        if let f = value as? NSFont {
            return "NSFont(\(f.fontName), \(String(format: "%.1f", f.pointSize)))"
        }

        if let n = value as? NSNumber {
            return "NSNumber(\(n))"
        }

        if let s = value as? NSString {
            let t = String(s)
            let head = t.prefix(80)
            return "String(\"\(head)\(t.count > 80 ? "…" : "")\")"
        }

        if let p = value as? NSParagraphStyle {
            return "NSParagraphStyle(lineBreak=\(p.lineBreakMode.rawValue), align=\(p.alignment.rawValue))"
        }

        return "\(type(of: value))"
    }

    private static func _safeSubstring(_ s: String, nsRange: NSRange, maxLen: Int) -> String {
        guard let r = Range(nsRange, in: s) else { return "" }
        let sub = String(s[r])
        let head = sub.prefix(maxLen)
        return "\(head)\(sub.count > maxLen ? "…" : "")"
    }
}