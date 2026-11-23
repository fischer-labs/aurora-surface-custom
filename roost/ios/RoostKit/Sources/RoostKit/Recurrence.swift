import Foundation

/// RFC 5545 RRULE subset (DESIGN §4). Unknown parts are ignored.
public struct RRule: Equatable, Sendable {
    public enum Freq: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    public enum Until: Equatable, Sendable {
        case date(LocalDate)            // inclusive local day
        case local(LocalDateTime)       // floating local time
        case utc(Date)                  // absolute instant
    }
    public struct WeekdayNum: Equatable, Hashable, Sendable {
        public var ordinal: Int?        // e.g. 2 for 2TU, -1 for -1FR
        public var weekday: Int         // 0 = Sunday
        public init(_ weekday: Int, ordinal: Int? = nil) { self.weekday = weekday; self.ordinal = ordinal }
    }

    public var freq: Freq
    public var interval: Int = 1
    public var count: Int?
    public var until: Until?
    public var byDay: [WeekdayNum] = []
    public var byMonthDay: [Int] = []
    public var byMonth: [Int] = []
    public var bySetPos: [Int] = []
    public var wkst: Int = 1 // Monday

    public init(freq: Freq) { self.freq = freq }

    public static let dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    public init?(_ string: String) {
        var freq: Freq?
        var r = RRule(freq: .daily)
        for part in string.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard kv.count == 2 else { continue }
            let (k, v) = (kv[0], kv[1])
            switch k {
            case "FREQ": freq = Freq(rawValue: v)
            case "INTERVAL": r.interval = max(1, Int(v) ?? 1)
            case "COUNT": r.count = Int(v)
            case "UNTIL": r.until = RRule.parseUntil(v)
            case "BYDAY":
                r.byDay = v.split(separator: ",").compactMap { tok in
                    let s = String(tok)
                    guard s.count >= 2, let wd = RRule.dayCodes.firstIndex(of: String(s.suffix(2))) else { return nil }
                    let ord = Int(s.dropLast(2))
                    return WeekdayNum(wd, ordinal: ord == 0 ? nil : ord)
                }
            case "BYMONTHDAY": r.byMonthDay = v.split(separator: ",").compactMap { Int($0) }.filter { $0 != 0 && abs($0) <= 31 }
            case "BYMONTH": r.byMonth = v.split(separator: ",").compactMap { Int($0) }.filter { (1...12).contains($0) }
            case "BYSETPOS": r.bySetPos = v.split(separator: ",").compactMap { Int($0) }.filter { $0 != 0 }
            case "WKST": r.wkst = RRule.dayCodes.firstIndex(of: v) ?? 1
            default: break
            }
        }
        guard let f = freq else { return nil }
        r.freq = f
        self = r
    }

    static func parseUntil(_ v: String) -> Until? {
        let digits = v.filter { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let y = Int(digits.prefix(4))!, m = Int(digits.dropFirst(4).prefix(2))!, d = Int(digits.dropFirst(6).prefix(2))!
        let date = LocalDate(y, m, d)
        guard v.contains("T"), digits.count >= 12 else { return .date(date) }
        let hh = Int(digits.dropFirst(8).prefix(2))!, mm = Int(digits.dropFirst(10).prefix(2))!
        let ss = digits.count >= 14 ? Int(digits.dropFirst(12).prefix(2))! : 0
        if v.hasSuffix("Z") {
            let base = LocalDateTime(date, hh, mm).toDate(in: TimeZone(identifier: "UTC")!)
            return .utc(base.addingTimeInterval(TimeInterval(ss)))
        }
        return .local(LocalDateTime(date, hh, mm))
    }

    /// Serializes back to RRULE text (without the "RRULE:" prefix).
    public var string: String {
        var parts = ["FREQ=\(freq.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if !byMonth.isEmpty { parts.append("BYMONTH=" + byMonth.map(String.init).joined(separator: ",")) }
        if !byMonthDay.isEmpty { parts.append("BYMONTHDAY=" + byMonthDay.map(String.init).joined(separator: ",")) }
        if !byDay.isEmpty {
            parts.append("BYDAY=" + byDay.map { ($0.ordinal.map(String.init) ?? "") + RRule.dayCodes[$0.weekday] }.joined(separator: ","))
        }
        if !bySetPos.isEmpty { parts.append("BYSETPOS=" + bySetPos.map(String.init).joined(separator: ",")) }
        if let c = count { parts.append("COUNT=\(c)") }
        if let u = until {
            switch u {
            case .date(let d): parts.append(String(format: "UNTIL=%04d%02d%02d", d.year, d.month, d.day))
            case .local(let l): parts.append(String(format: "UNTIL=%04d%02d%02dT%02d%02d00", l.date.year, l.date.month, l.date.day, l.hour, l.minute))
            case .utc(let date):
                let l = LocalDateTime(date, in: TimeZone(identifier: "UTC")!)
                parts.append(String(format: "UNTIL=%04d%02d%02dT%02d%02d00Z", l.date.year, l.date.month, l.date.day, l.hour, l.minute))
            }
        }
        return parts.joined(separator: ";")
    }

    // MARK: Candidate generation per period

    func candidates(period: Int, start: LocalDateTime) -> [LocalDate] {
        let s = start.date
        var out: [LocalDate] = []
        switch freq {
        case .daily:
            let d = s.adding(days: period * interval)
            if matchesFilters(d, allowOrdinals: false) { out = [d] }
        case .weekly:
            // Week containing DTSTART, aligned to WKST.
            let offset = (s.weekday - wkst + 7) % 7
            let weekStart = s.adding(days: -offset + period * interval * 7)
            let days = byDay.isEmpty ? [s.weekday] : byDay.map(\.weekday)
            for i in 0..<7 {
                let d = weekStart.adding(days: i)
                if days.contains(d.weekday), byMonth.isEmpty || byMonth.contains(d.month) { out.append(d) }
            }
        case .monthly:
            let ym = s.adding(months: period * interval)
            if !byMonth.isEmpty && !byMonth.contains(ym.month) { break }
            out = daysInMonth(ym.year, ym.month, defaultDay: s.day)
        case .yearly:
            let y = s.year + period * interval
            if byDay.contains(where: { $0.ordinal != nil }) && byMonth.isEmpty && byMonthDay.isEmpty {
                // Ordinal weekday within the year (e.g. 20MO) — rarely used.
                for wd in byDay {
                    let all = (1...12).flatMap { m in (1...LocalDate.daysInMonth(y, m)).map { LocalDate(y, m, $0) } }.filter { $0.weekday == wd.weekday }
                    if let o = wd.ordinal { if let d = pick(all, o) { out.append(d) } } else { out.append(contentsOf: all) }
                }
            } else {
                let months = byMonth.isEmpty ? [s.month] : byMonth
                for m in months {
                    if byMonthDay.isEmpty && byDay.isEmpty {
                        if LocalDate.valid(y, m, s.day) { out.append(LocalDate(y, m, s.day)) }
                    } else {
                        out.append(contentsOf: daysInMonth(y, m, defaultDay: s.day))
                    }
                }
            }
        }
        out = Array(Set(out)).sorted()
        if !bySetPos.isEmpty && !out.isEmpty {
            var picked: [LocalDate] = []
            for p in bySetPos { if let d = pick(out, p) { picked.append(d) } }
            out = Array(Set(picked)).sorted()
        }
        return out
    }

    private func pick(_ list: [LocalDate], _ pos: Int) -> LocalDate? {
        let idx = pos > 0 ? pos - 1 : list.count + pos
        return idx >= 0 && idx < list.count ? list[idx] : nil
    }

    private func daysInMonth(_ y: Int, _ m: Int, defaultDay: Int) -> [LocalDate] {
        let n = LocalDate.daysInMonth(y, m)
        var byMD: [LocalDate]? = nil
        if !byMonthDay.isEmpty {
            byMD = byMonthDay.compactMap { md in
                let d = md > 0 ? md : n + md + 1
                return d >= 1 && d <= n ? LocalDate(y, m, d) : nil
            }
        }
        var byD: [LocalDate]? = nil
        if !byDay.isEmpty {
            var res: [LocalDate] = []
            for wd in byDay {
                let all = (1...n).map { LocalDate(y, m, $0) }.filter { $0.weekday == wd.weekday }
                if let o = wd.ordinal { if let d = pick(all, o) { res.append(d) } } else { res.append(contentsOf: all) }
            }
            byD = res
        }
        switch (byMD, byD) {
        case let (a?, b?): return a.filter { b.contains($0) }
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return LocalDate.valid(y, m, defaultDay) ? [LocalDate(y, m, defaultDay)] : []
        }
    }

    private func matchesFilters(_ d: LocalDate, allowOrdinals: Bool) -> Bool {
        if !byMonth.isEmpty && !byMonth.contains(d.month) { return false }
        if !byMonthDay.isEmpty {
            let n = LocalDate.daysInMonth(d.year, d.month)
            if !byMonthDay.contains(where: { ($0 > 0 ? $0 : n + $0 + 1) == d.day }) { return false }
        }
        if !byDay.isEmpty && !byDay.contains(where: { $0.weekday == d.weekday }) { return false }
        return true
    }

    /// Number of whole periods between two local dates (for fast-forwarding).
    func periodsBetween(_ a: LocalDate, _ b: LocalDate) -> Int {
        switch freq {
        case .daily: return (b.dayNumber - a.dayNumber) / interval
        case .weekly: return (b.dayNumber - a.dayNumber) / (7 * interval)
        case .monthly: return ((b.year - a.year) * 12 + (b.month - a.month)) / interval
        case .yearly: return (b.year - a.year) / interval
        }
    }
}

/// Expands a (possibly recurring) event into occurrence start times.
public enum RecurrenceExpander {
    public static let maxIterations = 50_000

    /// - Returns: wall-clock starts (in `tz`) of occurrences overlapping `[rangeStart, rangeEnd)`.
    public static func expand(start: LocalDateTime, durationMinutes: Int, allDay: Bool, tz: TimeZone,
                              rrule: String?, exdates: Set<String>,
                              rangeStart: Date, rangeEnd: Date) -> [LocalDateTime] {
        func overlaps(_ s: LocalDateTime) -> Bool {
            let sd = s.toDate(in: tz)
            let ed: Date = allDay
                ? s.adding(minutes: max(durationMinutes, 1440)).toDate(in: tz)
                : sd.addingTimeInterval(TimeInterval(durationMinutes * 60))
            if ed == sd { return rangeStart <= sd && sd < rangeEnd }
            return sd < rangeEnd && ed > rangeStart
        }
        let normStart = allDay ? LocalDateTime(start.date) : start
        guard let ruleText = rrule, !ruleText.isEmpty, let rule = RRule(ruleText) else {
            return overlaps(normStart) && !exdates.contains(normStart.key(allDay: allDay)) ? [normStart] : []
        }
        let endLocal = LocalDateTime(rangeEnd, in: tz).adding(minutes: 1440)
        var startPeriod = 0
        // Fast-forward long-running series that have no COUNT.
        if rule.count == nil {
            let earliest = LocalDateTime(rangeStart, in: tz).adding(minutes: -max(durationMinutes, 1440) - 1440).date
            if earliest > normStart.date {
                startPeriod = max(0, rule.periodsBetween(normStart.date, earliest) - 1)
            }
        }
        var results: [LocalDateTime] = []
        iterate(start: normStart, rule: rule, fromPeriod: startPeriod, tz: tz) { c in
            if c > endLocal { return false }
            if !exdates.contains(c.key(allDay: allDay)) && overlaps(c) { results.append(c) }
            return true
        }
        return results
    }
}
