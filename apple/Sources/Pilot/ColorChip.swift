import AppKit

/// Detects inline-code spans in a note whose *entire* content is a color in one
/// of the supported formats, so the editor can render a clickable swatch after
/// it. Supported: hex (`#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA`),
/// `rgb()` / `rgba()`, `oklch()`, and `cmyk()`.
enum ColorChip {
    struct Match {
        /// Range of the whole inline-code span, including the backticks.
        let range: NSRange
        /// The color text, trimmed (e.g. `#00FF3F`) — what we copy on click.
        let value: String
        /// Resolved color for the swatch.
        let color: NSColor
    }

    private static let inlineCode = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)

    /// Every inline-code span whose sole content is a recognized color, or
    /// only those within `range` (which should start and end on line
    /// boundaries) when one is given.
    static func matches(in string: String, range: NSRange? = nil) -> [Match] {
        let ns = string as NSString
        var result: [Match] = []
        inlineCode.enumerateMatches(
            in: string,
            options: range == nil ? [] : [.withTransparentBounds, .withoutAnchoringBounds],
            range: range ?? NSRange(location: 0, length: ns.length)
        ) { m, _, _ in
            guard let m else { return }
            let trimmed = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let color = parse(trimmed) else { return }
            result.append(Match(range: m.range, value: trimmed, color: color))
        }
        return result
    }

    /// Parses a color string. Returns nil if it isn't one of the supported formats.
    static func parse(_ raw: String) -> NSColor? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { return parseHex(s) }
        switch s.lowercased() {
        case let v where v.hasPrefix("rgb"): return parseRGB(s)
        case let v where v.hasPrefix("oklch"): return parseOKLCH(s)
        case let v where v.hasPrefix("cmyk"): return parseCMYK(s)
        default: return nil
        }
    }

    // MARK: - Parsers

    private static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }

    /// The comma/space/slash-separated arguments inside `name(...)`.
    private static func args(_ s: String) -> [String]? {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        return s[s.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseHex(_ s: String) -> NSColor? {
        let hex = Array(s.dropFirst())
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        func pair(_ slice: ArraySlice<Character>) -> CGFloat { CGFloat(Int(String(slice), radix: 16) ?? 0) / 255 }
        func dup(_ c: Character) -> CGFloat { CGFloat(Int(String([c, c]), radix: 16) ?? 0) / 255 }
        switch hex.count {
        case 3: return NSColor(srgbRed: dup(hex[0]), green: dup(hex[1]), blue: dup(hex[2]), alpha: 1)
        case 4: return NSColor(srgbRed: dup(hex[0]), green: dup(hex[1]), blue: dup(hex[2]), alpha: dup(hex[3]))
        case 6: return NSColor(srgbRed: pair(hex[0..<2]), green: pair(hex[2..<4]), blue: pair(hex[4..<6]), alpha: 1)
        case 8: return NSColor(srgbRed: pair(hex[0..<2]), green: pair(hex[2..<4]), blue: pair(hex[4..<6]), alpha: pair(hex[6..<8]))
        default: return nil
        }
    }

    private static func parseRGB(_ s: String) -> NSColor? {
        guard let parts = args(s), parts.count >= 3 else { return nil }
        func chan(_ p: String) -> CGFloat? {
            if p.hasSuffix("%") { return Double(p.dropLast()).map { CGFloat($0 / 100) } }
            return Double(p).map { CGFloat($0 / 255) }
        }
        guard let r = chan(parts[0]), let g = chan(parts[1]), let b = chan(parts[2]) else { return nil }
        var a: CGFloat = 1
        if parts.count >= 4 {
            let p = parts[3]
            a = p.hasSuffix("%") ? CGFloat((Double(p.dropLast()) ?? 100) / 100) : CGFloat(Double(p) ?? 1)
        }
        return NSColor(srgbRed: clamp(r), green: clamp(g), blue: clamp(b), alpha: clamp(a))
    }

    private static func parseCMYK(_ s: String) -> NSColor? {
        guard let parts = args(s), parts.count == 4 else { return nil }
        func pct(_ p: String) -> CGFloat? {
            Double(p.hasSuffix("%") ? String(p.dropLast()) : p).map { CGFloat($0 / 100) }
        }
        guard let c = pct(parts[0]), let m = pct(parts[1]), let y = pct(parts[2]), let k = pct(parts[3]) else { return nil }
        return NSColor(srgbRed: clamp((1 - c) * (1 - k)),
                       green: clamp((1 - m) * (1 - k)),
                       blue: clamp((1 - y) * (1 - k)),
                       alpha: 1)
    }

    private static func parseOKLCH(_ s: String) -> NSColor? {
        guard let parts = args(s), parts.count >= 3 else { return nil }
        func num(_ p: String) -> Double? {
            var t = p
            if t.hasSuffix("deg") { t = String(t.dropLast(3)) }
            if t.hasSuffix("%") { return Double(t.dropLast()).map { $0 / 100 } }
            return Double(t)
        }
        guard var L = num(parts[0]), let C = num(parts[1]), let H = num(parts[2]) else { return nil }
        if L > 1 { L /= 100 }   // accept "86.8" as well as "86.8%"
        let alpha = parts.count >= 4 ? CGFloat(num(parts[3]) ?? 1) : 1

        // OKLCH -> OKLab -> linear sRGB -> gamma-encoded sRGB.
        let hr = H * .pi / 180
        let a = C * cos(hr), b = C * sin(hr)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, sc = s_ * s_ * s_
        func gamma(_ c: Double) -> Double {
            let x = max(0, c)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        let r = gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * sc)
        let g = gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * sc)
        let bl = gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * sc)
        return NSColor(srgbRed: clamp(CGFloat(r)), green: clamp(CGFloat(g)), blue: clamp(CGFloat(bl)), alpha: clamp(alpha))
    }
}
