import SwiftUI
import UIKit
import RoostKit

// MARK: - Color tokens (docs/DESIGN.md §12)

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let roostBG = dynamic(0xFAF7F2, 0x14110E)
    static let roostSurface = dynamic(0xFFFFFF, 0x1D1915)
    static let roostSurface2 = dynamic(0xF3EEE6, 0x27221C)
    static let roostLine = dynamic(0xE8E0D4, 0x38302A)
    static let roostInk = dynamic(0x1E1A16, 0xF5EFE7)
    static let roostInk2 = dynamic(0x5F564B, 0xBFB4A6)
    static let roostInk3 = dynamic(0x938878, 0x8C8174)
    static let ember = dynamic(0xD4572A, 0xF0784C)
    static let emberSoft = dynamic(0xFBE6DC, 0x3A2219)
    static let danger = dynamic(0xC93A3A, 0xF0706A)
}

/// The 12 person/calendar colors. Amber and lime take dark text.
enum Palette: String, CaseIterable, Identifiable {
    case red, orange, amber, lime, green, teal, cyan, blue, indigo, violet, pink, brown
    var id: String { rawValue }

    var hex: UInt32 {
        switch self {
        case .red: return 0xE5484D
        case .orange: return 0xF76B15
        case .amber: return 0xFFB224
        case .lime: return 0x99D52A
        case .green: return 0x30A46C
        case .teal: return 0x12A594
        case .cyan: return 0x05A2C2
        case .blue: return 0x0090FF
        case .indigo: return 0x3E63DD
        case .violet: return 0x8E4EC6
        case .pink: return 0xD6409F
        case .brown: return 0xAD7F58
        }
    }
    var color: Color { Color(hex: hex) }
    var onColor: Color { (self == .amber || self == .lime) ? Color(hex: 0x1E1A16) : .white }
    /// Soft tint for event backgrounds.
    var soft: Color { color.opacity(0.16) }

    static func named(_ s: String) -> Palette { Palette(rawValue: s) ?? .blue }
}

extension Font {
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

// MARK: - Components

struct Avatar: View {
    var member: Member?
    var size: CGFloat = 28
    var ring: Bool = false

    var body: some View {
        let p = Palette.named(member?.color ?? "brown")
        ZStack {
            Circle().fill(p.color)
            if let emoji = member?.emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.52))
            } else {
                Text(member?.initials.uppercased() ?? "?")
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(p.onColor)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.roostSurface, lineWidth: ring ? 2 : 0))
        .accessibilityLabel(member?.name ?? "Unknown")
    }
}

struct AvatarStack: View {
    var members: [Member]
    var size: CGFloat = 22
    var max: Int = 4

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(Array(members.prefix(max))) { m in Avatar(member: m, size: size, ring: true) }
            if members.count > max {
                Text("+\(members.count - max)").font(.caption2.weight(.bold)).foregroundStyle(Color.roostInk2)
                    .padding(.leading, size * 0.4)
            }
        }
    }
}

struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = .roostInk2
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(filled ? Color.white : tint)
        .background(Capsule().fill(filled ? tint : tint.opacity(0.12)))
    }
}

struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.ember)
                .padding(18)
                .background(Circle().fill(Color.emberSoft))
            Text(title).font(.rounded(.title3)).foregroundStyle(Color.roostInk)
            Text(message).font(.subheadline).foregroundStyle(Color.roostInk2).multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.roostSurface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.roostLine, lineWidth: 0.5))
    }
}

extension View {
    func roostCard() -> some View { modifier(CardBackground()) }
}

struct SectionTitle: View {
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.rounded(.headline)).foregroundStyle(Color.roostInk)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(Color.roostInk3) }
        }
    }
}

/// Small colored dot for calendars and categories.
struct Dot: View {
    var color: Color
    var size: CGFloat = 9
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

// MARK: - Formatting helpers

enum Fmt {
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
    static func range(_ o: Occurrence) -> String {
        if o.event.allDay {
            let days = Calendar.current.dateComponents([.day], from: o.start, to: o.end).day ?? 1
            return days > 1 ? "All day · \(days) days" : "All day"
        }
        return "\(time(o.start)) – \(time(o.end))"
    }
    static func reminder(_ m: Int, allDay: Bool) -> String {
        if allDay {
            switch m {
            case -540: return "9 AM on the day"
            case 900: return "9 AM the day before"
            case 2340: return "9 AM two days before"
            case 9540: return "9 AM a week before"
            default: break
            }
        }
        if m == 0 { return "At start" }
        if m % 10080 == 0 { return "\(m / 10080) week\(m == 10080 ? "" : "s") before" }
        if m % 1440 == 0 { return "\(m / 1440) day\(m == 1440 ? "" : "s") before" }
        if m % 60 == 0 { return "\(m / 60) hour\(m == 60 ? "" : "s") before" }
        return "\(m) min before"
    }
    static func due(_ t: TaskItem) -> String? {
        guard let d = t.dueLocal else { return nil }
        let date = d.toDate(in: .current)
        let day = Fmt.dayTitle(date)
        return t.dueHasTime ? "\(day), \(time(date))" : day
    }
    static func recurrence(_ rrule: String) -> String? {
        guard !rrule.isEmpty, let r = RRule(rrule) else { return nil }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let every = r.interval > 1 ? "Every \(r.interval) " : "Every "
        switch r.freq {
        case .daily: return r.interval > 1 ? "\(every)days" : "Daily"
        case .weekly:
            let days = r.byDay.map { names[$0.weekday] }
            if days == ["Mon", "Tue", "Wed", "Thu", "Fri"] { return "Weekdays" }
            let unit = r.interval > 1 ? "\(every)weeks" : "Weekly"
            return days.isEmpty ? unit : "\(unit) on \(days.joined(separator: ", "))"
        case .monthly:
            if let d = r.byDay.first, let o = d.ordinal {
                let ord = o < 0 ? (o == -1 ? "last" : "\(-o)th-to-last") : ["", "1st", "2nd", "3rd", "4th", "5th"][min(o, 5)]
                return "Monthly on the \(ord) \(names[d.weekday])"
            }
            return r.interval > 1 ? "\(every)months" : "Monthly"
        case .yearly: return "Yearly"
        }
    }
}
