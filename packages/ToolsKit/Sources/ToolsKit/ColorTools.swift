// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The color and design-token tool (PLAN.md §11.2): hex colors, WCAG contrast, tokens in our own
/// `tokens.json` format, and the dominant colors of an image.
public enum ColorTools {
    public struct RGB: Sendable, Hashable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

        /// "#RGB", "#RRGGBB" or "#RRGGBBAA".
        public init?(hex: String) {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
            guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
            let has = s.count == 8
            r = Double((v >> (has ? 24 : 16)) & 0xff) / 255
            g = Double((v >> (has ? 16 : 8)) & 0xff) / 255
            b = Double((v >> (has ? 8 : 0)) & 0xff) / 255
            a = has ? Double(v & 0xff) / 255 : 1
        }

        public var hex: String {
            let c = [r, g, b].map { Int(($0 * 255).rounded()) }
            return String(format: "#%02X%02X%02X", c[0], c[1], c[2]) + (a < 1 ? String(format: "%02X", Int((a * 255).rounded())) : "")
        }

        /// WCAG relative luminance.
        public var luminance: Double {
            func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        /// This color drawn over an opaque background.
        public func over(_ background: RGB) -> RGB {
            RGB(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a))
        }
    }

    /// WCAG 2.x contrast ratio of a foreground (blended over the background if translucent).
    public static func contrast(_ foreground: RGB, _ background: RGB) -> Double {
        let f = foreground.over(background).luminance, b = background.luminance
        return (max(f, b) + 0.05) / (min(f, b) + 0.05)
    }

    public struct Rating: Sendable, Equatable {
        public let ratio: Double
        public var aaNormal: Bool { ratio >= 4.5 }
        public var aaLarge: Bool { ratio >= 3 }
        public var aaaNormal: Bool { ratio >= 7 }
        public var aaaLarge: Bool { ratio >= 4.5 }
        public var summary: String {
            String(format: "%.2f:1 ", ratio) + (aaaNormal ? "AAA" : aaNormal ? "AA" : aaLarge ? "AA large text only" : "fails WCAG AA")
        }
    }

    public static func rate(_ foreground: RGB, on background: RGB) -> Rating { Rating(ratio: contrast(foreground, background)) }

    // MARK: Tokens

    public struct Token: Sendable, Hashable, Identifiable {
        public var id: String { path }
        /// "dark.text.primary"
        public let path: String
        public let hex: String
        public var theme: String { String(path.split(separator: ".").first ?? "") }
        public var group: String { path.split(separator: ".").dropFirst().first.map(String.init) ?? "" }
        public var name: String { path.split(separator: ".").dropFirst(2).joined(separator: ".") }
    }

    /// Color tokens from a `tokens.json` (`themes.<theme>.<group>.<name>` hex strings).
    public static func tokens(_ json: String) -> [Token] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let themes = object["themes"] as? [String: Any] else { return [] }
        var out: [Token] = []
        func walk(_ value: Any, _ path: [String]) {
            if let d = value as? [String: Any] { for k in d.keys.sorted() { walk(d[k]!, path + [k]) } }
            else if let s = value as? String, RGB(hex: s) != nil { out.append(Token(path: path.joined(separator: "."), hex: s)) }
        }
        for theme in themes.keys.sorted() { walk(themes[theme]!, [theme]) }
        return out
    }

    /// Text tokens that don't reach WCAG AA (4.5:1) on the theme's surfaces.
    public static func contrastProblems(_ tokens: [Token]) -> [(text: Token, surface: Token, rating: Rating)] {
        var out: [(Token, Token, Rating)] = []
        for theme in Set(tokens.map(\.theme)).sorted() {
            let text = tokens.filter { $0.theme == theme && $0.group == "text" }
            let surfaces = tokens.filter { $0.theme == theme && $0.group == "surface" && ["editor", "pane", "chrome", "raised"].contains($0.name) }
            for t in text {
                for s in surfaces {
                    guard let fg = RGB(hex: t.hex), let bg = RGB(hex: s.hex) else { continue }
                    let rating = rate(fg, on: bg)
                    if !rating.aaNormal { out.append((t, s, rating)) }
                }
            }
        }
        return out
    }

    /// Changes one token's value in the file's text, leaving the rest of it as it was.
    public static func setting(_ path: String, to hex: String, in json: String) -> String? {
        var index = json.startIndex
        let parts = path.split(separator: ".").map(String.init)
        guard let themes = json.range(of: "\"themes\"") else { return nil }
        index = themes.upperBound
        for (i, part) in parts.enumerated() {
            guard let key = json.range(of: "\"\(part)\"", range: index..<json.endIndex) else { return nil }
            index = key.upperBound
            if i == parts.count - 1 {
                guard let value = json[index...].firstMatch(of: /^\s*:\s*"(#[0-9A-Fa-f]{3,8})"/) else { return nil }
                return json.replacingCharacters(in: value.1.startIndex..<value.1.endIndex, with: hex)
            }
        }
        return nil
    }

    // MARK: Swatches from an image

    /// The most common colors in RGBA8 pixels, as k-means centers (deterministic start), most
    /// frequent first. Transparent pixels are ignored.
    public static func dominantColors(rgba pixels: [UInt8], count: Int = 6) -> [RGB] {
        var points: [(Double, Double, Double)] = []
        var i = 0
        while i + 3 < pixels.count {
            if pixels[i + 3] > 127 { points.append((Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)) }
            i += 4
        }
        guard !points.isEmpty else { return [] }
        let k = min(count, points.count)
        // Start from points spread through the image order.
        var centers = (0..<k).map { points[$0 * points.count / k] }
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<12 {
            for (n, p) in points.enumerated() {
                var best = 0, bestD = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = pow(p.0 - center.0, 2) + pow(p.1 - center.1, 2) + pow(p.2 - center.2, 2)
                    if d < bestD { bestD = d; best = c }
                }
                assignment[n] = best
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
            for (n, p) in points.enumerated() {
                let c = assignment[n]
                sums[c] = (sums[c].0 + p.0, sums[c].1 + p.1, sums[c].2 + p.2, sums[c].3 + 1)
            }
            for c in 0..<k where sums[c].3 > 0 { centers[c] = (sums[c].0 / Double(sums[c].3), sums[c].1 / Double(sums[c].3), sums[c].2 / Double(sums[c].3)) }
        }
        var sizes = [Int](repeating: 0, count: k)
        for a in assignment { sizes[a] += 1 }
        let order = (0..<k).filter { sizes[$0] > 0 }.sorted { sizes[$0] > sizes[$1] }
        var out: [RGB] = []
        for c in order {
            let color = RGB(r: centers[c].0, g: centers[c].1, b: centers[c].2)
            // Merge near-duplicates.
            if !out.contains(where: { abs($0.r - color.r) + abs($0.g - color.g) + abs($0.b - color.b) < 0.06 }) { out.append(color) }
        }
        return out
    }
}
