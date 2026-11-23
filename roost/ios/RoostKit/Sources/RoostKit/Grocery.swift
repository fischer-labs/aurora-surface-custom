import Foundation

// MARK: - Text normalization (shared/README.md §1, §3.1)

public enum TextNorm {
    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        t = t.replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var out = ""
        var lastSpace = true
        for ch in t.unicodeScalars {
            let ok = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "%"
            if ok { out.unicodeScalars.append(ch); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func tokens(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    public static func singularVariants(_ w: String) -> [String] {
        var v: [String] = []
        func add(_ x: String) { if x != w && !x.isEmpty && !v.contains(x) { v.append(x) } }
        if w.hasSuffix("ies") && w.count > 4 { add(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("oes") { add(String(w.dropLast(2))) }
        if w.hasSuffix("ves") { add(String(w.dropLast(3)) + "f"); add(String(w.dropLast(3)) + "fe") }
        if w.hasSuffix("ses") || w.hasSuffix("xes") || w.hasSuffix("zes") || w.hasSuffix("ches") || w.hasSuffix("shes") {
            add(String(w.dropLast(2)))
        }
        if w.hasSuffix("s") && !w.hasSuffix("ss") && !w.hasSuffix("us") && !w.hasSuffix("is") { add(String(w.dropLast())) }
        return v
    }
}

// MARK: - Taxonomy

public struct GroceryCategory: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var emoji: String
    public var symbol: String
    public var order: Int
    public var id: String { key }
}

public final class GroceryTaxonomy: @unchecked Sendable {
    public let categories: [GroceryCategory]
    public let modifiers: [String: String]
    let index: [String: String]

    struct Raw: Decodable {
        var categories: [GroceryCategory]
        var modifiers: [String: String]
        var terms: [String: [String]]
    }

    public init(data: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        categories = raw.categories.sorted { $0.order < $1.order }
        modifiers = raw.modifiers
        var idx: [String: String] = [:]
        for (cat, terms) in raw.terms {
            for t in terms { idx[TextNorm.normalize(t)] = cat }
        }
        index = idx
    }

    /// The taxonomy bundled with RoostKit (copy of shared/grocery/taxonomy.json).
    public static let bundled: GroceryTaxonomy = {
        guard let url = Bundle.module.url(forResource: "taxonomy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let t = try? GroceryTaxonomy(data: data) else {
            fatalError("RoostKit taxonomy.json missing from bundle")
        }
        return t
    }()

    public func category(_ key: String) -> GroceryCategory {
        categories.first { $0.key == key } ?? categories.last!
    }

    public var termCount: Int { index.count }
}

// MARK: - Line parsing (§2)

public struct ParsedGrocery: Equatable, Sendable {
    public var name: String
    public var quantity: Double?
    public var unit: String?
}

public enum GroceryParser {
    static let units: [String: String] = {
        var m: [String: String] = [:]
        let groups: [(String, [String])] = [
            ("lb", ["lb", "lbs", "pound", "pounds"]), ("oz", ["oz", "ounce", "ounces"]), ("g", ["g", "gram", "grams"]),
            ("kg", ["kg", "kgs", "kilogram", "kilograms"]), ("ml", ["ml"]), ("l", ["l", "liter", "liters", "litre", "litres"]),
            ("gal", ["gal", "gallon", "gallons"]), ("qt", ["qt", "quart", "quarts"]), ("pt", ["pt", "pint", "pints"]),
            ("cup", ["cup", "cups"]), ("dozen", ["dozen", "doz"]), ("pack", ["pack", "packs", "pk", "pkg", "package", "packages"]),
            ("box", ["box", "boxes"]), ("bag", ["bag", "bags"]), ("can", ["can", "cans"]), ("jar", ["jar", "jars"]),
            ("bottle", ["bottle", "bottles"]), ("bunch", ["bunch", "bunches"]), ("head", ["head", "heads"]), ("loaf", ["loaf", "loaves"]),
            ("carton", ["carton", "cartons"]), ("container", ["container", "containers"]), ("roll", ["roll", "rolls"]),
            ("bar", ["bar", "bars"]), ("stick", ["stick", "sticks"]), ("piece", ["piece", "pieces", "pc", "pcs"]),
            ("ct", ["ct", "count"]), ("case", ["case", "cases"]), ("tub", ["tub", "tubs"]),
        ]
        for (canon, words) in groups { for w in words { m[w] = canon } }
        return m
    }()

    static let words: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "half": 0.5, "couple": 2,
    ]
    static let fractions: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "⅛": 0.125]

    /// Parses a numeric token: "2", "2.5", ".5", "1/2", "½", "1½".
    static func number(_ t: String) -> Double? {
        if let d = Double(t), t.first != "+", t.first != "-", !t.lowercased().contains("e"), !t.contains("n") { return d }
        if let last = t.last, let f = fractions[last] {
            let head = t.dropLast()
            if head.isEmpty { return f }
            if let w = Int(head) { return Double(w) + f }
            return nil
        }
        let parts = t.split(separator: "/")
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0, !parts[0].contains("."), !parts[1].contains(".") {
            return a / b
        }
        return nil
    }

    static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static let trailing = regex(#"(?:^|\s)(?:[x×]\s*(\d+(?:\.\d+)?)|\((\d+(?:\.\d+)?)\))\s*$"#)
    static let glued = regex(#"^(\d+(?:\.\d+)?|\d*[½¼¾⅓⅔⅛])(x|-?[a-z]+)$"#)

    public static func parse(_ raw: String) -> ParsedGrocery? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var qty: Double?
        var unit: String?

        let ns = s as NSString
        if let m = trailing.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range.location > 0 {
            let g = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            qty = Double(ns.substring(with: g))
            s = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
        }

        var toks = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if qty == nil, let first = toks.first {
            let fns = first as NSString
            if let m = glued.firstMatch(in: first, range: NSRange(location: 0, length: fns.length)) {
                var rest = fns.substring(with: m.range(at: 2))
                if rest.hasPrefix("-") { rest.removeFirst() }
                if rest.lowercased() == "x" || units[rest.lowercased()] != nil {
                    toks.replaceSubrange(0...0, with: [fns.substring(with: m.range(at: 1)), rest])
                }
            }
            var i = 0
            let lower = { (k: Int) -> String in k < toks.count ? toks[k].lowercased() : "" }
            if lower(0) == "a" || lower(0) == "an" {
                if lower(1) == "couple" { qty = 2; i = 2 } else { qty = 1; i = 1 }
            } else if let w = words[lower(0)], lower(0) != "half" || units[lower(1)] != nil {
                qty = w; i = 1 // "half" only as "half gallon"/"half dozen", never "half and half"
            } else if let n = number(toks[0]) {
                qty = n; i = 1
                if let frac = number(lower(1)), lower(1).contains("/") || lower(1).count == 1 && fractions[Character(lower(1))] != nil {
                    qty = n + frac; i = 2
                }
            } else if lower(0) == "dozen" {
                qty = 1; unit = "dozen"; i = 1
            }
            if qty != nil {
                if lower(i) == "x" || lower(i) == "×" { i += 1 }
                var unitIndex: Int?
                if unit == nil, let u = units[lower(i).trimmingCharacters(in: CharacterSet(charactersIn: "."))] {
                    unit = u; unitIndex = i; i += 1
                }
                if lower(i) == "of" { i += 1 }
                var rest = Array(toks.dropFirst(i))
                if rest.isEmpty {
                    if let ui = unitIndex { rest = [toks[ui]]; unit = nil } // "6 rolls": the unit word is the item
                    else { qty = nil; unit = nil; rest = toks }              // a bare number isn't a quantity
                }
                toks = rest
            }
        }
        let name = cleanName(toks.joined(separator: " "))
        guard !name.isEmpty else { return ParsedGrocery(name: cleanName(raw), quantity: nil, unit: nil) }
        return ParsedGrocery(name: name, quantity: qty, unit: unit)
    }

    static func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–")))
        guard let f = t.first else { return "" }
        return f.uppercased() + t.dropFirst()
    }

    /// Display string for a quantity: "2", "1.5", "½".
    public static func formatQuantity(_ q: Double?, unit: String?) -> String? {
        guard let q else { return unit }
        let n: String
        if q == 0.5 { n = "½" } else if q == 0.25 { n = "¼" } else if q == 0.75 { n = "¾" }
        else if q == q.rounded() { n = String(Int(q)) } else { n = String(format: "%.2g", q) }
        guard let unit else { return n }
        return "\(n) \(unit)"
    }
}

// MARK: - Categorization (§3)

public struct CategoryResult: Equatable, Sendable {
    public var category: String
    public var source: String // "learned" | "dictionary" | "none"
}

public struct GroceryCategorizer: Sendable {
    public let taxonomy: GroceryTaxonomy
    public var learned: [String: String]

    public init(taxonomy: GroceryTaxonomy = .bundled, learned: [String: String] = [:]) {
        self.taxonomy = taxonomy
        self.learned = learned
    }

    static let overridable: Set<String> = ["produce", "meat", "bakery", "dairy"]

    public func categorize(_ name: String) -> CategoryResult {
        let toks = TextNorm.tokens(name)
        guard !toks.isEmpty else { return CategoryResult(category: "other", source: "none") }
        let full = toks.joined(separator: " ")
        if let c = learned[full] { return CategoryResult(category: c, source: "learned") }
        for v in TextNorm.singularVariants(toks.last!) {
            let alt = (toks.dropLast() + [v]).joined(separator: " ")
            if let c = learned[alt] { return CategoryResult(category: c, source: "learned") }
        }

        var best: (len: Int, end: Int, exact: Bool, cat: String)?
        for len in stride(from: min(4, toks.count), through: 1, by: -1) {
            for start in 0...(toks.count - len) {
                let gram = Array(toks[start..<(start + len)])
                var hit: (Bool, String)?
                if let c = taxonomy.index[gram.joined(separator: " ")] {
                    hit = (true, c)
                } else {
                    for v in TextNorm.singularVariants(gram.last!) {
                        if let c = taxonomy.index[(gram.dropLast() + [v]).joined(separator: " ")] { hit = (false, c); break }
                    }
                }
                guard let (exact, cat) = hit else { continue }
                let end = start + len - 1
                if let b = best {
                    if len < b.len { continue }
                    if len == b.len && end < b.end { continue }
                    if len == b.len && end == b.end && (!exact || b.exact) { continue }
                }
                best = (len, end, exact, cat)
            }
        }
        let modifier = toks.lazy.compactMap { taxonomy.modifiers[$0] }.first
        if let b = best {
            if let m = modifier, GroceryCategorizer.overridable.contains(b.cat) {
                return CategoryResult(category: m, source: "dictionary")
            }
            return CategoryResult(category: b.cat, source: "dictionary")
        }
        if let m = modifier { return CategoryResult(category: m, source: "dictionary") }
        return CategoryResult(category: "other", source: "none")
    }

    public static func learnKey(_ name: String) -> String { TextNorm.tokens(name).joined(separator: " ") }
}

// MARK: - Merging (§3.2)

public enum GroceryMerge {
    public static func mergeKey(_ name: String) -> String {
        TextNorm.tokens(name).map { TextNorm.singularVariants($0).first ?? $0 }.joined(separator: " ")
    }

    public enum Action: String, Sendable { case merge, uncheck, new }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        public var targetIndex: Int?
        public var quantity: Double?
        public var unit: String?
    }

    public struct Existing: Sendable {
        public var name: String
        public var quantity: Double?
        public var unit: String?
        public var checked: Bool
        public init(name: String, quantity: Double?, unit: String?, checked: Bool) {
            self.name = name; self.quantity = quantity; self.unit = unit; self.checked = checked
        }
    }

    public static func decide(adding p: ParsedGrocery, to items: [Existing]) -> Decision {
        let key = mergeKey(p.name)
        // Prefer an unchecked match with the same unit, then any unchecked, then checked.
        let matches = items.enumerated().filter { mergeKey($0.element.name) == key }
        if let (i, it) = matches.first(where: { !$0.element.checked && $0.element.unit == p.unit }) {
            return Decision(action: .merge, targetIndex: i, quantity: (it.quantity ?? 1) + (p.quantity ?? 1), unit: p.unit)
        }
        if matches.contains(where: { !$0.element.checked }) {
            return Decision(action: .new, targetIndex: nil, quantity: p.quantity, unit: p.unit)
        }
        if let (i, _) = matches.first(where: { $0.element.checked }) {
            return Decision(action: .uncheck, targetIndex: i, quantity: p.quantity, unit: p.unit)
        }
        return Decision(action: .new, targetIndex: nil, quantity: p.quantity, unit: p.unit)
    }
}
