import Foundation

enum Units {
    /// Stable decimal precision for machine-readable depth labels.
    static func decimal(_ value: Double) -> String {
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// Format inches as exact fractional inches (to 1/64) or millimetres.
    static func format(_ inches: Double, metric: Bool) -> String {
        guard inches.isFinite, abs(inches) < Double(Int.max / 32) else { return "Invalid" }
        if metric { return decimal(inches * 25.4) + " mm" }
        let sign = inches < 0 ? "-" : ""
        let x = abs(inches)
        var whole = Int(x.rounded(.down))
        let sixteenths = (x - Double(whole)) * 64
        let r = sixteenths.rounded()
        if abs(sixteenths - r) > 1e-6 { return sign + decimal(x) + "\"" }
        var num = Int(r)
        if num == 64 { whole += 1; num = 0 }
        var den = 64
        while num > 0 && num % 2 == 0 { num /= 2; den /= 2 }
        if num == 0 { return "\(sign)\(whole)\"" }
        if whole == 0 { return "\(sign)\(num)/\(den)\"" }
        return "\(sign)\(whole) \(num)/\(den)\""
    }

    /// Parse `3 1/2`, `3-1/2"`, `3.5`, `1/4`, `2' 3`, `90mm`, `9cm`. Bare numbers are mm when `bareIsMM`.
    static func parse(_ raw: String, bareIsMM: Bool = false) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        var scale = 1.0
        if s.hasSuffix("mm") { scale = 1 / 25.4; s.removeLast(2) }
        else if s.hasSuffix("cm") { scale = 10 / 25.4; s.removeLast(2) }
        else if s.hasSuffix("in") { s.removeLast(2) }
        else if bareIsMM && !s.contains("\"") && !s.contains("'") { scale = 1 / 25.4 }
        s = s.replacingOccurrences(of: "\"", with: "")
        var total = 0.0
        var found = false
        if let q = s.firstIndex(of: "'") {
            guard let ft = Double(s[s.startIndex..<q].trimmingCharacters(in: .whitespaces)) else { return nil }
            total += ft * 12
            found = true
            s = String(s[s.index(after: q)...])
        }
        for t in s.split(whereSeparator: { $0 == " " || $0 == "-" }) {
            found = true
            if t.contains("/") {
                let p = t.split(separator: "/")
                guard p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d != 0 else { return nil }
                total += n / d
            } else {
                guard let v = Double(t) else { return nil }
                total += v
            }
        }
        guard found else { return nil }
        let result = (negative ? -total : total) * scale
        return result.isFinite ? result : nil
    }
}
