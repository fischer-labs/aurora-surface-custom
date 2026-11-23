import SwiftUI
import RoostKit

/// Day, 3-Day, Week and People views: a scrolling 24-hour grid.
struct TimeGridView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    @Binding var anchor: Date
    var days: Int
    var byPeople: Bool = false
    var onNew: (Date) -> Void

    static let hourHeight: CGFloat = 56
    static let gutter: CGFloat = 44

    struct Column: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var day: Date
        var member: Member?
        var highlight: Bool
    }

    private var cal: Calendar { Calendar.current }

    /// For multi-day views the window starts at the anchor (3-day) or week start (week).
    private var firstDay: Date {
        let d = cal.startOfDay(for: anchor)
        guard days == 7 else { return d }
        let wd = cal.component(.weekday, from: d)
        return cal.date(byAdding: .day, value: -((wd - cal.firstWeekday + 7) % 7), to: d)!
    }

    private var columns: [Column] {
        if byPeople {
            var cols = store.sortedMembers.map { m in
                Column(id: m.id, title: m.name.split(separator: " ").first.map(String.init) ?? m.name, subtitle: "", day: firstDay, member: m, highlight: false)
            }
            cols.append(Column(id: "_family", title: "Everyone", subtitle: "", day: firstDay, member: nil, highlight: false))
            return cols
        }
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: i, to: firstDay)!
            return Column(id: d.description, title: d.formatted(.dateTime.weekday(.abbreviated)), subtitle: d.formatted(.dateTime.day()),
                          day: d, member: nil, highlight: cal.isDateInToday(d))
        }
    }

    var body: some View {
        let cols = columns
        let windowEnd = cal.date(byAdding: .day, value: byPeople ? 1 : days, to: firstDay)!
        let items = CalItem.build(store: store, prefs: prefs, device: device, from: firstDay, to: windowEnd)
        GeometryReader { geo in
            let colWidth = max((geo.size.width - TimeGridView.gutter) / CGFloat(cols.count), byPeople ? 92 : 40)
            let contentWidth = TimeGridView.gutter + colWidth * CGFloat(cols.count)
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        header(cols, colWidth: colWidth)
                        allDayRow(cols, items: items, colWidth: colWidth)
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                ZStack(alignment: .topLeading) {
                                    hourLines(width: contentWidth)
                                    ForEach(Array(cols.enumerated()), id: \.element.id) { idx, col in
                                        columnBody(col, items: timedItems(for: col, in: items), width: colWidth)
                                            .frame(width: colWidth, height: TimeGridView.hourHeight * 24)
                                            .offset(x: TimeGridView.gutter + CGFloat(idx) * colWidth)
                                    }
                                }
                                .frame(width: contentWidth, height: TimeGridView.hourHeight * 24, alignment: .topLeading)
                            }
                            .onAppear { proxy.scrollTo(scrollHour, anchor: .top) }
                            .onChange(of: anchor) { _, _ in proxy.scrollTo(scrollHour, anchor: .top) }
                        }
                    }
                    .frame(width: contentWidth)
                }
                .scrollDisabled(contentWidth <= geo.size.width + 1)
            }
        }
        .gesture(DragGesture(minimumDistance: 40).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            let step = byPeople ? 1 : days
            withAnimation(.snappy) { anchor = cal.date(byAdding: .day, value: v.translation.width < 0 ? step : -step, to: anchor)! }
        })
    }

    private var scrollHour: Int {
        cal.isDateInToday(anchor) ? max(0, cal.component(.hour, from: Date()) - 1) : 7
    }

    private func header(_ cols: [Column], colWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: TimeGridView.gutter)
            ForEach(cols) { c in
                VStack(spacing: 2) {
                    if let m = c.member {
                        Avatar(member: m, size: 26)
                        Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(Color.roostInk).lineLimit(1)
                    } else if byPeople {
                        Image(systemName: "house.fill").foregroundStyle(Color.ember).frame(height: 26)
                        Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(Color.roostInk)
                    } else {
                        Text(c.title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(c.highlight ? Color.ember : Color.roostInk3)
                        Text(c.subtitle).font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(c.highlight ? Color.white : Color.roostInk)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(c.highlight ? Color.ember : .clear))
                    }
                }
                .frame(width: colWidth)
                .contentShape(Rectangle())
                .onTapGesture { if !byPeople && days > 1 { anchor = c.day } }
            }
        }
        .padding(.vertical, 6)
    }

    private func allDayRow(_ cols: [Column], items: [CalItem], colWidth: CGFloat) -> some View {
        let maxRows = cols.map { allDayItems(for: $0, in: items).count }.max() ?? 0
        return Group {
            if maxRows > 0 {
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.roostInk3)
                        .frame(width: TimeGridView.gutter, alignment: .trailing).padding(.trailing, 4).padding(.top, 4)
                    ForEach(cols) { c in
                        VStack(spacing: 2) {
                            ForEach(allDayItems(for: c, in: items).prefix(3)) { item in
                                NavigationLink(value: item) {
                                    Text(item.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(item.isBusy ? Color.roostInk3 : item.color))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                        .frame(width: colWidth, alignment: .top)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func belongs(_ item: CalItem, to col: Column) -> Bool {
        guard byPeople else { return true }
        if let m = col.member { return item.memberIds.contains(m.id) || item.driverId == m.id }
        return item.memberIds.isEmpty && item.driverId.isEmpty
    }

    private func allDayItems(for col: Column, in items: [CalItem]) -> [CalItem] {
        let dayEnd = cal.date(byAdding: .day, value: 1, to: col.day)!
        return items.filter { $0.allDay && $0.start < dayEnd && $0.end > col.day && belongs($0, to: col) }
    }

    private func timedItems(for col: Column, in items: [CalItem]) -> [CalItem] {
        let dayEnd = cal.date(byAdding: .day, value: 1, to: col.day)!
        return items.filter { !$0.allDay && $0.start < dayEnd && $0.end > col.day && belongs($0, to: col) }
    }

    private func hourLines(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                HStack(alignment: .top, spacing: 4) {
                    Text(h == 0 ? "" : hourLabel(h))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.roostInk3)
                        .frame(width: TimeGridView.gutter - 6, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle().fill(Color.roostLine).frame(height: 0.5)
                }
                .frame(width: width, height: TimeGridView.hourHeight, alignment: .topLeading)
                .id(h)
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let d = cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        return d.formatted(.dateTime.hour())
    }

    private func columnBody(_ col: Column, items: [CalItem], width: CGFloat) -> some View {
        let dayStart = col.day
        let minutes: (Date) -> Int = { d in max(0, min(1440, Int(d.timeIntervalSince(dayStart) / 60))) }
        let layout = DayLayout.layout(items.map { LayoutItem(id: $0.id, start: minutes($0.start), end: minutes($0.end)) })
        let hh = TimeGridView.hourHeight
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(col.highlight ? Color.emberSoft.opacity(0.25) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { pt in
                    let mins = Int(pt.y / hh * 60) / 15 * 15
                    if let d = cal.date(byAdding: .minute, value: mins, to: dayStart), !store.editableCalendars.isEmpty { onNew(d) }
                }
            Rectangle().fill(Color.roostLine).frame(width: 0.5)
            ForEach(items) { item in
                let slot = layout[item.id] ?? LayoutSlot(col: 0, cols: 1)
                let top = CGFloat(minutes(item.start)) / 60 * hh
                let height = max(CGFloat(minutes(item.end) - minutes(item.start)) / 60 * hh, 20)
                let w = (width - 3) / CGFloat(slot.cols)
                NavigationLink(value: item) { EventBlock(item: item, compact: w < 60 || height < 34) }
                    .buttonStyle(.plain)
                    .frame(width: w - 1, height: height - 1)
                    .offset(x: 1.5 + CGFloat(slot.col) * w, y: top)
            }
            if cal.isDateInToday(dayStart) {
                let y = CGFloat(minutes(Date())) / 60 * hh
                HStack(spacing: 0) {
                    Circle().fill(Color.ember).frame(width: 7, height: 7)
                    Rectangle().fill(Color.ember).frame(height: 1.5)
                }
                .offset(x: -3, y: y - 3.5)
                .allowsHitTesting(false)
            }
        }
    }
}

struct EventBlock: View {
    var item: CalItem
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if item.task != nil { Image(systemName: "circle").font(.system(size: 9, weight: .bold)) }
                Text(item.title).font(.system(size: compact ? 10 : 12, weight: .semibold)).lineLimit(compact ? 1 : 2)
            }
            if !compact {
                Text(Fmt.time(item.start)).font(.system(size: 10)).opacity(0.8)
                if !item.location.isEmpty { Text(item.location).font(.system(size: 10)).lineLimit(1).opacity(0.8) }
            }
        }
        .foregroundStyle(item.isBusy ? Color.roostInk2 : Color.roostInk)
        .padding(.horizontal, 4).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(item.isBusy ? Color.roostSurface2 : item.color.opacity(item.isDevice ? 0.12 : 0.22))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(item.isBusy ? Color.roostInk3 : item.color).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(item.isDevice ? item.color.opacity(0.6) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
