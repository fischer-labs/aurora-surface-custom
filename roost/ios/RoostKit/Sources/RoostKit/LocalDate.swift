import Foundation

/// A wall-clock date (no time zone). Arithmetic is pure integer math so
/// recurrence expansion is deterministic on every platform.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// Days since 1970-01-01 (proleptic Gregorian). Howard Hinnant's algorithm.
    public var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(dayNumber z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int { ((dayNumber % 7) + 11) % 7 }

    public func adding(days: Int) -> LocalDate { LocalDate(dayNumber: dayNumber + days) }

    public func adding(months: Int) -> (year: Int, month: Int) {
        let total = year * 12 + (month - 1) + months
        return (total / 12, total % 12 + 1)
    }

    public static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    public static func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m)
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { a.dayNumber < b.dayNumber }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public init?(iso: String) {
        let p = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, LocalDate.valid(p[0], p[1], p[2]) else { return nil }
        self.init(p[0], p[1], p[2])
    }
}

/// A wall-clock date and time to the minute.
public struct LocalDateTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var date: LocalDate
    public var hour: Int
    public var minute: Int

    public init(_ date: LocalDate, _ hour: Int = 0, _ minute: Int = 0) {
        self.date = date; self.hour = hour; self.minute = minute
    }

    public var minuteNumber: Int { date.dayNumber * 1440 + hour * 60 + minute }

    public init(minuteNumber n: Int) {
        let day = Int((Double(n) / 1440).rounded(.down))
        let rem = n - day * 1440
        self.init(LocalDate(dayNumber: day), rem / 60, rem % 60)
    }

    public func adding(minutes: Int) -> LocalDateTime { LocalDateTime(minuteNumber: minuteNumber + minutes) }

    public static func < (a: LocalDateTime, b: LocalDateTime) -> Bool { a.minuteNumber < b.minuteNumber }

    public var description: String { date.description + String(format: "T%02d:%02d", hour, minute) }
    public var timeString: String { String(format: "%02d:%02d", hour, minute) }

    /// Parses "YYYY-MM-DD" or "YYYY-MM-DDTHH:mm".
    public init?(iso: String) {
        guard let d = LocalDate(iso: iso) else { return nil }
        if iso.count >= 16 {
            let t = iso.dropFirst(11).prefix(5).split(separator: ":").compactMap { Int($0) }
            guard t.count == 2 else { return nil }
            self.init(d, t[0], t[1])
        } else {
            self.init(d)
        }
    }

    /// Occurrence key (DESIGN §4).
    public func key(allDay: Bool) -> String { allDay ? date.description : description }

    // MARK: Time zone conversion

    public func toDate(in tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute)
        return cal.date(from: c) ?? Date(timeIntervalSince1970: TimeInterval(minuteNumber * 60))
    }

    public init(_ instant: Date, in tz: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        self.init(LocalDate(c.year ?? 1970, c.month ?? 1, c.day ?? 1), c.hour ?? 0, c.minute ?? 0)
    }
}

public extension TimeZone {
    /// Resolves an IANA identifier, falling back to the current zone.
    static func roost(_ identifier: String?) -> TimeZone {
        if let id = identifier, !id.isEmpty, let tz = TimeZone(identifier: id) { return tz }
        return .current
    }
}
