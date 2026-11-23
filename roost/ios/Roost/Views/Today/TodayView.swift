import SwiftUI
import RoostKit

struct TodayView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(CalendarPrefs.self) private var prefs
    @Environment(DeviceCalendars.self) private var device
    var selectTab: (MainTab) -> Void
    @State private var showQuickAdd = false
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    nowNext
                    todaySection
                    tasksSection
                    grocerySection
                    cardsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color.roostBG.ignoresSafeArea())
            .refreshable { await store.syncNow() }
            .navigationDestination(for: CalItem.self) { ItemDetailRouter(item: $0) }
            .navigationDestination(for: InfoCard.self) { InfoCardDetail(card: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showQuickAdd = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                        .accessibilityLabel("Quick add")
                }
                ToolbarItem(placement: .topBarLeading) { SyncBadge() }
            }
            .sheet(isPresented: $showQuickAdd) { QuickAddSheet(mode: .event) }
            .onReceive(timer) { now = $0 }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: now)
        let part = h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
        if let name = store.me?.name.split(separator: " ").first { return "\(part), \(name)" }
        return part
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Color.ember)
            Text(greeting).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Color.roostInk)
            Text(store.family.name).font(.subheadline).foregroundStyle(Color.roostInk2)
        }
        .padding(.top, 8)
    }

    private var todayItems: [CalItem] {
        let start = Calendar.current.startOfDay(for: now)
        return CalItem.build(store: store, prefs: prefs, device: device, from: start, to: start.addingTimeInterval(86400))
            .filter { $0.task == nil }
    }

    @ViewBuilder private var nowNext: some View {
        let upcoming = todayItems.filter { !$0.allDay && $0.end > now }
        if let next = upcoming.first {
            let isNow = next.start <= now
            NavigationLink(value: next) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isNow ? "HAPPENING NOW" : "UP NEXT").font(.caption2.weight(.heavy)).tracking(1).foregroundStyle(.white.opacity(0.85))
                        Text(next.title).font(.rounded(.title3, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                        Text(isNow ? "until \(Fmt.time(next.end))" : "\(Fmt.time(next.start)) · \(relative(next.start))")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                        if let d = store.member(next.driverId) {
                            Label("\(d.name) is driving", systemImage: "car.fill").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                    }
                    Spacer()
                    AvatarStack(members: store.members(next.memberIds), size: 30, max: 3)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [next.color, next.color.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: next.color.opacity(0.25), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
        }
    }

    private func relative(_ d: Date) -> String {
        let mins = Int(d.timeIntervalSince(now) / 60)
        if mins < 60 { return "in \(max(mins, 1)) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "in \(h) hr" : "in \(h) hr \(m) min"
    }

    @ViewBuilder private var todaySection: some View {
        let items = todayItems
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Today", trailing: items.isEmpty ? nil : "\(items.count) event\(items.count == 1 ? "" : "s")")
            if items.isEmpty {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(Color.ember)
                    Text("Nothing scheduled. Enjoy the quiet.").foregroundStyle(Color.roostInk2)
                }
                .font(.subheadline)
                .roostCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { CalItemRow(item: item) }.buttonStyle(.plain)
                        if item.id != items.last?.id { Divider().padding(.leading, 78) }
                    }
                }
                .roostCard()
            }
        }
    }

    @ViewBuilder private var tasksSection: some View {
        let today = LocalDateTime(now, in: .current).date.description
        let open = store.tasks.filter { !$0.deleted && !$0.completed && !$0.due.isEmpty && String($0.due.prefix(10)) <= today && $0.parent.isEmpty }
            .sorted { $0.due < $1.due }
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "To-dos due", trailing: "\(open.count)")
                VStack(spacing: 0) {
                    ForEach(open.prefix(8)) { t in
                        TaskRow(task: t, showList: true)
                        if t.id != open.prefix(8).last?.id { Divider().padding(.leading, 40) }
                    }
                    if open.count > 8 {
                        Button("See all \(open.count)") { selectTab(.lists) }.font(.subheadline.weight(.semibold)).padding(.top, 8)
                    }
                }
                .roostCard()
            }
        }
    }

    @ViewBuilder private var grocerySection: some View {
        if let list = store.groceryLists.first {
            let items = store.grocery.filter { $0.list == list.id && !$0.deleted && !$0.checked }
            Button { selectTab(.grocery) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "cart.fill").font(.title3).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Circle().fill(Palette.green.color))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.name).font(.rounded(.headline)).foregroundStyle(Color.roostInk)
                        Text(items.isEmpty ? "All stocked up" : "\(items.count) item\(items.count == 1 ? "" : "s") · \(Set(items.map(\.category)).count) aisles")
                            .font(.subheadline).foregroundStyle(Color.roostInk2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Color.roostInk3)
                }
                .roostCard()
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var cardsSection: some View {
        let pinned = store.liveCards.filter(\.pinned)
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Good to know")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(pinned) { c in
                            NavigationLink(value: c) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Image(systemName: InfoCardDetail.icon(for: c)).foregroundStyle(Color.ember)
                                    Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.roostInk).lineLimit(1)
                                    Text(c.body).font(.caption).foregroundStyle(Color.roostInk2).lineLimit(3)
                                }
                                .frame(width: 180, height: 110, alignment: .topLeading)
                                .roostCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct SyncBadge: View {
    @Environment(FamilyStore.self) private var store
    var body: some View {
        switch store.syncState {
        case .syncing: ProgressView().controlSize(.small)
        case .offline:
            Label("Offline", systemImage: "icloud.slash").font(.caption.weight(.semibold)).foregroundStyle(Color.roostInk3)
        case .error(let msg):
            Label("Sync issue", systemImage: "exclamationmark.icloud").font(.caption.weight(.semibold)).foregroundStyle(Color.danger)
                .help(msg)
        case .idle:
            if store.isLocal {
                Label("On this phone", systemImage: "iphone").font(.caption.weight(.semibold)).foregroundStyle(Color.roostInk3)
            } else {
                EmptyView()
            }
        }
    }
}

/// Routes a calendar item to the right detail screen.
struct ItemDetailRouter: View {
    var item: CalItem
    var body: some View {
        switch item.source {
        case .roost(let o): EventDetailView(occurrence: o)
        case .task(let t): TaskEditor(task: t, isNew: false)
        case .device(let id, _): DeviceEventView(identifier: id)
        }
    }
}
