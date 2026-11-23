import Foundation

/// Natural-language quick add (shared/README.md §4). The regular expressions
/// here are mirrored exactly in web/src/core/quickadd.ts.
public struct QuickAddResult: Equatable, Sendable {
    public var title: String = ""
    public var date: LocalDate?
    public var time: (hour: Int, minute: Int)? { get { timeMinutes.map { ($0 / 60, $0 % 60) } } set { timeMinutes = newValue.map { $0.hour * 60 + $0.minute } } }
    public var timeMinutes: Int?
    public var endDate: LocalDate?
    public var endTimeMinutes: Int?
    public var allDay: Bool { timeMinutes == nil }
    public var rrule: String?
    public var mentions: [String] = []
    public var driver: String?
    public var tag: String?
    public var priority: Int = 0
    public var reminders: [Int] = []

    public static func == (a: QuickAddResult, b: QuickAddResult) -> Bool {
        a.title == b.title && a.date == b.date && a.timeMinutes == b.timeMinutes && a.endDate == b.endDate &&
            a.endTimeMinutes == b.endTimeMinutes && a.rrule == b.rrule && a.mentions == b.mentions &&
            a.driver == b.driver && a.tag == b.tag && a.priority == b.priority && a.reminders == b.reminders
    }

    /// Start as a wall-clock date-time (midnight for all-day).
    public var start: LocalDateTime? { date.map { LocalDateTime($0, (timeMinutes ?? 0) / 60, (timeMinutes ?? 0) % 60) } }
    public var end: LocalDateTime? {
        guard let d = endDate, let m = endTimeMinutes else { return nil }
        return LocalDateTime(d, m / 60, m % 60)
    }
}

public enum QuickAddMode: String, Sendable { case event, task }

public enum QuickAddParser {
    static let WD = #"(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:s|nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)s?"#
    static let MONTH = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    static let ORD = #"(?:1st|2nd|3rd|4th|first|second|third|fourth|last)"#
    static let MER = #"(am|pm|a\.m\.|p\.m\.)"#
    static let SEP = #"\s*(?:,\s*and|,|and|&|/)\s*"#
    static let PRE = #"(?:\b(?:due|on|by)\s+)?"#

    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    static let driver = re(#"\bdriver:\s*([A-Za-z][\w'-]*)"#)
    static let mention = re(#"(^|\s)@([A-Za-z][\w'-]*)"#)
    static let tag = re(#"(^|\s)#([A-Za-z0-9][\w-]*)"#)
    static let prioWord = re(#"(^|\s)!(high|medium|med|low)\b"#)
    static let prioBang = re(#"(^|\s)(!{1,3})(?=\s|$)"#)
    static let remind = re(#"\bremind(?:\s+me)?\s+(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|hr|h|days?|d|weeks?|wks?|w)\b(?:\s+before)?"#)

    static let recOrdinal = re(#"\bevery\s+("# + ORD + "(?:" + SEP + ORD + #")*)\s+("# + WD + #")\b"#)
    static let recWeekdays = re(#"\bevery\s+(other\s+)?("# + WD + "(?:" + SEP + WD + #")*)\b"#)
    static let recOtherDay = re(#"\bevery\s+other\s+day\b"#)
    static let recNDays = re(#"\bevery\s+(\d+)\s+days?\b"#)
    static let recDaily = re(#"\b(?:daily|every\s+day)\b"#)
    static let recWeekday = re(#"\b(?:every\s+weekday|weekdays)\b"#)
    static let recWeekend = re(#"\b(?:every\s+weekend|weekends)\b"#)
    static let recOtherWeek = re(#"\b(?:every\s+other\s+week|biweekly)\b"#)
    static let recNWeeks = re(#"\bevery\s+(\d+)\s+weeks?\b"#)
    static let recWeekly = re(#"\b(?:weekly|every\s+week)\b"#)
    static let recNMonths = re(#"\bevery\s+(\d+)\s+months?\b"#)
    static let recMonthly = re(#"\b(?:monthly|every\s+month)\b"#)
    static let recYearly = re(#"\b(?:yearly|annually|every\s+year)\b"#)

    static let dISO = re(PRE + #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#)
    static let dNumeric = re(PRE + #"\b(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\b"#)
    static let dMonthDay = re(PRE + #"\b"# + MONTH + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#)
    static let dDayMonth = re(PRE + #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + MONTH + #"\b(?:,?\s+(\d{4}))?"#)
    static let dToday = re(#"\b(?:due\s+)?today\b"#)
    static let dTonight = re(#"\btonight\b"#)
    static let dTomorrow = re(#"\b(?:due\s+)?(?:tomorrow|tmrw|tmw)\b"#)
    static let dWeekend = re(#"\bthis\s+weekend\b"#)
    static let dNextWeek = re(#"\bnext\s+week\b"#)
    static let dIn = re(#"\bin\s+(\d+)\s+(days?|weeks?)\b"#)
    static let dNextWD = re(#"\b(?:due\s+)?next\s+("# + WD + #")\b"#)
    static let dWD = re(#"\b(?:(?:due|on|this)\s+)?("# + WD + #")\b"#)

    static let tRange = re(#"(?:\bfrom\s+)?\b(\d{1,2})(?::(\d{2}))?\s*"# + MER + #"?\s*(?:-|–|—|to|until|till)\s*(\d{1,2})(?::(\d{2}))?\s*"# + MER + #"(?!\w)"#)
    static let tRange24 = re(#"(?:\bfrom\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\s*(?:-|–|—|to|until|till)\s*([01]?\d|2[0-3]):([0-5]\d)\b"#)
    static let tNoon = re(#"\b(noon|midnight)\b"#)
    static let tMer = re(#"\b(\d{1,2})(?::(\d{2}))?\s*"# + MER + #"(?!\w)"#)
    static let tColon = re(#"(\bat\s+)?\b(\d{1,2}):(\d{2})\b"#)
    static let tAt = re(#"\bat\s+(\d{1,2})\b(?!\s*(?::|am|pm|a\.m|p\.m))"#)
    static let duration = re(#"\bfor\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|mins?|min|m)\b"#)

    static let connectors: Set<String> = ["at", "on", "from", "by", "due", "for", "in", "every", "the"]

    struct Work {
        var s: String
        mutating func take(_ r: NSRegularExpression) -> [String?]? {
            let ns = s as NSString
            guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                let rg = m.range(at: i)
                groups.append(rg.location == NSNotFound ? nil : ns.substring(with: rg))
            }
            s = ns.replacingCharacters(in: m.range, with: " ")
            return groups
        }
        mutating func takeAll(_ r: NSRegularExpression) -> [[String?]] {
            var out: [[String?]] = []
            while let g = take(r) { out.append(g) }
            return out
        }
    }

    static func weekdayIndex(_ s: String) -> Int {
        ["su": 0, "mo": 1, "tu": 2, "we": 3, "th": 4, "fr": 5, "sa": 6][String(s.lowercased().prefix(2))] ?? 1
    }

    static func monthIndex(_ s: String) -> Int {
        let p = String(s.lowercased().prefix(3))
        return (["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: p) ?? 0) + 1
    }

    static func ordinalValue(_ s: String) -> Int {
        switch s.lowercased() {
        case "1st", "first": return 1
        case "2nd", "second": return 2
        case "3rd", "third": return 3
        case "4th", "fourth": return 4
        default: return -1
        }
    }

    static func minutes(_ n: Double, _ unit: String) -> Int {
        let u = unit.lowercased()
        if u.hasPrefix("w") { return Int(n * 10080) }
        if u.hasPrefix("d") { return Int(n * 1440) }
        if u.hasPrefix("h") { return Int(n * 60) }
        return Int(n)
    }

    static func to24(_ h: Int, _ mer: String?) -> Int {
        guard let mer = mer?.lowercased() else { return h }
        if mer.hasPrefix("a") { return h == 12 ? 0 : h }
        return h == 12 ? 12 : h + 12
    }

    static func bareHour(_ h: Int) -> Int { (1...7).contains(h) ? h + 12 : h }

    static func weekStart(_ d: LocalDate) -> LocalDate { d.adding(days: -((d.weekday + 6) % 7)) }
    static func onOrAfter(_ today: LocalDate, _ wd: Int) -> LocalDate { today.adding(days: (wd - today.weekday + 7) % 7) }
    static func strictlyAfter(_ today: LocalDate, _ wd: Int) -> LocalDate {
        let n = (wd - today.weekday + 7) % 7
        return today.adding(days: n == 0 ? 7 : n)
    }

    public static func parse(_ text: String, now: LocalDateTime, mode: QuickAddMode) -> QuickAddResult {
        var r = QuickAddResult()
        var w = Work(s: " " + text + " ")
        let today = now.date

        if let g = w.take(driver) { r.driver = g[1] }
        r.mentions = w.takeAll(mention).compactMap { $0[2] }
        let tags = w.takeAll(tag).compactMap { $0[2] }
        r.tag = tags.first.map { $0.replacingOccurrences(of: "_", with: " ") }
        if let g = w.take(prioWord) {
            r.priority = ["high": 3, "medium": 2, "med": 2, "low": 1][g[2]!.lowercased()] ?? 0
        } else if let g = w.take(prioBang) {
            r.priority = g[2]!.count
        }
        r.reminders = w.takeAll(remind).map { minutes(Double($0[1]!) ?? 0, $0[2]!) }

        // Recurrence.
        var byDays: [Int] = []
        var ordinals: [(Int, Int)] = [] // (ordinal, weekday)
        let codes = RRule.dayCodes
        if let g = w.take(recOrdinal) {
            let wd = weekdayIndex(g[2]!)
            let ords = g[1]!.components(separatedBy: CharacterSet(charactersIn: ",&")).flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            ordinals = ords.map { (ordinalValue($0), wd) }
            r.rrule = "FREQ=MONTHLY;BYDAY=" + ordinals.map { "\($0.0)\(codes[$0.1])" }.joined(separator: ",")
        } else if let g = w.take(recWeekdays) {
            let names = (try! NSRegularExpression(pattern: WD, options: [.caseInsensitive]))
                .matches(in: g[2]!, range: NSRange(location: 0, length: (g[2]! as NSString).length))
                .map { (g[2]! as NSString).substring(with: $0.range) }
            byDays = Array(Set(names.map(weekdayIndex))).sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
            r.rrule = "FREQ=WEEKLY;" + (g[1] != nil ? "INTERVAL=2;" : "") + "BYDAY=" + byDays.map { codes[$0] }.joined(separator: ",")
        } else if w.take(recOtherDay) != nil {
            r.rrule = "FREQ=DAILY;INTERVAL=2"
        } else if let g = w.take(recNDays) {
            r.rrule = "FREQ=DAILY;INTERVAL=\(g[1]!)"
        } else if w.take(recDaily) != nil {
            r.rrule = "FREQ=DAILY"
        } else if w.take(recWeekday) != nil {
            byDays = [1, 2, 3, 4, 5]
            r.rrule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        } else if w.take(recWeekend) != nil {
            byDays = [6, 0]
            r.rrule = "FREQ=WEEKLY;BYDAY=SA,SU"
        } else if w.take(recOtherWeek) != nil {
            r.rrule = "FREQ=WEEKLY;INTERVAL=2"
        } else if let g = w.take(recNWeeks) {
            r.rrule = "FREQ=WEEKLY;INTERVAL=\(g[1]!)"
        } else if w.take(recWeekly) != nil {
            r.rrule = "FREQ=WEEKLY"
        } else if let g = w.take(recNMonths) {
            r.rrule = "FREQ=MONTHLY;INTERVAL=\(g[1]!)"
        } else if w.take(recMonthly) != nil {
            r.rrule = "FREQ=MONTHLY"
        } else if w.take(recYearly) != nil {
            r.rrule = "FREQ=YEARLY"
        }

        // Dates.
        var tonight = false
        func rollYear(_ m: Int, _ d: Int, _ y: String?) -> LocalDate? {
            if let y, var yy = Int(y) {
                if yy < 100 { yy += 2000 }
                return LocalDate.valid(yy, m, d) ? LocalDate(yy, m, d) : nil
            }
            guard LocalDate.valid(today.year, m, d) else { return nil }
            let c = LocalDate(today.year, m, d)
            return c < today ? (LocalDate.valid(today.year + 1, m, d) ? LocalDate(today.year + 1, m, d) : nil) : c
        }
        if let g = w.take(dISO) {
            let (y, m, d) = (Int(g[1]!)!, Int(g[2]!)!, Int(g[3]!)!)
            r.date = LocalDate.valid(y, m, d) ? LocalDate(y, m, d) : nil
        } else if let g = w.take(dNumeric) {
            r.date = rollYear(Int(g[1]!)!, Int(g[2]!)!, g[3])
        } else if let g = w.take(dMonthDay) {
            r.date = rollYear(monthIndex(g[1]!), Int(g[2]!)!, g[3])
        } else if let g = w.take(dDayMonth) {
            r.date = rollYear(monthIndex(g[2]!), Int(g[1]!)!, g[3])
        } else if w.take(dToday) != nil {
            r.date = today
        } else if w.take(dTonight) != nil {
            r.date = today; tonight = true
        } else if w.take(dTomorrow) != nil {
            r.date = today.adding(days: 1)
        } else if w.take(dWeekend) != nil {
            r.date = today.weekday == 6 ? today : onOrAfter(today, 6)
        } else if w.take(dNextWeek) != nil {
            r.date = weekStart(today).adding(days: 7)
        } else if let g = w.take(dIn) {
            let n = Int(g[1]!)!
            r.date = today.adding(days: g[2]!.lowercased().hasPrefix("w") ? n * 7 : n)
        } else if let g = w.take(dNextWD) {
            var d = strictlyAfter(today, weekdayIndex(g[1]!))
            if weekStart(d) == weekStart(today) { d = d.adding(days: 7) }
            r.date = d
        } else if let g = w.take(dWD) {
            r.date = onOrAfter(today, weekdayIndex(g[1]!))
        }

        // Times.
        var start: Int?
        var end: Int?
        if let g = w.take(tRange) {
            let em = to24(Int(g[4]!)!, g[6]) * 60 + (Int(g[5] ?? "0") ?? 0)
            var sh = Int(g[1]!)!
            let smin = Int(g[2] ?? "0") ?? 0
            if let sm = g[3] { sh = to24(sh, sm) } else {
                sh = to24(sh, g[6])
                if sh * 60 + smin > em { sh = to24(Int(g[1]!)!, "am") }
            }
            start = sh * 60 + smin
            end = em
        } else if let g = w.take(tRange24) {
            start = Int(g[1]!)! * 60 + Int(g[2]!)!
            end = Int(g[3]!)! * 60 + Int(g[4]!)!
        } else if let g = w.take(tNoon) {
            start = g[1]!.lowercased() == "noon" ? 720 : 0
        } else if let g = w.take(tMer) {
            start = to24(Int(g[1]!)!, g[3]) * 60 + (Int(g[2] ?? "0") ?? 0)
        } else if let g = w.take(tColon) {
            var h = Int(g[2]!)!
            if g[1] != nil { h = bareHour(h) }
            start = h * 60 + Int(g[3]!)!
        } else if let g = w.take(tAt) {
            start = bareHour(Int(g[1]!)!) * 60
        }
        if let g = w.take(duration), let s = start {
            end = s + minutes(Double(g[1]!) ?? 0, g[2]!)
        }
        if start == nil && tonight { start = 18 * 60 }
        if let s = start, s >= 24 * 60 { start = nil }

        // Default dates.
        if r.date == nil {
            if !ordinals.isEmpty {
                var d = today
                for _ in 0..<400 {
                    let n = LocalDate.daysInMonth(d.year, d.month)
                    if ordinals.contains(where: { o, wd in d.weekday == wd && (o > 0 ? (d.day - 1) / 7 + 1 == o : d.day + 7 > n) }) { break }
                    d = d.adding(days: 1)
                }
                r.date = d
            } else if !byDays.isEmpty {
                r.date = (0..<7).map { today.adding(days: $0) }.first { byDays.contains($0.weekday) }
            } else if mode == .event || r.rrule != nil || start != nil {
                r.date = today
            }
        }

        if let s = start, let d = r.date {
            r.timeMinutes = s
            if mode == .event {
                var e = end ?? s + 60
                var ed = d
                if e <= s && end != nil { e += 1440 }
                while e >= 1440 { e -= 1440; ed = ed.adding(days: 1) }
                r.endDate = ed
                r.endTimeMinutes = e
            }
        }

        // Title.
        var words = w.s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        let punct = CharacterSet(charactersIn: ",;:-–—")
        func clean(_ x: String) -> String { x.trimmingCharacters(in: punct) }
        while let f = words.first, connectors.contains(clean(f).lowercased()) || clean(f).isEmpty { words.removeFirst() }
        while let l = words.last, connectors.contains(clean(l).lowercased()) || clean(l).isEmpty { words.removeLast() }
        var title = words.joined(separator: " ").trimmingCharacters(in: punct.union(.whitespaces))
        if let f = title.first { title = f.uppercased() + title.dropFirst() }
        r.title = title
        return r
    }
}
