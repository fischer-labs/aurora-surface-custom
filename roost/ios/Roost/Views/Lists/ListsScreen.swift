import SwiftUI
import UIKit
import RoostKit

enum SmartList: String, CaseIterable, Identifiable, Hashable {
    case today, upcoming, mine, overdue, flagged
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .mine: return "Assigned to me"
        case .overdue: return "Overdue"
        case .flagged: return "Priority"
        }
    }
    var icon: String {
        switch self {
        case .today: return "sun.max.fill"
        case .upcoming: return "calendar"
        case .mine: return "person.crop.circle.fill"
        case .overdue: return "exclamationmark.circle.fill"
        case .flagged: return "flag.fill"
        }
    }
    var color: Color {
        switch self {
        case .today: return Palette.blue.fill
        case .upcoming: return Palette.violet.fill
        case .mine: return Palette.green.fill
        case .overdue: return Palette.red.fill
        case .flagged: return Palette.red.fill
        }
    }

    @MainActor
    func tasks(_ store: FamilyStore) -> [TaskItem] {
        let today = LocalDateTime(Date(), in: .current).date.description
        let open = store.tasks.filter { !$0.deleted && !$0.completed && $0.parent.isEmpty }
        switch self {
        case .today: return open.filter { !$0.due.isEmpty && String($0.due.prefix(10)) <= today }.sorted { $0.due < $1.due }
        case .upcoming: return open.filter { String($0.due.prefix(10)) > today }.sorted { $0.due < $1.due }
        case .mine: return open.filter { t in store.me.map { t.assignees.contains($0.id) } ?? false }.sorted(by: TaskSort.default)
        case .overdue: return open.filter { !$0.due.isEmpty && String($0.due.prefix(10)) < today }.sorted { $0.due < $1.due }
        case .flagged: return open.filter { $0.priority > 0 }.sorted { $0.priority > $1.priority }
        }
    }
}

enum TaskSort {
    static func `default`(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.completed != b.completed { return !a.completed }
        if a.due.isEmpty != b.due.isEmpty { return !a.due.isEmpty }
        if a.due != b.due { return a.due < b.due }
        if a.priority != b.priority { return a.priority > b.priority }
        return a.sortOrder < b.sortOrder
    }
}

enum ListRoute: Hashable { case smart(SmartList), list(String) }

struct ListsScreen: View {
    @Environment(FamilyStore.self) private var store
    @State private var newList: TaskList?
    @State private var showQuickAdd = false
    @State private var path: [ListRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(SmartList.allCases) { s in
                            // A plain button: a NavigationLink in a List row adds a chevron that floats in the gutter.
                            Button { path.append(.smart(s)) } label: { smartTile(s) }.buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("Lists") {
                    ForEach(store.taskLists) { l in
                        NavigationLink(value: ListRoute.list(l.id)) {
                            HStack(spacing: 12) {
                                Image(systemName: l.kind == .packing ? "suitcase.fill" : "checklist")
                                    .foregroundStyle(Palette.named(l.color).onColor).frame(width: 32, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.named(l.color).fill))
                                Text(l.name).font(.body.weight(.medium))
                                Spacer()
                                let n = store.tasks.filter { $0.list == l.id && !$0.deleted && !$0.completed && $0.parent.isEmpty }.count
                                if n > 0 { Text("\(n)").foregroundStyle(Color.roostInk3) }
                            }
                        }
                        .listRowBackground(Color.roostSurface)
                    }
                    if store.taskLists.isEmpty {
                        Text("No lists are shared with you yet. To-dos assigned to you show up in “Assigned to me”.")
                            .font(.subheadline).foregroundStyle(Color.roostInk2)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roostBG)
            .navigationTitle("To-Dos")
            .navigationDestination(for: ListRoute.self) { route in
                switch route {
                case .smart(let s): SmartListView(smart: s)
                case .list(let id): TaskListView(listId: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showQuickAdd = true } label: { Label("Quick add to-do", systemImage: "text.cursor") }
                            .disabled(!store.taskLists.contains(where: store.canEdit))
                        if store.myRole != .relative && store.myRole != .kid {
                            Button { newList = TaskList(id: RecordID.make(), family: store.family.id, name: "", kind: .todo, color: "blue") } label: {
                                Label("New list", systemImage: "plus.rectangle.on.rectangle")
                            }
                        }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .sheet(item: $newList) { l in ListSettingsSheet(list: l, isNew: true) }
            .sheet(isPresented: $showQuickAdd) { QuickAddSheet(mode: .task) }
        }
    }

    private func smartTile(_ s: SmartList) -> some View {
        let count = s.tasks(store).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: s.icon).font(.title3).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Circle().fill(s.color))
                    .opacity(count == 0 && s == .overdue ? 0.35 : 1)
                Spacer()
                Text("\(count)").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Color.roostInk)
            }
            Text(s.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.roostInk2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.roostSurface))
    }
}

struct SmartListView: View {
    @Environment(FamilyStore.self) private var store
    var smart: SmartList

    var body: some View {
        let tasks = smart.tasks(store)
        List {
            if tasks.isEmpty {
                EmptyState(systemImage: smart.icon, title: "All clear", message: "Nothing here right now.")
                    .listRowBackground(Color.clear)
            }
            ForEach(tasks) { t in TaskRow(task: t, showList: true).listRowBackground(Color.roostSurface) }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle(smart.title)
    }
}

struct TaskListView: View {
    @Environment(FamilyStore.self) private var store
    var listId: String
    @State private var quick = ""
    @State private var showDone = false
    @State private var settings = false

    private var list: TaskList? { store.list(listId) }

    var body: some View {
        let all = store.tasks.filter { $0.list == listId && !$0.deleted && $0.parent.isEmpty }
        let open = all.filter { !$0.completed }.sorted(by: TaskSort.default)
        let done = all.filter(\.completed).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let editable = list.map(store.canEdit) ?? false
        List {
            if editable {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.ember)
                        TextField("Add a to-do — try “Call dentist fri 2pm !”", text: $quick)
                            .submitLabel(.done)
                            .onSubmit(addQuick)
                    }
                    if !quick.isEmpty {
                        let p = QuickAddParser.parse(quick, now: LocalDateTime(Date(), in: .current), mode: .task)
                        if p.date != nil || p.rrule != nil || p.priority > 0 || !p.mentions.isEmpty {
                            Text(previewText(p)).font(.caption).foregroundStyle(Color.roostInk2)
                        }
                    }
                }
            }
            Section {
                if open.isEmpty {
                    Text("Nothing to do. Nice.").foregroundStyle(Color.roostInk3)
                }
                ForEach(open) { t in TaskRow(task: t, showList: false).listRowBackground(Color.roostSurface) }
                    .onMove(perform: editable ? move : nil)
            }
            if !done.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showDone) {
                        ForEach(done.prefix(50)) { t in TaskRow(task: t, showList: false).listRowBackground(Color.roostSurface) }
                    } label: {
                        Text("Completed (\(done.count))").font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle(list?.name ?? "List")
        .toolbar {
            if let l = list, store.isAdmin || l.owner == store.me?.id {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $settings) { if let l = list { ListSettingsSheet(list: l, isNew: false) } }
    }

    private func previewText(_ p: QuickAddResult) -> String {
        var parts: [String] = []
        if let s = p.start { parts.append(Fmt.dayTitle(s.toDate(in: .current)) + (p.timeMinutes != nil ? " " + Fmt.time(s.toDate(in: .current)) : "")) }
        if let r = p.rrule.flatMap(Fmt.recurrence) { parts.append(r) }
        if p.priority > 0 { parts.append(String(repeating: "!", count: p.priority)) }
        if !p.mentions.isEmpty { parts.append(p.mentions.map { "@" + $0 }.joined(separator: " ")) }
        return "→ " + p.title + " · " + parts.joined(separator: " · ")
    }

    private func addQuick() {
        let text = quick.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let p = QuickAddParser.parse(text, now: LocalDateTime(Date(), in: .current), mode: .task)
        var t = store.newTask(list: listId, title: p.title.isEmpty ? text : p.title)
        if let s = p.start { t.due = p.timeMinutes != nil ? s.description : s.date.description }
        t.rrule = p.rrule ?? ""
        t.priority = p.priority
        t.reminders = p.reminders.isEmpty && p.timeMinutes != nil ? [0] : p.reminders
        t.assignees = p.mentions.compactMap { name in
            name.lowercased() == "me" ? store.me?.id : store.members.first { $0.name.lowercased().hasPrefix(name.lowercased()) }?.id
        }
        store.save(task: t)
        quick = ""
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var open = store.tasks.filter { $0.list == listId && !$0.deleted && !$0.completed && $0.parent.isEmpty }.sorted(by: TaskSort.default)
        open.move(fromOffsets: from, toOffset: to)
        for (i, item) in open.enumerated() where item.sortOrder != Double(i) {
            var t = item
            t.sortOrder = Double(i)
            store.save(task: t)
        }
    }
}

struct TaskRow: View {
    @Environment(FamilyStore.self) private var store
    var task: TaskItem
    var showList: Bool
    @State private var editing = false

    var body: some View {
        let overdue = !task.completed && !task.due.isEmpty && String(task.due.prefix(10)) < LocalDateTime(Date(), in: .current).date.description
        let subs = store.subtasks(of: task)
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.snappy) { store.toggle(task: task) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(task.completed ? Color.emberFill : Color.roostInk3)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -8).padding(.leading, -8)
            .disabled(!store.canEdit(task))
            .accessibilityLabel(task.completed ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if task.priority > 0 {
                        Text(String(repeating: "!", count: task.priority)).font(.body.weight(.heavy)).foregroundStyle(Color.danger)
                    }
                    Text(task.title).strikethrough(task.completed).foregroundStyle(task.completed ? Color.roostInk3 : Color.roostInk)
                }
                HStack(spacing: 8) {
                    if let due = Fmt.due(task) {
                        Label(due, systemImage: task.rrule.isEmpty ? "calendar" : "repeat")
                            .font(.caption.weight(.medium)).foregroundStyle(overdue ? Color.danger : Color.roostInk2)
                    }
                    if !subs.isEmpty {
                        Label("\(subs.filter(\.completed).count)/\(subs.count)", systemImage: "list.bullet").font(.caption).foregroundStyle(Color.roostInk3)
                    }
                    if !task.notes.isEmpty { Image(systemName: "note.text").font(.caption).foregroundStyle(Color.roostInk3) }
                    if showList, let l = store.list(task.list) { Text(l.name).font(.caption).foregroundStyle(Color.roostInk3) }
                }
            }
            Spacer(minLength: 0)
            AvatarStack(members: store.members(task.assignees), size: 22, max: 3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .swipeActions(edge: .trailing) {
            if store.list(task.list).map(store.canEdit) ?? false {
                Button(role: .destructive) { store.delete(task: task) } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $editing) { NavigationStack { TaskEditor(task: task, isNew: false) } }
    }
}

struct TaskEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    var isNew: Bool
    var onSaved: (() -> Void)? = nil
    @State private var hasDue = false
    @State private var hasTime = false
    @State private var dueDate = Date()
    @State private var preset: RepeatPreset = .none
    @State private var newSub = ""

    private var editable: Bool { isNew || store.canEdit(task) }

    var body: some View {
        Form {
            Section {
                TextField("To-do", text: $task.title).font(.title3.weight(.semibold))
                TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(2...8)
            }
            Section {
                Toggle("Due date", isOn: $hasDue.animation())
                if hasDue {
                    DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                    Toggle("Time", isOn: $hasTime.animation())
                    if hasTime { DatePicker("Time", selection: $dueDate, displayedComponents: .hourAndMinute) }
                    Picker("Repeat", selection: $preset) {
                        ForEach(RepeatPreset.allCases.filter { $0 != .custom || preset == .custom }) { p in Text(p.label(for: dueDate)).tag(p) }
                    }
                }
            }
            if hasDue {
                Section("Remind") {
                    ReminderPicker(selection: $task.reminders, allDay: !hasTime)
                }
            }
            Section("Assign to") { MemberPicker(selection: $task.assignees) }
            Section {
                Picker("Priority", selection: $task.priority) {
                    Text("None").tag(0); Text("Low !").tag(1); Text("Medium !!").tag(2); Text("High !!!").tag(3)
                }
                Picker("List", selection: $task.list) {
                    ForEach(store.taskLists.filter(store.canEdit)) { l in Text(l.name).tag(l.id) }
                }
            }
            if !isNew {
                Section("Subtasks") {
                    ForEach(store.subtasks(of: task)) { s in
                        HStack {
                            Button { store.toggle(task: s) } label: {
                                Image(systemName: s.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(s.completed ? Color.ember : Color.roostInk3)
                            }
                            .buttonStyle(.plain)
                            Text(s.title).strikethrough(s.completed)
                        }
                        .swipeActions { Button(role: .destructive) { store.delete(task: s) } label: { Label("Delete", systemImage: "trash") } }
                    }
                    HStack {
                        Image(systemName: "plus").foregroundStyle(Color.roostInk3)
                        TextField("Add subtask", text: $newSub).onSubmit {
                            guard !newSub.isEmpty else { return }
                            var s = store.newTask(list: task.list, title: newSub)
                            s.parent = task.id
                            store.save(task: s)
                            newSub = ""
                        }
                    }
                }
                if let by = store.members.first(where: { $0.user == task.createdBy }) {
                    Section { Text("Added by \(by.name)").font(.footnote).foregroundStyle(Color.roostInk3) }
                }
            }
        }
        .disabled(!editable && !isAssignee)
        .scrollContentBackground(.hidden)
        .background(Color.roostBG)
        .navigationTitle(isNew ? "New to-do" : "To-do")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).bold().disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty || task.list.isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private var isAssignee: Bool { store.me.map { task.assignees.contains($0.id) } ?? false }

    private func load() {
        if let d = task.dueLocal {
            hasDue = true
            hasTime = task.dueHasTime
            dueDate = d.toDate(in: .current)
        } else {
            dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        }
        preset = RepeatPreset.detect(task.rrule, start: dueDate)
        if task.list.isEmpty { task.list = store.taskLists.first(where: store.canEdit)?.id ?? "" }
    }

    private func save() {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespaces)
        if hasDue {
            let l = LocalDateTime(dueDate, in: .current)
            t.due = hasTime ? l.description : l.date.description
            t.rrule = preset == .custom ? t.rrule : preset.rrule(for: dueDate)
        } else {
            t.due = ""
            t.rrule = ""
            t.reminders = []
        }
        store.save(task: t)
        if !t.reminders.isEmpty { Task { _ = await ReminderScheduler.shared.requestPermission() } }
        onSaved?()
        dismiss()
    }
}

struct ListSettingsSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var list: TaskList
    var isNew: Bool
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("List name", text: $list.name)
                    if isNew {
                        Picker("Kind", selection: $list.kind) {
                            Text("To-do").tag(TaskList.Kind.todo)
                            Text("Groceries").tag(TaskList.Kind.grocery)
                            Text("Packing").tag(TaskList.Kind.packing)
                        }
                    }
                    ColorRow(selection: $list.color)
                }
                if !store.isLocal && (store.isAdmin || isNew) {
                    Section {
                        SharingEditor(sharing: $list.sharing, resource: "list", subkind: list.kind.rawValue, ownerId: list.owner)
                    } header: { Text("Who can see this list") }
                }
                if !isNew {
                    Section {
                        Button("Delete list", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New list" : "List settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.save(list: list); dismiss() }.bold().disabled(list.name.isEmpty)
                }
            }
            .confirmationDialog("Delete “\(list.name)” and its items?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    var l = list
                    l.deleted = true
                    store.save(list: l)
                    dismiss()
                }
            }
        }
    }
}

/// Picks one of the 12 palette colors.
struct ColorRow: View {
    @Binding var selection: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Palette.allCases) { p in
                    Circle().fill(p.color).frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color.roostInk, lineWidth: selection == p.rawValue ? 2.5 : 0).padding(-3))
                        .onTapGesture { selection = p.rawValue }
                        .accessibilityLabel(p.rawValue.capitalized)
                        .accessibilityAddTraits(selection == p.rawValue ? .isSelected : [])
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }
}
