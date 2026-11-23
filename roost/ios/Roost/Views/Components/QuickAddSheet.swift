import SwiftUI
import RoostKit

/// "Soccer every Tue 4-5:30pm @Emma driver:Dad remind 30m" → an event or a to-do.
struct QuickAddSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var mode: QuickAddMode
    var defaultList: String? = nil
    @State private var text = ""
    @State private var openEditor = false
    @FocusState private var focused: Bool

    private var parsed: QuickAddResult {
        QuickAddParser.parse(text, now: LocalDateTime(Date(), in: .current), mode: mode)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Type", selection: $mode) {
                    Text("Event").tag(QuickAddMode.event)
                    Text("To-do").tag(QuickAddMode.task)
                }
                .pickerStyle(.segmented)

                TextField(mode == .event ? "Dentist Friday 3pm @Emma" : "Call pediatrician tomorrow 9am !!", text: $text, axis: .vertical)
                    .font(.title3)
                    .focused($focused)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.roostSurface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.roostLine))
                    .submitLabel(.done)
                    .onSubmit(add)

                if !text.isEmpty { preview }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Try").font(.caption.weight(.bold)).foregroundStyle(Color.roostInk3)
                    ForEach(examples, id: \.self) { ex in
                        Button { text = ex } label: {
                            Text(ex).font(.footnote).foregroundStyle(Color.roostInk2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(Color.roostBG)
            .navigationTitle("Quick add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add).disabled(parsed.title.isEmpty).bold() }
                ToolbarItem(placement: .bottomBar) {
                    Button("More options…") { openEditor = true }.disabled(parsed.title.isEmpty)
                }
            }
            .onAppear { focused = true }
            .sheet(isPresented: $openEditor) {
                if mode == .event {
                    EventEditor(event: buildEvent(), isNew: true, onSaved: { dismiss() })
                } else {
                    NavigationStack { TaskEditor(task: buildTask(), isNew: true, onSaved: { dismiss() }) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var examples: [String] {
        mode == .event
            ? ["Soccer every Tue 4-5:30pm @Emma driver:Dad", "Grandma's birthday dec 3", "Book club every first tuesday 7pm"]
            : ["Pay water bill due 12/1 !", "Take out trash every weekday", "Call pediatrician tomorrow 9am @Me"]
    }

    @ViewBuilder private var preview: some View {
        let p = parsed
        FlowChips {
            if let d = p.date {
                let date = LocalDateTime(d, (p.timeMinutes ?? 0) / 60, (p.timeMinutes ?? 0) % 60).toDate(in: .current)
                Chip(text: Fmt.dayTitle(date), systemImage: "calendar", tint: .ember)
                if p.timeMinutes != nil {
                    let end = p.end?.toDate(in: .current)
                    Chip(text: end.map { "\(Fmt.time(date))–\(Fmt.time($0))" } ?? Fmt.time(date), systemImage: "clock", tint: .ember)
                } else if mode == .event {
                    Chip(text: "All day", systemImage: "sun.max", tint: .ember)
                }
            }
            if let r = p.rrule, let label = Fmt.recurrence(r) { Chip(text: label, systemImage: "repeat", tint: .ember) }
            ForEach(resolve(p.mentions)) { m in Chip(text: m.name, systemImage: "person.fill", tint: Palette.named(m.color).color) }
            if let d = p.driver.flatMap({ resolve([$0]).first }) { Chip(text: d.name, systemImage: "car.fill", tint: Palette.named(d.color).color) }
            if let tag = p.tag { Chip(text: tag, systemImage: "number", tint: .roostInk2) }
            if p.priority > 0 { Chip(text: String(repeating: "!", count: p.priority), systemImage: "flag.fill", tint: .orange) }
            ForEach(p.reminders, id: \.self) { m in Chip(text: Fmt.reminder(m, allDay: false), systemImage: "bell.fill", tint: .roostInk2) }
        }
    }

    private func resolve(_ names: [String]) -> [Member] {
        names.compactMap { n in
            if n.lowercased() == "me" { return store.me }
            let l = n.lowercased()
            return store.members.first { $0.name.lowercased() == l } ?? store.members.first { $0.name.lowercased().hasPrefix(l) }
        }
    }

    private func buildEvent() -> CalendarEvent {
        let p = parsed
        let tz = TimeZone.current
        let day = p.date ?? LocalDateTime(Date(), in: tz).date
        let start = (p.start ?? LocalDateTime(day)).toDate(in: tz)
        let calId = p.tag.flatMap { tag in store.editableCalendars.first { $0.name.lowercased() == tag.lowercased() }?.id }
        var e = store.newEvent(start: start, allDay: p.allDay, calendarId: calId)
        e.title = p.title
        e.tz = tz.identifier
        if let end = p.end { e.end = end.toDate(in: tz) }
        if p.allDay { e.end = LocalDateTime(day.adding(days: 1)).toDate(in: tz) }
        e.rrule = p.rrule ?? ""
        e.members = resolve(p.mentions).map(\.id)
        e.driver = p.driver.flatMap { resolve([$0]).first?.id } ?? ""
        if !p.reminders.isEmpty { e.reminders = p.reminders }
        return e
    }

    private func buildTask() -> TaskItem {
        let p = parsed
        let listId = p.tag.flatMap { tag in store.taskLists.first { $0.name.lowercased() == tag.lowercased() }?.id }
            ?? defaultList ?? store.taskLists.first(where: store.canEdit)?.id ?? ""
        var t = store.newTask(list: listId, title: p.title)
        if let d = p.date { t.due = p.timeMinutes != nil ? p.start!.description : d.description }
        t.rrule = p.rrule ?? ""
        t.assignees = resolve(p.mentions).map(\.id)
        t.priority = p.priority
        t.reminders = p.reminders.isEmpty && p.timeMinutes != nil ? [0] : p.reminders
        return t
    }

    private func add() {
        guard !parsed.title.isEmpty else { return }
        if mode == .event {
            let e = buildEvent()
            guard !e.calendar.isEmpty else { return }
            store.save(event: e)
        } else {
            let t = buildTask()
            guard !t.list.isEmpty else { return }
            store.save(task: t)
        }
        dismiss()
    }
}

/// Wrapping row of chips.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FlowLayout(spacing: 6) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
