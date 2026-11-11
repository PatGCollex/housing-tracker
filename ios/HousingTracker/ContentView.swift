import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NewView()
                .tabItem { Label("This Week", systemImage: "sparkles") }
            WatchingView()
                .tabItem { Label("Watching", systemImage: "star") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}

// MARK: - New

struct NewView: View {
    @EnvironmentObject var store: BillStore
    @State private var filter = BillFilter()

    private var shown: [Bill] { filter.apply(store.newBills) }

    private var emptyText: String? {
        if let error = store.loadError { return error }
        if !shown.isEmpty { return nil }
        if filter.isActive { return "Nothing matches." }
        return "No bill activity in the past week. This fills up when the session starts in January."
    }

    var body: some View {
        NavigationStack {
            List {
                if let recap = store.recap, !filter.isActive {
                    Section {
                        NavigationLink { RecapView(recap: recap) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Weekly recap").font(.headline)
                                Text(recap.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                BillSections(bills: shown)
                if let updated = store.lastUpdated {
                    Section {} footer: { Text("Updated \(DateText.pretty(updated))") }
                }
            }
            .overlay {
                EmptyMessage(text: emptyText)
            }
            .navigationTitle("This Week")
            .toolbar { FilterMenu(filter: $filter) }
            .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
            .refreshable { await store.refresh() }
        }
    }
}

// MARK: - Watching

struct WatchingView: View {
    @EnvironmentObject var store: BillStore
    @State private var byFolder = false
    @State private var open: Set<String> = []
    @State private var askingNewFolder = false
    @State private var renaming: Folder?
    @State private var nameText = ""

    private var years: [String] {
        Array(Set(store.watching.map(\.year))).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.watching.isEmpty {
                    Section {
                        Picker("Group by", selection: $byFolder) {
                            Text("By year").tag(false)
                            Text("By folder").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if byFolder {
                    ForEach(store.folders) { folder in
                        Section {
                            dropdown(key: folder.id.uuidString, title: folder.name, bills: store.bills(in: folder), folder: folder)
                        }
                    }
                    let loose = store.watchingWithoutFolder
                    if !loose.isEmpty {
                        Section {
                            dropdown(key: "none", title: "Not in a folder", bills: loose)
                        } footer: {
                            Text("Press and hold a bill to put it in a folder. Press and hold a folder to rename or delete it.")
                        }
                    }
                } else {
                    ForEach(years, id: \.self) { year in
                        Section {
                            dropdown(key: year, title: year, bills: store.watching.filter { $0.year == year })
                        }
                    }
                }
            }
            .overlay {
                EmptyMessage(text: store.watching.isEmpty
                             ? "Tap the star on any bill to watch it. You'll get an alert when it changes."
                             : nil)
            }
            .navigationTitle("Watching")
            .toolbar {
                Button { nameText = ""; askingNewFolder = true } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
            }
            .alert("New folder", isPresented: $askingNewFolder) {
                TextField("Name, like Property tax", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    store.addFolder(nameText)
                    byFolder = true
                }
            }
            .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let f = renaming { store.renameFolder(f, to: nameText) } }
            }
            .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
            .refreshable { await store.refresh() }
        }
    }

    private func dropdown(key: String, title: String, bills: [Bill], folder: Folder? = nil) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { open.contains(key) },
            set: { if $0 { open.insert(key) } else { open.remove(key) } }
        )) {
            ForEach(bills) { bill in
                NavigationLink(value: bill) { BillRow(bill: bill) }
                    .contextMenu { FolderButtons(bill: bill) }
                    .swipeActions {
                        Button("Unwatch", role: .destructive) { store.toggleStar(bill) }
                    }
            }
        } label: {
            Text("\(title) (\(bills.count))").font(.headline)
                .contextMenu {
                    if let folder {
                        Button("Rename", systemImage: "pencil") { nameText = folder.name; renaming = folder }
                        Button("Delete folder", systemImage: "trash", role: .destructive) { store.deleteFolder(folder) }
                    }
                }
        }
    }
}

/// Folder check marks for one bill, used in menus.
struct FolderButtons: View {
    @EnvironmentObject var store: BillStore
    let bill: Bill

    var body: some View {
        if store.folders.isEmpty {
            Text("Make a folder first with the folder button on Watching.")
        }
        ForEach(store.folders) { folder in
            Button { store.toggle(bill, in: folder) } label: {
                if store.isBill(bill, in: folder) {
                    Label(folder.name, systemImage: "checkmark")
                } else {
                    Text(folder.name)
                }
            }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var store: BillStore
    @State private var query = ""
    @State private var filter = BillFilter()

    private var shown: [Bill] { filter.apply(store.search(query)) }

    var body: some View {
        NavigationStack {
            List { BillSections(bills: shown) }
                .overlay { EmptyMessage(text: shown.isEmpty ? "Nothing matches." : nil) }
                .searchable(text: $query, prompt: "Bill number or topic")
                .navigationTitle("Search")
                .toolbar { FilterMenu(filter: $filter) }
                .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
        }
    }
}

// MARK: - Filters

struct BillFilter: Equatable {
    var type = "All"      // All, House bill, Senate bill, Resolution
    var status = "All"    // All, Became law, Moving, Introduced, Stopped

    var isActive: Bool { self != BillFilter() }

    func apply(_ bills: [Bill]) -> [Bill] {
        bills.filter {
            (type == "All" || $0.billType == type)
                && (status == "All" || $0.statusGroup == status)
        }
    }
}

/// One filter button in the top corner, so the screen stays clean.
struct FilterMenu: View {
    @Binding var filter: BillFilter

    var body: some View {
        Menu {
            Picker("Type", selection: $filter.type) {
                Text("All types").tag("All")
                ForEach(["House bill", "Senate bill", "Resolution"], id: \.self) { Text($0 + "s") }
            }
            .pickerStyle(.menu)
            Picker("Status", selection: $filter.status) {
                Text("Any status").tag("All")
                ForEach(["Became law", "Moving", "Introduced", "Stopped"], id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Button("Clear filters", role: .destructive) { filter = BillFilter() }
            }
        } label: {
            Label("Filter", systemImage: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }
}

// MARK: - Shared pieces

/// Bills that are mainly about housing, then indirect ones tucked in a closed dropdown.
struct BillSections: View {
    let bills: [Bill]
    @State private var showIndirect = false

    private var direct: [Bill] { bills.filter { !$0.isIndirect } }
    private var indirect: [Bill] { bills.filter { $0.isIndirect } }

    var body: some View {
        if !direct.isEmpty {
            Section {
                ForEach(direct) { bill in
                    NavigationLink(value: bill) { BillRow(bill: bill) }
                }
            }
        }
        if !indirect.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showIndirect) {
                    ForEach(indirect) { bill in
                        NavigationLink(value: bill) { BillRow(bill: bill) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Indirectly related (\(indirect.count))").font(.headline)
                        Text("Bills that touch housing but aren't mainly about it")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct BillRow: View {
    let bill: Bill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bill.number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                OutcomeDot(bill: bill)
                Text(bill.displayHeadline).font(.body).lineLimit(3)
            }
            HStack(spacing: 6) {
                Text(bill.status)
                if let date = bill.lastActionDate {
                    Text("·")
                    Text(DateText.pretty(date))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Green dot when a bill passed, red when it failed or was vetoed.
struct OutcomeDot: View {
    let bill: Bill

    var body: some View {
        if let passed = bill.outcome {
            Circle()
                .fill(passed ? Color.green : Color.red)
                .frame(width: 9, height: 9)
                .accessibilityLabel(passed ? "Passed" : "Failed")
        }
    }
}

struct EmptyMessage: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(40)
        }
    }
}

struct RecapView: View {
    let recap: WeeklyRecap

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Week of \(DateText.pretty(recap.weekOf))").font(.subheadline).foregroundStyle(.secondary)
                Text(recap.summary).font(.body)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Weekly recap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
