import SwiftUI
import UIKit
import RoostKit

struct GroceryScreen: View {
    static let knownKeys = Set(GroceryTaxonomy.bundled.categories.map(\.key))
    @Environment(FamilyStore.self) private var store
    @AppStorage("grocery.list") private var selectedList = ""
    @State private var input = ""
    @State private var showCart = true
    @State private var editingAisles = false
    @State private var editingItem: GroceryItem?
    @State private var listSettings = false
    @FocusState private var focused: Bool

    private var list: TaskList? {
        store.groceryLists.first { $0.id == selectedList } ?? store.groceryLists.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let list {
                    content(list)
                } else {
                    EmptyState(systemImage: "cart", title: "No grocery list", message: "Ask a parent to share the family grocery list with you.")
                }
            }
            .background(Color.roostBG.ignoresSafeArea())
            .navigationTitle(list?.name ?? "Groceries")
            .toolbar { toolbar }
            .sheet(isPresented: $editingAisles) { if let list { AisleOrderSheet(list: list) } }
            .sheet(item: $editingItem) { GroceryItemSheet(item: $0) }
            .sheet(isPresented: $listSettings) { if let list { ListSettingsSheet(list: list, isNew: false) } }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if store.groceryLists.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("List", selection: $selectedList) {
                        ForEach(store.groceryLists) { l in Text(l.name).tag(l.id) }
                    }
                } label: { Label("Lists", systemImage: "list.bullet") }
            }
        }
        if let list {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: shareText(list)) { Label("Share list as text", systemImage: "square.and.arrow.up") }
                    Button { editingAisles = true } label: { Label("Store aisle order", systemImage: "arrow.up.arrow.down") }
                        .disabled(!store.canEdit(list))
                    if store.isAdmin || list.owner == store.me?.id {
                        Button { listSettings = true } label: { Label("List settings & sharing", systemImage: "gearshape") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func content(_ list: TaskList) -> some View {
        let items = store.grocery.filter { $0.list == list.id && !$0.deleted }
        let open = items.filter { !$0.checked }
        let cart = items.filter(\.checked).sorted { ($0.checkedAt ?? .distantPast) > ($1.checkedAt ?? .distantPast) }
        let editable = store.canEdit(list)
        return List {
            if editable {
                Section { addBar(list) }
            }
            if open.isEmpty && cart.isEmpty {
                EmptyState(systemImage: "basket", title: "List is empty", message: "Type or paste items — they'll sort themselves into aisles.")
                    .listRowBackground(Color.clear)
            }
            ForEach(store.orderedCategories(for: list)) { cat in
                let inCat = open.filter { $0.category == cat.key || (cat.key == "other" && !GroceryScreen.knownKeys.contains($0.category)) }
                    .sorted { $0.sortOrder < $1.sortOrder }
                if !inCat.isEmpty {
                    Section {
                        ForEach(inCat) { it in row(it, editable: editable) }
                    } header: {
                        HStack(spacing: 6) {
                            Text(cat.emoji)
                            Text(cat.name).font(.subheadline.weight(.bold)).foregroundStyle(Color.roostInk)
                            Text("\(inCat.count)").font(.caption.weight(.semibold)).foregroundStyle(Color.roostInk3)
                        }
                        .textCase(nil)
                    }
                }
            }
            if !cart.isEmpty {
                Section {
                    if showCart {
                        ForEach(cart) { it in row(it, editable: editable) }
                    }
                } header: {
                    HStack {
                        Button { withAnimation { showCart.toggle() } } label: {
                            Label("In the cart (\(cart.count))", systemImage: showCart ? "chevron.down" : "chevron.right")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Color.roostInk2)
                        }
                        Spacer()
                        if editable {
                            Button("Clear") { withAnimation { store.clearChecked(list: list.id) } }.font(.subheadline.weight(.semibold))
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.syncNow() }
    }

    private func addBar(_ list: TaskList) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.ember).font(.title3)
                TextField("Add items — “2 lb chicken, milk x2, eggs”", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { add(list) }
                if !input.isEmpty {
                    Button("Add") { add(list) }.font(.subheadline.weight(.bold))
                }
            }
            if !input.isEmpty, let p = GroceryParser.parse(input.split(separator: "\n").first.map(String.init) ?? input) {
                let c = GroceryTaxonomy.bundled.category(store.categorizer.categorize(p.name).category)
                Text("\(c.emoji) \(p.name)\(GroceryParser.formatQuantity(p.quantity, unit: p.unit).map { " · " + $0 } ?? "") → \(c.name)")
                    .font(.caption).foregroundStyle(Color.roostInk2)
            }
            let suggestions = store.suggestions(list: list.id, limit: 10)
            if !suggestions.isEmpty && input.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { store.addGroceries(s, list: list.id) } label: {
                                Label(s, systemImage: "arrow.counterclockwise").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.roostSurface2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func add(_ list: TaskList) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.snappy) { store.addGroceries(text, list: list.id) }
        input = ""
        focused = true
    }

    private func row(_ it: GroceryItem, editable: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { store.toggle(grocery: it) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: it.checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(it.checked ? Palette.green.color : Color.roostInk3)
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(it.name).strikethrough(it.checked).foregroundStyle(it.checked ? Color.roostInk3 : Color.roostInk)
                    if it.categorySource == "ai" { Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.ember) }
                }
                if !it.note.isEmpty { Text(it.note).font(.caption).foregroundStyle(Color.roostInk2) }
            }
            Spacer()
            if let q = it.quantityLabel {
                Text(q).font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.roostSurface2))
                    .foregroundStyle(Color.roostInk2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if editable { editingItem = it } }
        .swipeActions(edge: .trailing) {
            if editable { Button(role: .destructive) { store.delete(grocery: it) } label: { Label("Delete", systemImage: "trash") } }
        }
        .contextMenu {
            if editable {
                Menu {
                    ForEach(GroceryTaxonomy.bundled.categories) { c in
                        Button("\(c.emoji) \(c.name)") { withAnimation { store.setCategory(it, to: c.key) } }
                    }
                } label: { Label("Move to aisle", systemImage: "arrow.right.square") }
                Button { editingItem = it } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { store.delete(grocery: it) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func shareText(_ list: TaskList) -> String {
        let open = store.grocery.filter { $0.list == list.id && !$0.deleted && !$0.checked }
        var lines = [list.name]
        for c in store.orderedCategories(for: list) {
            let items = open.filter { $0.category == c.key }
            guard !items.isEmpty else { continue }
            lines.append("")
            lines.append("\(c.emoji) \(c.name)")
            for it in items { lines.append("☐ \(it.name)\(it.quantityLabel.map { " (\($0))" } ?? "")") }
        }
        return lines.joined(separator: "\n")
    }
}

struct GroceryItemSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var item: GroceryItem
    @State private var qtyText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item", text: $item.name)
                    HStack {
                        TextField("Qty", text: $qtyText).keyboardType(.decimalPad).frame(width: 70)
                        TextField("Unit (lb, oz, pack…)", text: $item.unit).textInputAutocapitalization(.never)
                    }
                    TextField("Note (brand, size…)", text: $item.note)
                }
                Section {
                    Picker("Aisle", selection: $item.category) {
                        ForEach(GroceryTaxonomy.bundled.categories) { c in Text("\(c.emoji) \(c.name)").tag(c.key) }
                    }
                } footer: {
                    Text("Changing the aisle teaches Roost for next time — for everyone in the family.")
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let original = store.grocery.first { $0.id == item.id }
                        item.quantity = Double(qtyText.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
                        if let original, original.category != item.category {
                            store.setCategory(item, to: item.category)
                            var updated = item
                            updated.categorySource = "manual"
                            store.save(grocery: updated)
                        } else {
                            store.save(grocery: item)
                        }
                        dismiss()
                    }
                    .bold().disabled(item.name.isEmpty)
                }
            }
            .onAppear { qtyText = item.quantity.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
        }
        .presentationDetents([.medium])
    }
}

struct AisleOrderSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var list: TaskList
    @State private var order: [GroceryCategory] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { c in
                        HStack { Text(c.emoji); Text(c.name) }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag aisles into the order you walk your store. Tip: make a separate grocery list per store (Costco, Trader Joe's) — each keeps its own order.")
                }
                Section {
                    Button("Reset to default") { order = GroceryTaxonomy.bundled.categories }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Aisle order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var l = list
                        l.storeOrder = order.map(\.key)
                        store.save(list: l)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear { order = store.orderedCategories(for: list) }
        }
    }
}
